#!/bin/sh
# Starts the API and the video worker in one container.
#
# Used by render.yaml. A Render disk attaches to a single service, and the API
# and worker must share TEMP_DIR, so they run side by side here instead of as
# two services.
#
# Order matters: the worker refuses to start when Redis still holds a media
# volume id from a previous instance (see check_media_volume), which is exactly
# what happens on a host without a persistent disk. The API publishes this
# instance's id during startup, so the worker waits for the API to answer
# /health first.

set -eu

export PYTHONPATH=/app
PORT="${PORT:-8000}"

.venv/bin/uvicorn src.main:app --host 0.0.0.0 --port "$PORT" &
api_pid=$!

ready=0
i=0
while [ "$i" -lt 60 ]; do
    if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$api_pid" 2>/dev/null; then
        echo "API exited before it became healthy" >&2
        exit 1
    fi
    i=$((i + 1))
    sleep 2
done

if [ "$ready" -ne 1 ]; then
    echo "API did not become healthy within 120s" >&2
fi

.venv/bin/python -m src.workers.run_workers &
worker_pid=$!

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
