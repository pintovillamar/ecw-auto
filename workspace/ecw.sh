#!/bin/bash
# ECW to MBTiles Converter - Direct conversion using GDAL CLI (ECW SDK)
# Uses a VRT to select RGB bands, then gdalwarp for reprojection to Web Mercator

set -e

# ============== CONFIGURATION ==============
INPUT_ECW=""
OUTPUT_MBTILES=""
MIN_ZOOM=13
MAX_ZOOM=19
TILE_SIZE=256
TILE_FORMAT="PNG"
JPEG_QUALITY=85
NEAR_TOL=22
PROCESSES=4
TEMP_DIR=""

# Extent overrides (optional)
EXTENT_NORTH=""
EXTENT_SOUTH=""
EXTENT_EAST=""
EXTENT_WEST=""
EXTENT_CRS=""

GDAL_BIN="/usr/local/bin"

# ============== FUNCTIONS ==============
show_help() {
    echo "ECW to MBTiles Converter"
    echo ""
    echo "Usage: $0 -i <input.ecw> -o <output.mbtiles> [options]"
    echo ""
    echo "Required:"
    echo "  -i, --input       Input ECW file path"
    echo "  -o, --output      Output MBTiles file path"
    echo ""
    echo "Optional:"
    echo "  -z, --min-zoom    Minimum zoom level (default: 13)"
    echo "  -Z, --max-zoom    Maximum zoom level (default: 18)"
    echo "  -f, --format      Tile format: png or jpg (default: png)"
    echo "  -q, --quality     JPEG quality 1-100 (default: 85)"
    echo "  -n, --near        Near-white tolerance for transparency (default: 22)"
    echo "  -p, --processes   Parallel processes (default: 4)"
    echo "  -g, --gdal-path   Path to GDAL binaries (default: /usr/local/bin)"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Extent (optional, export a sub-region instead of the full raster):"
    echo "  --extent-north    North bound (Y max)"
    echo "  --extent-south    South bound (Y min)"
    echo "  --extent-east     East bound (X max)"
    echo "  --extent-west     West bound (X min)"
    echo "  --extent-crs      CRS of the extent values (default: same as raster)."
    echo "                    Use EPSG:4326 for lat/lon or any EPSG code."
    exit 0
}

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_info "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# ============== PARSE ARGUMENTS ==============
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input) INPUT_ECW="$2"; shift 2 ;;
        -o|--output) OUTPUT_MBTILES="$2"; shift 2 ;;
        -z|--min-zoom) MIN_ZOOM="$2"; shift 2 ;;
        -Z|--max-zoom) MAX_ZOOM="$2"; shift 2 ;;
        -f|--format)
            if [ "$2" = "jpg" ] || [ "$2" = "jpeg" ]; then
                TILE_FORMAT="JPEG"
            else
                TILE_FORMAT="PNG"
            fi
            shift 2 ;;
        -q|--quality) JPEG_QUALITY="$2"; shift 2 ;;
        -n|--near) NEAR_TOL="$2"; shift 2 ;;
        -p|--processes) PROCESSES="$2"; shift 2 ;;
        -g|--gdal-path) GDAL_BIN="$2"; shift 2 ;;
        --extent-north) EXTENT_NORTH="$2"; shift 2 ;;
        --extent-south) EXTENT_SOUTH="$2"; shift 2 ;;
        --extent-east) EXTENT_EAST="$2"; shift 2 ;;
        --extent-west) EXTENT_WEST="$2"; shift 2 ;;
        --extent-crs) EXTENT_CRS="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) log_error "Unknown option: $1"; show_help ;;
    esac
done

# ============== VALIDATION ==============
[ -z "$INPUT_ECW" ] && { log_error "Input ECW file is required (-i)"; exit 1; }
[ -z "$OUTPUT_MBTILES" ] && { log_error "Output MBTiles file is required (-o)"; exit 1; }
[ ! -f "$INPUT_ECW" ] && { log_error "Input file does not exist: $INPUT_ECW"; exit 1; }

GDALINFO="$GDAL_BIN/gdalinfo"
GDAL_TRANSLATE="$GDAL_BIN/gdal_translate"
GDALWARP="$GDAL_BIN/gdalwarp"
NEARBLACK="$GDAL_BIN/nearblack"

for tool in "$GDALINFO" "$GDAL_TRANSLATE" "$GDALWARP"; do
    [ ! -x "$tool" ] && { log_error "GDAL tool not found: $tool"; exit 1; }
done

if [ "$TILE_FORMAT" = "PNG" ] && [ ! -x "$NEARBLACK" ]; then
    log_error "nearblack tool not found: $NEARBLACK"
    log_error "Install GDAL utils that include nearblack or use -f jpg"
    exit 1
fi

"$GDALINFO" --formats 2>/dev/null | grep -q "ECW" || { log_error "GDAL has no ECW support"; exit 1; }

log_info "Using GDAL from: $GDAL_BIN"
log_info "ECW SDK: $("$GDALINFO" --formats | grep ECW | head -1)"

INPUT_ECW=$(realpath "$INPUT_ECW")
OUTPUT_DIR=$(dirname "$(realpath -m "$OUTPUT_MBTILES")")
OUTPUT_NAME=$(basename "$OUTPUT_MBTILES")
OUTPUT_MBTILES="$OUTPUT_DIR/$OUTPUT_NAME"

TEMP_DIR=$(mktemp -d -t ecw_mbtiles_XXXXXX)
TILES_DIR="$TEMP_DIR/tiles"
RGB_VRT="$TEMP_DIR/rgb.vrt"
mkdir -p "$TILES_DIR"

# ============== GET RASTER INFO ==============
log_info "Processing: $(basename "$INPUT_ECW")"

RASTER_INFO=$("$GDALINFO" -json "$INPUT_ECW")

read -r XMIN YMIN XMAX YMAX CRS_CODE RASTER_WIDTH RASTER_HEIGHT < <(echo "$RASTER_INFO" | python3 -c "
import sys, json, re

data = json.load(sys.stdin)

corners = data.get('cornerCoordinates', {})
ul = corners.get('upperLeft', [0, 0])
lr = corners.get('lowerRight', [0, 0])

xmin, ymax = ul[0], ul[1]
xmax, ymin = lr[0], lr[1]

size = data.get('size', [0, 0])
width, height = size[0], size[1]

wkt = data.get('coordinateSystem', {}).get('wkt', '')
matches = re.findall(r'ID\[\"EPSG\",\s*(\d+)\]', wkt)
epsg = matches[-1] if matches else '32718'

print(f'{xmin} {ymin} {xmax} {ymax} {epsg} {width} {height}')
")

log_info "Raster bounds: $XMIN, $YMIN, $XMAX, $YMAX"
log_info "Source CRS: EPSG:$CRS_CODE"
log_info "Raster size: ${RASTER_WIDTH}x${RASTER_HEIGHT}"

# ============== APPLY EXTENT OVERRIDES ==============
HAS_EXTENT=false
if [ -n "$EXTENT_NORTH" ] || [ -n "$EXTENT_SOUTH" ] || [ -n "$EXTENT_EAST" ] || [ -n "$EXTENT_WEST" ]; then
    # All four must be provided
    if [ -z "$EXTENT_NORTH" ] || [ -z "$EXTENT_SOUTH" ] || [ -z "$EXTENT_EAST" ] || [ -z "$EXTENT_WEST" ]; then
        log_error "All four extent values are required (--extent-north, --extent-south, --extent-east, --extent-west)"
        exit 1
    fi
    HAS_EXTENT=true
fi

if [ "$HAS_EXTENT" = true ]; then
    # If extent CRS is specified and differs from raster CRS, reproject the extent
    if [ -n "$EXTENT_CRS" ]; then
        # Normalize: accept both "EPSG:4326" and "4326"
        EXTENT_EPSG=$(echo "$EXTENT_CRS" | sed 's/^EPSG://i')

        if [ "$EXTENT_EPSG" != "$CRS_CODE" ]; then
            log_info "Reprojecting extent from EPSG:$EXTENT_EPSG to EPSG:$CRS_CODE..."
            read -r EXTENT_WEST EXTENT_SOUTH EXTENT_EAST EXTENT_NORTH < <(python3 -c "
from pyproj import Transformer
t = Transformer.from_crs('EPSG:$EXTENT_EPSG', 'EPSG:$CRS_CODE', always_xy=True)
x1, y1 = t.transform($EXTENT_WEST, $EXTENT_SOUTH)
x2, y2 = t.transform($EXTENT_EAST, $EXTENT_NORTH)
print(f'{min(x1,x2)} {min(y1,y2)} {max(x1,x2)} {max(y1,y2)}')
")
            log_info "Reprojected extent: $EXTENT_WEST, $EXTENT_SOUTH, $EXTENT_EAST, $EXTENT_NORTH"
        fi
    fi

    # Clamp to raster bounds
    read -r XMIN YMIN XMAX YMAX < <(python3 -c "
xmin = max($EXTENT_WEST, $XMIN)
ymin = max($EXTENT_SOUTH, $YMIN)
xmax = min($EXTENT_EAST, $XMAX)
ymax = min($EXTENT_NORTH, $YMAX)
if xmin >= xmax or ymin >= ymax:
    import sys
    print('ERROR: Specified extent does not overlap with the raster bounds', file=sys.stderr)
    sys.exit(1)
print(f'{xmin} {ymin} {xmax} {ymax}')
")

    log_info "Using custom extent: $XMIN, $YMIN, $XMAX, $YMAX"
fi

# ============== CREATE RGB VRT ==============
log_info "Creating RGB VRT (selecting bands 1,2,3 only)..."

"$GDAL_TRANSLATE" -of VRT -b 1 -b 2 -b 3 "$INPUT_ECW" "$RGB_VRT" -q

log_info "RGB VRT created: $RGB_VRT"

# ============== GENERATE TILES ==============
log_info "Generating tiles (zoom $MIN_ZOOM to $MAX_ZOOM)..."

python3 << PYTHON_SCRIPT
import os
import sys
import subprocess
import math
import sqlite3
from concurrent.futures import ProcessPoolExecutor, as_completed

# Arguments from bash
rgb_vrt = "$RGB_VRT"
tiles_dir = "$TILES_DIR"
output_mbtiles = "$OUTPUT_MBTILES"
min_zoom = $MIN_ZOOM
max_zoom = $MAX_ZOOM
tile_size = $TILE_SIZE
tile_format = "$TILE_FORMAT"
jpeg_quality = $JPEG_QUALITY
near_tol = $NEAR_TOL
processes = $PROCESSES
gdalwarp = "$GDALWARP"
nearblack = "$NEARBLACK"
src_crs = "$CRS_CODE"
xmin, ymin, xmax, ymax = $XMIN, $YMIN, $XMAX, $YMAX

# Web Mercator constants
ORIGIN_SHIFT = 20037508.342789244

# Transform bounds
from pyproj import Transformer
transformer_to_merc = Transformer.from_crs(f"EPSG:{src_crs}", "EPSG:3857", always_xy=True)
transformer_to_4326 = Transformer.from_crs(f"EPSG:{src_crs}", "EPSG:4326", always_xy=True)

corners_src = [(xmin, ymin), (xmin, ymax), (xmax, ymax), (xmax, ymin)]
corners_merc = [transformer_to_merc.transform(x, y) for x, y in corners_src]
corners_4326 = [transformer_to_4326.transform(x, y) for x, y in corners_src]

merc_xmin = min(c[0] for c in corners_merc)
merc_xmax = max(c[0] for c in corners_merc)
merc_ymin = min(c[1] for c in corners_merc)
merc_ymax = max(c[1] for c in corners_merc)

lon_min = min(c[0] for c in corners_4326)
lon_max = max(c[0] for c in corners_4326)
lat_min = min(c[1] for c in corners_4326)
lat_max = max(c[1] for c in corners_4326)

print(f"Mercator bounds: {merc_xmin:.2f}, {merc_ymin:.2f}, {merc_xmax:.2f}, {merc_ymax:.2f}", file=sys.stderr)

def tile_bounds_mercator(tx, ty, zoom):
    tile_count = 2 ** zoom
    tile_size_m = 2 * ORIGIN_SHIFT / tile_count
    min_x = -ORIGIN_SHIFT + tx * tile_size_m
    max_x = min_x + tile_size_m
    max_y = ORIGIN_SHIFT - ty * tile_size_m
    min_y = max_y - tile_size_m
    return min_x, min_y, max_x, max_y

def get_tiles_for_extent(min_x, min_y, max_x, max_y, zoom):
    tile_count = 2 ** zoom
    tile_size_m = 2 * ORIGIN_SHIFT / tile_count
    tx_min = max(0, int((min_x + ORIGIN_SHIFT) / tile_size_m))
    tx_max = min(tile_count - 1, int((max_x + ORIGIN_SHIFT) / tile_size_m))
    ty_min = max(0, int((ORIGIN_SHIFT - max_y) / tile_size_m))
    ty_max = min(tile_count - 1, int((ORIGIN_SHIFT - min_y) / tile_size_m))
    return tx_min, ty_min, tx_max, ty_max

first_error = [False]

def generate_tile(task):
    zoom, tx, ty = task
    
    # Tile bounds in Web Mercator
    t_xmin, t_ymin, t_xmax, t_ymax = tile_bounds_mercator(tx, ty, zoom)
    
    # Quick check - does tile intersect our data?
    if t_xmax < merc_xmin or t_xmin > merc_xmax or t_ymax < merc_ymin or t_ymin > merc_ymax:
        return None
    
    # Output path
    ext = "png" if tile_format == "PNG" else "jpg"
    out_dir = os.path.join(tiles_dir, str(zoom), str(tx))
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{ty}.{ext}")
    
    # Use gdalwarp to reproject and extract tile
    # -te specifies the target extent in target CRS (Web Mercator)
    # -dstalpha adds alpha channel for transparency
    # -srcnodata makes near-white pixels (borders) transparent
    cmd = [
        gdalwarp,
        "-t_srs", "EPSG:3857",
        "-te", str(t_xmin), str(t_ymin), str(t_xmax), str(t_ymax),
        "-ts", str(tile_size), str(tile_size),
        "-r", "cubic",
        "-dstalpha",  # Add alpha channel
        "-srcnodata", "255 255 255",  # QGIS-like sampled white border color
        "-dstnodata", "0 0 0 0",  # Output nodata as transparent
        "-of", tile_format,
        "-overwrite",
        "-q",
        rgb_vrt,
        out_path
    ]
    
    if tile_format == "JPEG":
        # JPEG doesn't support alpha, remove dstalpha options
        cmd = [
            gdalwarp,
            "-t_srs", "EPSG:3857",
            "-te", str(t_xmin), str(t_ymin), str(t_xmax), str(t_ymax),
            "-ts", str(tile_size), str(tile_size),
            "-r", "cubic",
            "-of", tile_format,
            "-co", f"QUALITY={jpeg_quality}",
            "-overwrite",
            "-q",
            rgb_vrt,
            out_path
        ]
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        
        if result.returncode != 0:
            if not first_error[0]:
                print(f"GDAL Error: {result.stderr}", file=sys.stderr)
                print(f"Command: {' '.join(cmd)}", file=sys.stderr)
                first_error[0] = True
            return None

        if tile_format == "PNG" and os.path.exists(out_path):
            clean_path = out_path + ".clean.png"
            nb_cmd = [
                nearblack,
                "-of", "PNG",
                "-white",
                "-near", str(near_tol),
                "-setalpha",
                out_path,
                clean_path,
            ]
            nb_res = subprocess.run(nb_cmd, capture_output=True, text=True, timeout=60)
            if nb_res.returncode == 0 and os.path.exists(clean_path):
                os.replace(clean_path, out_path)
            elif os.path.exists(clean_path):
                os.remove(clean_path)

        if os.path.exists(out_path) and os.path.getsize(out_path) > 100:
            return (zoom, tx, ty, out_path)
    except Exception as e:
        if not first_error[0]:
            print(f"Exception: {e}", file=sys.stderr)
            first_error[0] = True
    
    return None

# Build tile list
tile_tasks = []
for zoom in range(min_zoom, max_zoom + 1):
    tx_min, ty_min, tx_max, ty_max = get_tiles_for_extent(merc_xmin, merc_ymin, merc_xmax, merc_ymax, zoom)
    for tx in range(tx_min, tx_max + 1):
        for ty in range(ty_min, ty_max + 1):
            tile_tasks.append((zoom, tx, ty))

print(f"Processing {len(tile_tasks)} potential tiles...", file=sys.stderr)

# Generate tiles
generated_tiles = []
with ProcessPoolExecutor(max_workers=processes) as executor:
    futures = {executor.submit(generate_tile, task): task for task in tile_tasks}
    completed = 0
    for future in as_completed(futures):
        completed += 1
        result = future.result()
        if result:
            generated_tiles.append(result)
        if completed % 100 == 0:
            print(f"  Progress: {completed}/{len(tile_tasks)} ({len(generated_tiles)} tiles)...", file=sys.stderr)

print(f"Generated {len(generated_tiles)} tiles", file=sys.stderr)

# Create MBTiles
print("Creating MBTiles...", file=sys.stderr)

if os.path.exists(output_mbtiles):
    os.remove(output_mbtiles)

conn = sqlite3.connect(output_mbtiles)
cursor = conn.cursor()

cursor.execute('CREATE TABLE metadata (name TEXT, value TEXT)')
cursor.execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)')
cursor.execute('CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)')
cursor.execute('CREATE UNIQUE INDEX name ON metadata (name)')

layer_name = os.path.splitext(os.path.basename("$INPUT_ECW"))[0].replace(' ', '_')
fmt = "png" if tile_format == "PNG" else "jpg"
bounds_str = f"{lon_min},{lat_min},{lon_max},{lat_max}"
center_lon = (lon_min + lon_max) / 2
center_lat = (lat_min + lat_max) / 2

metadata = [
    ('name', layer_name),
    ('type', 'overlay'),
    ('version', '1.0'),
    ('description', 'Converted from ECW'),
    ('format', fmt),
    ('bounds', bounds_str),
    ('center', f'{center_lon},{center_lat},{min_zoom}'),
    ('minzoom', str(min_zoom)),
    ('maxzoom', str(max_zoom)),
]
cursor.executemany('INSERT INTO metadata (name, value) VALUES (?, ?)', metadata)

for zoom, tx, ty, tile_path in generated_tiles:
    with open(tile_path, 'rb') as f:
        tile_data = f.read()
    tms_y = (2 ** zoom) - 1 - ty
    cursor.execute(
        'INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)',
        (zoom, tx, tms_y, tile_data)
    )

conn.commit()
conn.close()

print(f"MBTiles created with {len(generated_tiles)} tiles", file=sys.stderr)
PYTHON_SCRIPT

# ============== SUMMARY ==============
if [ -f "$OUTPUT_MBTILES" ]; then
    FINAL_SIZE=$(du -h "$OUTPUT_MBTILES" | cut -f1)
    log_info "============================================"
    log_info "Conversion complete!"
    log_info "  Input:  $INPUT_ECW"
    log_info "  Output: $OUTPUT_MBTILES"
    log_info "  Size:   $FINAL_SIZE"
    log_info "  Zoom:   $MIN_ZOOM - $MAX_ZOOM"
    log_info "============================================"
else
    log_error "MBTiles file was not created"
    exit 1
fi
