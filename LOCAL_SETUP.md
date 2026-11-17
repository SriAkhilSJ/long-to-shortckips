# Running SupoClip natively on Windows

This checkout runs without Docker: PostgreSQL, Redis, the FastAPI backend, the
worker and Next.js all run as local processes. Docker Desktop is not installed
and WSL has no distribution, so `docker compose up` is not an option here.

## Start / stop

```powershell
powershell -ExecutionPolicy Bypass -File scripts/dev-local.ps1   # start everything
powershell -ExecutionPolicy Bypass -File scripts/stop-local.ps1  # stop everything
```

Logs land in `logs/`. URLs: app <http://localhost:3107>, API
<http://localhost:8000> (docs at `/docs`).

Start the worker exactly once. Two `run_workers` processes share the same Redis
queue, and the older one wins jobs with its own environment.

## Ports

| Service | Port | Notes |
|---|---|---|
| PostgreSQL | 5433 | Project-local cluster in `.pgdata`, user/password `supoclip` / `supoclip_password`. The machine-wide PostgreSQL 17 service on 5432 is untouched. |
| Redis | 6379 | `redis-server --save '' --appendonly no` |
| Backend | 8000 | |
| Frontend | 3107 | `pnpm run dev` |

## Configuration

- `.env` (repo root) is read by the backend through `python-dotenv`, which walks
  up from `backend/src`. It holds the API keys plus a "Local native dev
  overrides" block: `DATABASE_URL` on port 5433, `REDIS_HOST`/`REDIS_PORT`,
  `TEMP_DIR`, `MEDIA_STORAGE=local`.
- `frontend/.env.local` holds what Next.js needs. Next only reads env files in
  its own directory, so `DATABASE_URL`, `BETTER_AUTH_*`, `BACKEND_INTERNAL_URL`
  and the `NEXT_PUBLIC_*` values are duplicated there. Keep the two files in
  sync when a secret changes.

Current providers:

```dotenv
TRANSCRIPTION_PROVIDER=assemblyai
ASSEMBLY_AI_API_KEY=...
OPENAI_API_KEY=<Velona key>
OPENAI_BASE_URL=https://velona.in/v1
LLM=openai:deepseek/deepseek-v4-flash
```

Velona is an OpenAI-compatible gateway, so it is wired through the `openai`
provider: pydantic-ai reads `OPENAI_BASE_URL` from the environment, and the model
id keeps its vendor prefix (`openai:deepseek/...`). `PEXELS_API_KEY` stays empty;
B-roll falls back to no key.

## Database bootstrap (first run only)

`init.sql` is stale relative to `frontend/prisma/schema.prisma`, so it is not the
right bootstrap for a new database. What works:

```powershell
# 1. Prisma owns the auth/user tables.
cd frontend
$env:DATABASE_URL="postgresql://supoclip:supoclip_password@127.0.0.1:5433/supoclip"
pnpm exec prisma migrate deploy

# 2. The backend creates its own SQLAlchemy tables (generated_clips,
#    processing_cache, api_keys, media_*, editor_*, ...) at startup.
cd ..\backend
uv run uvicorn src.main:app --host 127.0.0.1 --port 8000
```

A fresh cluster:

```powershell
& 'C:\Program Files\PostgreSQL\17\bin\initdb.exe' -D .pgdata -U supoclip --pwfile=pw.txt -E UTF8 --locale=C
& 'C:\Program Files\PostgreSQL\17\bin\postgres.exe' -D .pgdata -p 5433
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -U supoclip -p 5433 -d postgres -c "CREATE DATABASE supoclip;"
```

## Windows portability shims

The backend assumes POSIX in three places. Two are local patches, one is a
shim on `PYTHONPATH`:

1. `backend/.win-compat/fcntl.py` — `fcntl.flock` (used for media leases and
   download locks) mapped onto `msvcrt` byte-range locks. `scripts/dev-local.ps1`
   and every manual command must set
   `$env:PYTHONPATH="<repo>\backend\.win-compat"`. Linux and Docker keep using
   the real `fcntl`.
2. `backend/src/media/upload_ingest.py` and
   `backend/src/repositories/upload_repository.py` — the "fsync the directory
   entry" step is skipped on Windows, which cannot open a directory. Uploads
   returned `[Errno 13] Permission denied` before this guard.

`os.link("/proc/self/fd/...")` in `publish_spooled_upload` already falls back to
a streamed copy when the link fails, which is what happens on Windows.

## What was verified

A 42 s 640x360 test upload went through the whole pipeline: AssemblyAI
transcription, clip selection through Velona (`deepseek/deepseek-v4-flash`),
ffmpeg render. Result: one 1080x1920, 31 s clip with burned-in captions, score
79, title "Habit beats the masterpiece".
