FROM python:3.12-slim

LABEL maintainer="TorrentBridge"
LABEL description="Two-stage torrent download and seed automation"
LABEL org.opencontainers.image.title="TorrentBridge"
LABEL org.opencontainers.image.version="0.1.0"

# Install rsync, openssh-client (for rsync over SSH), and curl
RUN apt-get update && apt-get install -y --no-install-recommends \
    rsync \
    openssh-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-privileged app user (runs as root inside container by default for Unraid compat)
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY app/ .

# Directories that should be mounted as volumes
VOLUME ["/config"]

# Config path for SSH keys and torrentbridge.json
ENV TB_CONFIG_PATH=/config/torrentbridge.json
ENV TB_LOG_LEVEL=INFO

# Health check — verify the web server is responding
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:${TB_WEB_PORT:-7474}/api/status || exit 1

EXPOSE 7474

CMD ["python", "-u", "main.py"]
