import os
from flask import Flask, request, jsonify, render_template, send_file
from werkzeug.utils import secure_filename
from .utils import ensure_dirs, safe_filename, allowed_file, WORKSPACE, UPLOADS_DIR
from . import jobs

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024 * 1024  # 10 GB max upload

# Ensure directories exist on startup
ensure_dirs()


@app.route("/")
def index():
    """Serve the main UI."""
    return render_template("index.html")


@app.route("/health")
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok"})


@app.route("/api/jobs", methods=["POST"])
def create_job():
    """Upload a file and create a conversion job."""
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    if file.filename == "":
        return jsonify({"error": "No file selected"}), 400

    if not allowed_file(file.filename):
        return jsonify({"error": "File type not allowed. Use .ecw, .tif, or .tiff"}), 400

    # Get output name from form or derive from filename
    output_name = request.form.get("output_name", "").strip()
    if not output_name:
        base, _ = safe_filename(file.filename)
        output_name = base
    else:
        output_name, _ = safe_filename(output_name)

    if not output_name:
        output_name = "output"

    # Save uploaded file
    original_name = secure_filename(file.filename)
    input_path = os.path.join(UPLOADS_DIR, original_name)
    file.save(input_path)
    print(f"[web] Upload received: {original_name} -> {input_path}", flush=True)

    # Parse options
    options = {
        "min_zoom": _parse_int(request.form.get("min_zoom"), 13),
        "max_zoom": _parse_int(request.form.get("max_zoom"), 19),
        "format": request.form.get("format", "png").lower(),
        "quality": _parse_int(request.form.get("quality"), 85),
        "near_tolerance": _parse_int(request.form.get("near_tolerance"), 22),
        "processes": _parse_int(request.form.get("processes"), 4),
        "extent_north": _parse_float(request.form.get("extent_north")),
        "extent_south": _parse_float(request.form.get("extent_south")),
        "extent_east": _parse_float(request.form.get("extent_east")),
        "extent_west": _parse_float(request.form.get("extent_west")),
        "extent_crs": request.form.get("extent_crs", "").strip() or None,
    }

    # Validate zoom
    if options["min_zoom"] > options["max_zoom"]:
        options["min_zoom"], options["max_zoom"] = options["max_zoom"], options["min_zoom"]

    # Create job
    job_id = jobs.create_job(original_name, input_path, output_name, options)
    print(f"[web] Job created: {job_id} for {original_name}", flush=True)

    return jsonify({"job_id": job_id, "message": "Job created"}), 201


@app.route("/api/jobs", methods=["GET"])
def list_jobs():
    """List all jobs."""
    all_jobs = jobs.get_all_jobs()
    # Return without full logs
    for j in all_jobs:
        j.pop("logs", None)
    return jsonify(all_jobs)


@app.route("/api/jobs/<job_id>", methods=["GET"])
def get_job(job_id):
    """Get job status."""
    job = jobs.get_job(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    # Don't include full logs in status
    job.pop("logs", None)
    return jsonify(job)


@app.route("/api/jobs/<job_id>/logs", methods=["GET"])
def get_job_logs(job_id):
    """Get job logs."""
    job = jobs.get_job(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404

    tail = _parse_int(request.args.get("tail"), 100)
    logs = jobs.get_job_logs(job_id, tail=tail)
    return jsonify({"logs": logs})


@app.route("/api/outputs", methods=["GET"])
def list_outputs():
    """List available .mbtiles files."""
    outputs = []
    for f in os.listdir(WORKSPACE):
        if f.endswith(".mbtiles"):
            path = os.path.join(WORKSPACE, f)
            stat = os.stat(path)
            outputs.append({
                "name": f,
                "size": stat.st_size,
                "modified": stat.st_mtime,
            })
    outputs.sort(key=lambda x: x["modified"], reverse=True)
    return jsonify(outputs)


def _parse_int(val, default=None):
    """Parse an integer or return default."""
    if val is None:
        return default
    try:
        return int(val)
    except (ValueError, TypeError):
        return default


def _parse_float(val, default=None):
    """Parse a float or return default."""
    if val is None or val == "":
        return default
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
