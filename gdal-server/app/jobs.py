import os
import uuid
import threading
import subprocess
from datetime import datetime
from .utils import WORKSPACE, UPLOADS_DIR, LOGS_DIR, SCRIPT_PATH, parse_progress

# In-memory job storage
_jobs = {}
_jobs_lock = threading.Lock()
_current_job_id = None


def create_job(filename, input_path, output_name, options):
    """Create a new job and return its ID."""
    job_id = uuid.uuid4().hex[:8]
    output_path = os.path.join(WORKSPACE, f"{output_name}.mbtiles")
    log_file = os.path.join(LOGS_DIR, f"{job_id}.log")

    job = {
        "id": job_id,
        "filename": filename,
        "input_path": input_path,
        "output_path": output_path,
        "output_name": output_name,
        "status": "queued",
        "progress": 0,
        "stage": "queued",
        "message": "Waiting to start...",
        "created_at": datetime.now().isoformat(),
        "started_at": None,
        "finished_at": None,
        "options": options,
        "log_file": log_file,
        "logs": [],
    }

    with _jobs_lock:
        _jobs[job_id] = job

    # Start processing in background
    thread = threading.Thread(target=_run_job, args=(job_id,), daemon=True)
    thread.start()

    return job_id


def get_job(job_id):
    """Get job by ID."""
    with _jobs_lock:
        return _jobs.get(job_id, {}).copy() if job_id in _jobs else None


def get_all_jobs():
    """Get all jobs."""
    with _jobs_lock:
        return [j.copy() for j in _jobs.values()]


def get_job_logs(job_id, tail=100):
    """Get recent logs for a job."""
    with _jobs_lock:
        job = _jobs.get(job_id)
        if not job:
            return []
        return job.get("logs", [])[-tail:]


def _update_job(job_id, **kwargs):
    """Update job fields."""
    with _jobs_lock:
        if job_id in _jobs:
            _jobs[job_id].update(kwargs)


def _append_log(job_id, line):
    """Append a log line to the job."""
    with _jobs_lock:
        if job_id in _jobs:
            _jobs[job_id]["logs"].append(line)
            # Keep only last 500 lines in memory
            if len(_jobs[job_id]["logs"]) > 500:
                _jobs[job_id]["logs"] = _jobs[job_id]["logs"][-500:]


def _run_job(job_id):
    """Run the conversion job in background."""
    global _current_job_id

    job = get_job(job_id)
    if not job:
        return

    # Wait if another job is running
    import time
    while True:
        with _jobs_lock:
            if _current_job_id is None:
                _current_job_id = job_id
                break
        time.sleep(1)

    _update_job(job_id, status="running", started_at=datetime.now().isoformat(), 
                progress=5, stage="starting", message="Starting conversion...")

    # Build command
    # Write to a .tmp file first, then rename on success.
    # This prevents the TileServer from trying to read a half-written file.
    output_path = job["output_path"]
    tmp_output_path = output_path + ".tmp"
    opts = job["options"]
    cmd = [
        "/bin/bash", SCRIPT_PATH,
        "-i", job["input_path"],
        "-o", tmp_output_path,
    ]

    if opts.get("min_zoom"):
        cmd.extend(["-z", str(opts["min_zoom"])])
    if opts.get("max_zoom"):
        cmd.extend(["-Z", str(opts["max_zoom"])])
    if opts.get("format"):
        cmd.extend(["-f", opts["format"]])
    if opts.get("quality"):
        cmd.extend(["-q", str(opts["quality"])])
    if opts.get("near_tolerance"):
        cmd.extend(["-n", str(opts["near_tolerance"])])
    if opts.get("processes"):
        cmd.extend(["-p", str(opts["processes"])])
    if opts.get("extent_north") and opts.get("extent_south") and opts.get("extent_east") and opts.get("extent_west"):
        cmd.extend(["--extent-north", str(opts["extent_north"])])
        cmd.extend(["--extent-south", str(opts["extent_south"])])
        cmd.extend(["--extent-east", str(opts["extent_east"])])
        cmd.extend(["--extent-west", str(opts["extent_west"])])
        if opts.get("extent_crs"):
            cmd.extend(["--extent-crs", opts["extent_crs"]])

    # Log the command being run
    print(f"[job {job_id}] Running command: {' '.join(cmd)}", flush=True)
    
    # Open log file
    log_file = job["log_file"]
    
    try:
        with open(log_file, "w") as lf:
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                cwd=WORKSPACE,  # Set working directory
            )

            for line in iter(process.stdout.readline, ''):
                line = line.rstrip("\n")
                if not line:
                    continue
                
                # Write to log file
                lf.write(line + "\n")
                lf.flush()

                # Forward to Docker stdout with job prefix
                print(f"[job {job_id}] {line}", flush=True)

                # Append to in-memory logs
                _append_log(job_id, line)

                # Parse progress
                parsed = parse_progress(line)
                if parsed:
                    pct, stage, msg = parsed
                    _update_job(job_id, progress=pct, stage=stage, message=msg)

            process.wait()

            if process.returncode == 0:
                # Rename .tmp to final path (triggers MOVED_TO for TileServer)
                if os.path.exists(tmp_output_path):
                    if os.path.exists(output_path):
                        os.remove(output_path)
                    os.rename(tmp_output_path, output_path)
                    print(f"[job {job_id}] Renamed {tmp_output_path} -> {output_path}", flush=True)

                _update_job(
                    job_id,
                    status="completed",
                    progress=100,
                    stage="done",
                    message="Conversion complete!",
                    finished_at=datetime.now().isoformat(),
                )
                print(f"[job {job_id}] Completed: {output_path}", flush=True)
            else:
                # Clean up temp file on failure
                if os.path.exists(tmp_output_path):
                    os.remove(tmp_output_path)

                _update_job(
                    job_id,
                    status="failed",
                    stage="error",
                    message=f"Process exited with code {process.returncode}",
                    finished_at=datetime.now().isoformat(),
                )
                print(f"[job {job_id}] Failed with exit code {process.returncode}", flush=True)

    except Exception as e:
        _update_job(
            job_id,
            status="failed",
            stage="error",
            message=str(e),
            finished_at=datetime.now().isoformat(),
        )
        print(f"[job {job_id}] Exception: {e}", flush=True)

    finally:
        _clear_current_job()


def _clear_current_job():
    """Clear the current job ID."""
    global _current_job_id
    with _jobs_lock:
        _current_job_id = None
