# Deploying SupoClip

## Vercel: frontend only, not the app

Vercel cannot host SupoClip as it runs:

- **No long-running worker.** Transcription, clip selection and rendering are ARQ
  jobs in `backend/src/workers`. Rendering one clip is minutes of ffmpeg; a
  Vercel function is capped at 300 s (and 60 s on Hobby).
- **No ffmpeg, fonts, tesseract or torch.** The backend image installs all four;
  the serverless runtime has none of them.
- **No writable disk.** `TEMP_DIR` holds the source video, the normalized copy,
  the audio track and the rendered clips. Serverless filesystems are read-only
  except `/tmp`, which is per-invocation.
- **No Redis.** The ARQ queue is Redis-backed.

The Next.js frontend *can* live on Vercel (point `NEXT_PUBLIC_API_URL` and
`BACKEND_INTERNAL_URL` at the Render API and give it the same `DATABASE_URL`),
but the backend, worker, Postgres and Redis still need a container host.

## Render: yes

`render.yaml` in the repo root is a Blueprint with:

| Resource | Type | Plan | Why |
|---|---|---|---|
| `supoclip-web` | Docker web service | 1c-2g | API + video worker in one container, 10 GB disk at `/app/uploads` |
| `supoclip-app` | Docker web service | 0.5c-512mb | Next.js production runner |
| `supoclip-db` | Postgres 17 | free | Tasks, users, clips metadata |
| `supoclip-redis` | Key Value | free | ARQ queue |

API and worker share one container because a Render disk attaches to a single
service, and both need the same `TEMP_DIR`. If you later split them, move media
to S3/R2 (`MEDIA_STORAGE=s3`) so neither needs the other's disk.

Rough cost at the plans above: ~$32/month (1c-2g web + 0.5c-512mb web) plus the
free Postgres and Key Value tiers. The free web plan cannot be used: no disks,
and services sleep after 15 minutes of inactivity.

### 1. Create the Blueprint

1. Push this repo to GitHub.
2. In Render: **New → Blueprint**, pick the repo, keep `render.yaml`, apply.
3. Render prompts for the two `sync: false` secrets:
   - `ASSEMBLY_AI_API_KEY`
   - `OPENAI_API_KEY` (the Velona key; `OPENAI_BASE_URL` and `LLM` are already
     set to `https://velona.in/v1` and `openai:deepseek/deepseek-v4-flash`)

`BETTER_AUTH_SECRET`, `BACKEND_AUTH_SECRET` and `APP_SETTINGS_ENCRYPTION_KEY` are
generated once by Render and shared with the frontend through `fromService`, so
sign-in works across both services without copy-pasting secrets.

### 2. Check the URLs

The blueprint assumes:

- API: `https://supoclip-web.onrender.com`
- App: `https://supoclip-app.onrender.com`

If Render assigned different subdomains (names are global), update these five
variables and redeploy `supoclip-app` — `NEXT_PUBLIC_*` values are baked into
the browser bundle at build time:

- `supoclip-app`: `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_APP_URL`, `BETTER_AUTH_URL`
- `supoclip-web`: `CORS_ORIGINS`, `NEXT_PUBLIC_APP_URL`

### 3. Create the Prisma tables (once)

The backend creates its own SQLAlchemy tables on boot, but the auth/user tables
come from Prisma. The frontend image is a standalone Node server without the
Prisma CLI, so run the migration from your machine against Render's **external**
database URL (Render → `supoclip-db` → Connect → External):

```powershell
cd frontend
$env:DATABASE_URL="postgresql://...external..."
pnpm install --frozen-lockfile
pnpm exec prisma migrate deploy
```

Repeat after pulling changes that add migrations. Then open the app, sign up, and
run one generation end to end.

### Notes

- `DATABASE_URL` from Render is a plain `postgresql://` URL; the backend rewrites
  it to `postgresql+asyncpg://` when it builds the async engine.
- Media lives on the web service's disk, so a redeploy keeps uploads but a
  service delete does not. Move to `MEDIA_STORAGE=s3` for anything real.
- `MAX_VIDEO_UPLOAD_BYTES` stays at 4 GB; the disk is 10 GB and holds the source,
  the normalized copy, the audio track and the clips.
- The worker is started next to uvicorn by `dockerCommand`, so one service holds
  both. Start it once — two workers on the same Redis queue fight over jobs.
