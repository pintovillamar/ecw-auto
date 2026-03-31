FROM maptiler/tileserver-gl:latest

USER root

# Install inotify-tools for filesystem event watching
# and jq for JSON manipulation
RUN apt-get update && apt-get install -y --no-install-recommends \
    inotify-tools \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Copy the custom entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
