#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=${PORT:-8080}

# Start Python HTTP healthcheck (Railway requires HTTP endpoint)
python3 -c "
import http.server, threading, os

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK')
    def log_message(self, *a): pass

s = http.server.HTTPServer(('0.0.0.0', int('${PORT}')), H)
print(f'[INFO] Healthcheck on port ${PORT}')
s.serve_forever()
" &
HEALTH_PID=$!

trap "kill $HEALTH_PID 2>/dev/null; pkill -f xmrig 2>/dev/null; exit 0" SIGTERM SIGINT EXIT

# Start miner
bash "${SCRIPT_DIR}/start.sh"
