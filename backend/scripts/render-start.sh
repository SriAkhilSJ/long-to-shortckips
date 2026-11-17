#!/bin/sh
# Starts the API and the video worker in one container.
#
# Used by render.yaml. A Render disk attaches to a single service, and the API
# and worker must share TEMP_DIR, so they run side by side here instead of as
# two services.
#
# The worker runs in the background; uvicorn stays in the foreground so the
# container's exit code and signals follow the web server. Render sends SIGTERM
# to PID 1 (this shell), so the trap forwards it to both children.

set -eu

export PYTHONPATH=/app

.venv/bin/python -m src.workers.run_workers &
worker_pid=$!

.venv/bin/uvicorn src.main:app --host 0.0.0.0 --port "${PORT:-8000}" &
api_pid=$!

term() {
    kill -TERM "$worker_pid" "$api_pid" 2>/dev/null || true
}
trap term TERM INT

# Wait for either process to exit; a crash in the worker must restart the
# container rather than leave the API serving without a queue consumer.
while kill -0 "$worker_pid" 2>/dev/null && kill -0 "$api_pid" 2>/dev/null; do
    sleep 2
done

term
wait "$api_pid" 2>/dev/null || true
wait "$worker_pid" 2>/dev/null || true
exit 1
