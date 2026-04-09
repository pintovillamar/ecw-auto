import os
import re
import unicodedata

ALLOWED_EXTENSIONS = {".ecw", ".tif", ".tiff"}
WORKSPACE = os.environ.get("WORKSPACE_DIR", "/workspace")
UPLOADS_DIR = os.path.join(WORKSPACE, "uploads")
LOGS_DIR = os.path.join(WORKSPACE, "job_logs")
SCRIPT_PATH = os.path.join(WORKSPACE, "ecw.sh")


def ensure_dirs():
    """Create workspace subdirectories if they don't exist."""
    os.makedirs(UPLOADS_DIR, exist_ok=True)
    os.makedirs(LOGS_DIR, exist_ok=True)


def safe_filename(filename):
    """Sanitize a filename to a safe slug."""
    # Normalize unicode
    name = unicodedata.normalize("NFKD", filename)
    name = name.encode("ascii", "ignore").decode("ascii")
    # Get name without extension
    base, ext = os.path.splitext(name)
    # Replace non-alphanumeric with underscores, collapse multiples
    base = re.sub(r"[^\w\-]", "_", base)
    base = re.sub(r"_+", "_", base).strip("_").lower()
    return base, ext.lower()


def allowed_file(filename):
    """Check if the file extension is allowed."""
    _, ext = os.path.splitext(filename)
    return ext.lower() in ALLOWED_EXTENSIONS


def parse_progress(line):
    """Parse a log line from ecw.sh and return (progress_pct, stage, message) or None."""

    # [INFO] ... - Processing: filename
    if "Processing:" in line:
        return 10, "analyzing", line.strip()

    # [INFO] ... - Raster bounds:
    if "Raster bounds:" in line:
        return 12, "analyzing", line.strip()

    # [INFO] ... - Source CRS:
    if "Source CRS:" in line:
        return 14, "analyzing", line.strip()

    # Creating RGB VRT
    if "Creating RGB VRT" in line:
        return 20, "analyzing", line.strip()

    # RGB VRT created
    if "RGB VRT created" in line:
        return 22, "analyzing", line.strip()

    # Generating tiles
    if "Generating tiles" in line:
        return 25, "tiling", line.strip()

    # Processing N potential tiles
    if "potential tiles" in line:
        return 26, "tiling", line.strip()

    # Progress: X/Y (Z tiles)...
    m = re.search(r"Progress:\s*(\d+)/(\d+)", line)
    if m:
        done, total = int(m.group(1)), int(m.group(2))
        if total > 0:
            # Map tile progress to 25-85% range
            pct = 25 + int((done / total) * 60)
            return min(pct, 85), "tiling", line.strip()

    # Generated N tiles
    if "Generated" in line and "tiles" in line:
        return 87, "packing", line.strip()

    # Creating MBTiles
    if "Creating MBTiles" in line:
        return 90, "packing", line.strip()

    # MBTiles created
    if "MBTiles created" in line:
        return 95, "packing", line.strip()

    # Conversion complete
    if "Conversion complete" in line:
        return 100, "done", line.strip()

    return None
