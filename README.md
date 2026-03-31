# ECW-Auto

A Docker-based toolkit for working with **ECW geospatial imagery**. Builds a slim, optimized container with GDAL compiled from source with full ECW read support no manual SDK installation required.

Includes an integrated **TileServer GL** setup with automatic file detection convert ECW to MBTiles and serve them instantly without manual restarts.

## Features

- **Multi-stage Docker build** small runtime image (~1–1.5 GB) based on `debian:12-slim`
- **GDAL 3.4.1 + ECW SDK 5.4.0** read ECW/JP2 files out of the box
- **Python ready** includes `pyproj` in a virtual environment
- **Automated SDK install** handles the ECW license prompt and pager issues automatically
- **Integrated TileServer GL** serve MBTiles tiles via HTTP with a web UI
- **Auto-detection** TileServer automatically picks up new `.mbtiles` files and restarts

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- `erdas-ecw-sdk-5.4.0-linux.zip` placed in the same directory as the Dockerfile

## Quick Start (Docker Compose)

The easiest way to run the full stack (GDAL + TileServer) is with Docker Compose:

```bash
# Start both containers
docker compose up -d --build

# Access TileServer at http://localhost:8080

# Run ECW conversions
docker compose exec gdal-ecw bash
./ecw_to_mbtiles.sh -i /workspace/input.ecw -o /workspace/output.mbtiles

# View logs
docker compose logs -f tileserver

# Stop everything
docker compose down
```

### Quick Start (GDAL container only)

If you only need the GDAL container without the TileServer:

```bash
docker build --progress=plain --no-cache -t ecw-slim .
docker run -it -v "$(pwd)/workspace:/workspace" ecw-slim
```

## Stage 1: Builder

### 1. Build Dependencies

```bash
apt-get install -y --no-install-recommends \
    build-essential cmake libproj-dev libgeos-dev \
    libsqlite3-dev libtiff-dev libgeotiff-dev libcurl4-openssl-dev \
    libpng-dev libjpeg-dev libgif-dev libwebp-dev libopenjp2-7-dev \
    libexpat1-dev libxerces-c-dev libpq-dev libhdf5-dev libnetcdf-dev \
    libpoppler-dev libfreexl-dev libspatialite-dev libcfitsio-dev \
    liblzma-dev libzstd-dev swig python3-dev python3-numpy wget unzip \
    python3-venv expect ca-certificates
```

### 2. ECW SDK Installation

The installer uses a pager (`more`/`less`) that hangs in Docker. The fix is to symlink them to `cat`:

```bash
ln -sf /bin/cat /usr/bin/more && ln -sf /bin/cat /usr/bin/less
```

The installer is automated via an `expect` script that:

1. Selects option `1` (Desktop Read-Only Redistributable)
2. Auto-scrolls through the license (`--More--` handling)
3. Accepts the license agreement (`yes`)

The entire SDK is moved preserving its original directory structure:

```bash
mv /hexagon/ERDAS-ECW_JPEG_2000_SDK-5.4.0/Desktop_Read-Only /usr/local/hexagon_ecw
```

> **Important:** GDAL's configure expects the SDK's original directory layout. Flattening the paths breaks linking.

### 3. ECW Library Path

```bash
echo '/usr/local/hexagon_ecw/lib/newabi/x64/release' > /etc/ld.so.conf.d/ecw.conf
ldconfig
```

### 4. GDAL Compilation

```bash
./configure --with-unix-stdio-64=no \
    --with-ecw=/usr/local/hexagon_ecw \
    --with-ecw-lib=/usr/local/hexagon_ecw/lib/newabi/x64/release

make -j$(nproc)
make install
ldconfig
```

Binaries are then stripped to reduce size:

```bash
strip --strip-unneeded /usr/local/lib/libgdal.so*
strip --strip-unneeded /usr/local/bin/gdal* /usr/local/bin/ogr* /usr/local/bin/nearblack
```

## Stage 2: Runtime

### 5. Runtime Libraries

Only runtime (non-dev) Debian packages are installed no build tools, no `-dev` headers.

### 6. Copied from Builder

- `/usr/local/lib/` GDAL shared libraries
- `/usr/local/bin/gdal_translate`, `gdalinfo`, `gdalwarp`, `nearblack`, `ogr*` GDAL binaries
- `/usr/local/share/gdal/` GDAL data files
- `/usr/local/hexagon_ecw/lib/newabi/x64/release/` ECW runtime libraries only

### 7. ECW Symlinks

```bash
ln -s /usr/local/hexagon_ecw/lib/newabi/x64/release/libNCSEcw.so.5.4.0 /usr/local/lib/libNCSEcw.so.5.4.0
ln -s /usr/local/lib/libNCSEcw.so.5.4.0 /usr/local/lib/libNCSEcw.so.5.4
ln -s /usr/local/lib/libNCSEcw.so.5.4 /usr/local/lib/libNCSEcw.so.5
ln -s /usr/local/lib/libNCSEcw.so.5 /usr/local/lib/libNCSEcw.so
ldconfig
```

### 8. Python Environment

A venv is created at `/opt/venv` with `pyproj` installed.

## Build & Run

**PowerShell:**

```powershell
# Build
docker build --progress=plain --no-cache -t ecw-slim . 2>&1 | Tee-Object -FilePath build.log

# Run
docker run -it --name ecw-container -v "${PWD}/workspace:/workspace" ecw-slim
```

**Bash / macOS / Linux:**

```bash
# Build
docker build --progress=plain --no-cache -t ecw-slim . 2>&1 | tee build.log

# Run
docker run -it -v "$(pwd)/workspace:/workspace" ecw-slim
```

**Command Prompt (cmd):**

```cmd
:: Build
docker build --progress=plain --no-cache -t ecw-slim . 2>&1 > build.log

:: Run
docker run -it --name ecw-container -v "%cd%/workspace:/workspace" ecw-slim
```


## Verify

```bash
gdalinfo --formats | grep -i ecw
```

Expected output:

```
  ECW -raster- (rw+): ERDAS Compressed Wavelets (SDK 5.4)
  JP2ECW -raster,vector- (rw+v): ERDAS JPEG2000 (SDK 5.4)
```

## Usage ECW to MBTiles

The included `ecw_to_mbtiles.sh` script converts ECW imagery to MBTiles format. It reprojects to Web Mercator, generates tiles across zoom levels, and handles near-white border transparency.

**Basic usage:**

```bash
./workspace/ecw_to_mbtiles.sh -i /workspace/input.ecw -o /workspace/output.mbtiles
```

**With options:**

```bash
./workspace/ecw_to_mbtiles.sh \
  -i /workspace/input.ecw \
  -o /workspace/output.mbtiles \
  -z 10 -Z 18 \
  -f png \
  -n 22 \
  -p 4
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-i, --input` | Input ECW file path | *(required)* |
| `-o, --output` | Output MBTiles file path | *(required)* |
| `-z, --min-zoom` | Minimum zoom level | `13` |
| `-Z, --max-zoom` | Maximum zoom level | `18` |
| `-f, --format` | Tile format: `png` or `jpg` | `png` |
| `-q, --quality` | JPEG quality 1–100 | `85` |
| `-n, --near` | Near-white tolerance for transparency | `22` |
| `-p, --processes` | Parallel processes | `4` |
| `-g, --gdal-path` | Path to GDAL binaries | `/usr/local/bin` |

## TileServer GL Integration

The project includes a custom TileServer GL setup that automatically detects and serves `.mbtiles` files.

### Architecture

```
docker-compose.yml
├── gdal-ecw                    # GDAL + ECW SDK container
│   └── mounts ./workspace → /workspace
│
└── tileserver                  # TileServer GL with auto-detection
    └── mounts ./workspace → /data
```

Both containers share the `./workspace` directory:
- **GDAL container** writes `.mbtiles` files to `/workspace`
- **TileServer** reads them from `/data` (same directory, different mount point)

### How Auto-Detection Works

The TileServer uses a custom entrypoint script (`tileserver/entrypoint.sh`) that:

1. **On startup**: Scans `/data` for all `*.mbtiles` files
2. **Generates `config.json`**: Creates entries for each file found (e.g., `output.mbtiles` becomes layer `"output"`)
3. **Starts tileserver-gl**: Serves tiles via HTTP on port 8080
4. **Watches for changes**: Uses `inotifywait` to monitor `/data` for new/deleted `.mbtiles` files
5. **Auto-restarts**: When a change is detected, regenerates config and restarts the server

This means you never need to manually restart the TileServer or edit `config.json` just create new `.mbtiles` files and they're automatically served.

### TileServer Endpoints

Once running at `http://localhost:8080`:

| Endpoint | Description |
|----------|-------------|
| `/` | Web UI showing all available tile layers |
| `/data/{layer_name}/{z}/{x}/{y}.png` | Raster tiles (PNG) |
| `/data/{layer_name}/{z}/{x}/{y}.jpg` | Raster tiles (JPEG) |
| `/data/{layer_name}.json` | TileJSON metadata |

**Example:** If you have `toquepala.mbtiles`, tiles are served at:
```
http://localhost:8080/data/toquepala/{z}/{x}/{y}.png
```

### Using with Leaflet

```javascript
var layer = L.tileLayer('http://localhost:8080/data/toquepala/{z}/{x}/{y}.png', {
    minZoom: 10,
    maxZoom: 20,
    tms: false,
    attribution: '© Your Attribution'
});
layer.addTo(map);
```

### Customizing the TileServer

The TileServer is built from `tileserver/Dockerfile`:

```dockerfile
FROM maptiler/tileserver-gl:latest
# Adds inotify-tools for file watching
# Adds jq for JSON manipulation
# Uses custom entrypoint for auto-detection
```

To modify the entrypoint behavior, edit `tileserver/entrypoint.sh`.

### Manual TileServer (without auto-detection)

If you prefer manual control, you can run the stock TileServer image:

```bash
docker run --rm -it -v "$(pwd)/workspace:/data" -p 8080:8080 maptiler/tileserver-gl
```

Note: This requires manually updating `config.json` and restarting the container when adding new files.

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `--More-- (END)` hang during build | ECW installer pager | `ln -sf /bin/cat /usr/bin/more && ln -sf /bin/cat /usr/bin/less` |
| `undefined reference to NCS::*` | Flattened ECW lib paths | Use original SDK structure with `lib/newabi/x64/release` |
| `/usr/local/share/gdal: not found` | GDAL build failed silently | Check build log for compile/link errors above |
| Log clipped at 2MB | BuildKit default limit | Set `maxSize = -1` in `~/.docker/buildkitd.toml` |
| TileServer not detecting new files | inotify not triggering | Check `docker compose logs tileserver` for watcher status |
| Port 8080 already in use | Another service on 8080 | Change port in `docker-compose.yml`: `"8081:8080"` |
