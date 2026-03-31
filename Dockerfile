# ==============================================================
# Stage 1: BUILDER compile GDAL with ECW support
# ==============================================================
FROM debian:12-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install all build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake libproj-dev libgeos-dev \
    libsqlite3-dev libtiff-dev libgeotiff-dev libcurl4-openssl-dev \
    libpng-dev libjpeg-dev libgif-dev libwebp-dev libopenjp2-7-dev \
    libexpat1-dev libxerces-c-dev libpq-dev libhdf5-dev libnetcdf-dev \
    libpoppler-dev libfreexl-dev libspatialite-dev libcfitsio-dev \
    liblzma-dev libzstd-dev swig python3-dev python3-numpy wget unzip \
    python3-venv expect ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy and install ECW SDK
COPY erdas-ecw-sdk-5.4.0-linux.zip /tmp/
WORKDIR /tmp
RUN ln -sf /bin/cat /usr/bin/more && ln -sf /bin/cat /usr/bin/less && \
    unzip erdas-ecw-sdk-5.4.0-linux.zip && \
    chmod +x ERDAS_ECWJP2_SDK-5.4.0.bin && \
    echo 'set timeout -1' > install.exp && \
    echo 'spawn ./ERDAS_ECWJP2_SDK-5.4.0.bin' >> install.exp && \
    echo 'expect "*or 6]*"' >> install.exp && \
    echo 'send "1\r"' >> install.exp && \
    echo 'expect {' >> install.exp && \
    echo '    "*--More--*" { send " "; exp_continue }' >> install.exp && \
    echo '    "*Press ENTER*" { send "\r"; exp_continue }' >> install.exp && \
    echo '    "*Do you accept this License Agreement?*" { send "yes\r" }' >> install.exp && \
    echo '}' >> install.exp && \
    echo 'expect eof' >> install.exp && \
    expect install.exp && \
    # Move the entire SDK (preserving original directory structure GDAL expects)
    mv /hexagon/ERDAS-ECW_JPEG_2000_SDK-5.4.0/Desktop_Read-Only /usr/local/hexagon_ecw && \
    rm -rf /tmp/erdas-ecw-sdk-5.4.0-linux.zip /tmp/ERDAS_ECWJP2_SDK-5.4.0.bin /hexagon /tmp/install.exp

# Configure ECW library path
RUN echo '/usr/local/hexagon_ecw/lib/newabi/x64/release' > /etc/ld.so.conf.d/ecw.conf && ldconfig

# Download, Build, Install, and Strip GDAL
RUN wget -q https://github.com/OSGeo/gdal/releases/download/v3.4.1/gdal-3.4.1.tar.gz && \
    tar -xzf gdal-3.4.1.tar.gz && \
    cd gdal-3.4.1 && \
    ./configure --with-unix-stdio-64=no \
        --with-ecw=/usr/local/hexagon_ecw \
        --with-ecw-lib=/usr/local/hexagon_ecw/lib/newabi/x64/release && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    # Strip debug symbols to save space
    strip --strip-unneeded /usr/local/lib/libgdal.so* || true && \
    strip --strip-unneeded /usr/local/bin/gdal* /usr/local/bin/ogr* /usr/local/bin/nearblack || true && \
    # Clean up source
    cd /tmp && \
    rm -rf /tmp/gdal-3.4.1 /tmp/gdal-3.4.1.tar.gz

# ==============================================================
# Stage 2: RUNTIME slim image with only what's needed
# ==============================================================
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install ONLY runtime libraries (no -dev, no build tools)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libproj25 libgeos-c1v5 libgeos3.11.1 \
    libsqlite3-0 libtiff6 libgeotiff5 \
    libcurl4 libpng16-16 libjpeg62-turbo libgif7 libwebp7 libopenjp2-7 \
    libexpat1 libxerces-c3.2 libpq5 libhdf5-103-1 libnetcdf19 \
    libpoppler126 libfreexl1 libspatialite7 libcfitsio10 \
    liblzma5 libzstd1 \
    python3 python3-numpy python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Copy GDAL binaries, libraries, and data from builder
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/bin/gdal_translate /usr/local/bin/
COPY --from=builder /usr/local/bin/gdalinfo /usr/local/bin/
COPY --from=builder /usr/local/bin/gdalwarp /usr/local/bin/
COPY --from=builder /usr/local/bin/nearblack /usr/local/bin/
COPY --from=builder /usr/local/bin/ogr* /usr/local/bin/
COPY --from=builder /usr/local/share/gdal/ /usr/local/share/gdal/

# Copy ECW runtime libraries (only the release libs needed at runtime)
COPY --from=builder /usr/local/hexagon_ecw/lib/newabi/x64/release/ /usr/local/hexagon_ecw/lib/newabi/x64/release/

# Configure library paths and symlinks
RUN echo '/usr/local/hexagon_ecw/lib/newabi/x64/release' > /etc/ld.so.conf.d/ecw.conf && \
    rm -f /usr/local/lib/libNCSEcw.so* && \
    ln -s /usr/local/hexagon_ecw/lib/newabi/x64/release/libNCSEcw.so.5.4.0 /usr/local/lib/libNCSEcw.so.5.4.0 && \
    ln -s /usr/local/lib/libNCSEcw.so.5.4.0 /usr/local/lib/libNCSEcw.so.5.4 && \
    ln -s /usr/local/lib/libNCSEcw.so.5.4 /usr/local/lib/libNCSEcw.so.5 && \
    ln -s /usr/local/lib/libNCSEcw.so.5 /usr/local/lib/libNCSEcw.so && \
    ldconfig

# Create Python Virtual Environment and install pyproj
RUN python3 -m venv /opt/venv
ENV PATH="/usr/local/bin:/opt/venv/bin:${PATH}"
RUN pip install --no-cache-dir pyproj

WORKDIR /workspace
CMD ["bash"]

# ==============================================================
# TODOs (lightweight-compatible improvements)
# ==============================================================
# TODO: Update GDAL to 3.8.x or 3.9.x for bug fixes and performance improvements
# TODO: Add gdal2tiles.py to support direct tile generation (small footprint)
# TODO: Consider adding a non-root user for security (adduser --system gdal)
# TODO: Add HEALTHCHECK instruction if using in orchestrated environments
# TODO: Pin base image hash for reproducible builds (debian:12-slim@sha256:...)
# TODO: Add .dockerignore to exclude unnecessary files from build context