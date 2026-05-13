#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-8080}"
RESTART_DELAY="${RESTART_DELAY:-5}"
MAX_RESTARTS="${MAX_RESTARTS:-0}"   # 0 = unlimited

log() {
    echo "[ENTRYPOINT] $*"
}

if ! [[ "${RESTART_DELAY}" =~ ^[0-9]+$ ]]; then
    RESTART_DELAY="5"
fi

if ! [[ "${MAX_RESTARTS}" =~ ^[0-9]+$ ]]; then
    MAX_RESTARTS="0"
fi

# Start Python HTTP healthcheck (Railway expects an HTTP listener)
python3 -u -c "
import http.server

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK')
    def log_message(self, *a):
        pass

s = http.server.HTTPServer(('0.0.0.0', int('${PORT}')), H)
print('[ENTRYPOINT] Healthcheck on port ${PORT}', flush=True)
s.serve_forever()
" &
HEALTH_PID=$!

cleanup() {
    log "Shutting down..."
    kill "${HEALTH_PID}" 2>/dev/null || true
    pkill -f xmrig 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT EXIT

restart_count=0
while true; do
    log "Launching miner..."

    set +e
    bash "${SCRIPT_DIR}/start.sh"
    code=$?
    set -e

    log "Miner exited with code ${code}"
    restart_count=$((restart_count + 1))

    if (( MAX_RESTARTS > 0 )) && (( restart_count >= MAX_RESTARTS )); then
        log "Reached MAX_RESTARTS=${MAX_RESTARTS}, exiting with failure"
        exit 1
    fi

    log "Restarting miner in ${RESTART_DELAY}s (attempt ${restart_count})"
    sleep "${RESTART_DELAY}"
done
