# ECW-Auto

A Docker-based toolkit for working with **ECW geospatial imagery**. Builds a slim, optimized container with GDAL compiled from source with full ECW read support — no manual SDK installation required.

## Features

- **Multi-stage Docker build** — small runtime image (~1–1.5 GB) based on `debian:12-slim`
- **GDAL 3.4.1 + ECW SDK 5.4.0** — read ECW/JP2 files out of the box
- **Python ready** — includes `pyproj` in a virtual environment
- **Automated SDK install** — handles the ECW license prompt and pager issues automatically

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- `erdas-ecw-sdk-5.4.0-linux.zip` placed in the same directory as the Dockerfile

## Quick Start

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

Only runtime (non-dev) Debian packages are installed — no build tools, no `-dev` headers.

### 6. Copied from Builder

- `/usr/local/lib/` — GDAL shared libraries
- `/usr/local/bin/gdal_translate`, `gdalinfo`, `gdalwarp`, `nearblack`, `ogr*` — GDAL binaries
- `/usr/local/share/gdal/` — GDAL data files
- `/usr/local/hexagon_ecw/lib/newabi/x64/release/` — ECW runtime libraries only

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
docker run -it --name ecw-container -v "$(pwd)/workspace:/workspace" ecw-slim
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

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `--More-- (END)` hang during build | ECW installer pager | `ln -sf /bin/cat /usr/bin/more && ln -sf /bin/cat /usr/bin/less` |
| `undefined reference to NCS::*` | Flattened ECW lib paths | Use original SDK structure with `lib/newabi/x64/release` |
| `/usr/local/share/gdal: not found` | GDAL build failed silently | Check build log for compile/link errors above |
| Log clipped at 2MB | BuildKit default limit | Set `maxSize = -1` in `~/.docker/buildkitd.toml` |
