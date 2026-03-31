#!/bin/bash
set -e

DATA_DIR="/data"
CONFIG_FILE="$DATA_DIR/config.json"
TILESERVER_PID=""

# Generate config.json from all .mbtiles files in /data
generate_config() {
    echo "[entrypoint] Scanning $DATA_DIR for .mbtiles files..."

    # Start building the JSON
    local data_entries=""
    local first=true

    for mbtiles_file in "$DATA_DIR"/*.mbtiles; do
        [ -f "$mbtiles_file" ] || continue

        filename=$(basename "$mbtiles_file")
        # Derive the layer name from filename (without extension), replace spaces with underscores
        layer_name=$(echo "${filename%.mbtiles}" | tr ' ' '_')

        if [ "$first" = true ]; then
            first=false
        else
            data_entries="$data_entries,"
        fi

        data_entries="$data_entries
    \"$layer_name\": {
      \"mbtiles\": \"$filename\"
    }"
    done

    if [ -z "$data_entries" ]; then
        echo "[entrypoint] No .mbtiles files found in $DATA_DIR"
        # Write a minimal config with no data
        cat > "$CONFIG_FILE" << 'EMPTY_EOF'
{
  "options": {
    "paths": {
      "root": "/data",
      "mbtiles": ""
    }
  },
  "data": {}
}
EMPTY_EOF
    else
        cat > "$CONFIG_FILE" << CONF_EOF
{
  "options": {
    "paths": {
      "root": "/data",
      "mbtiles": ""
    }
  },
  "data": {$data_entries
  }
}
CONF_EOF
    fi

    echo "[entrypoint] Generated config.json with entries:"
    cat "$CONFIG_FILE"
}

# Start (or restart) tileserver-gl
start_tileserver() {
    # Kill previous instance if running
    if [ -n "$TILESERVER_PID" ] && kill -0 "$TILESERVER_PID" 2>/dev/null; then
        echo "[entrypoint] Stopping tileserver-gl (PID $TILESERVER_PID)..."
        kill "$TILESERVER_PID" 2>/dev/null || true
        wait "$TILESERVER_PID" 2>/dev/null || true
    fi

    echo "[entrypoint] Starting tileserver-gl..."
    node /usr/src/app/ --config "$CONFIG_FILE" &
    TILESERVER_PID=$!
    echo "[entrypoint] tileserver-gl started (PID $TILESERVER_PID)"
}

# Handle graceful shutdown
cleanup() {
    echo "[entrypoint] Shutting down..."
    if [ -n "$TILESERVER_PID" ] && kill -0 "$TILESERVER_PID" 2>/dev/null; then
        kill "$TILESERVER_PID" 2>/dev/null || true
        wait "$TILESERVER_PID" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

# Initial startup
generate_config
start_tileserver

# Watch for .mbtiles file changes (create, delete, move)
echo "[entrypoint] Watching $DATA_DIR for .mbtiles changes..."

# Use inotifywait to monitor for new/deleted/moved .mbtiles files
# --monitor keeps watching indefinitely
# We debounce by waiting a few seconds after an event before acting
inotifywait --monitor --event create --event delete --event moved_to --event moved_from \
    --format '%f %e' "$DATA_DIR" | while read -r FILENAME EVENT; do

    # Only react to .mbtiles files
    case "$FILENAME" in
        *.mbtiles)
            echo "[entrypoint] Detected $EVENT on $FILENAME — regenerating config..."
            # Small delay to allow file writing to complete (especially for large files)
            sleep 3
            generate_config
            start_tileserver
            ;;
    esac
done
