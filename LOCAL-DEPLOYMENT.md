# Local EE viability test

This is an internal, non-production evaluation of Alga PSA from the current `release/1.6.0` source. It uses the EE **production** Dockerfile (`ee/server/Dockerfile.build`), not `next dev` or a Windows source bind mount. The published `ghcr.io/nine-minds/alga-psa-ee:latest` image was inspected on 2026-09-20: its embedded build date is 2025-09-21 and it lacks the current `create-tenant` CLI. Do not use that image to judge current Level.io/Huntress support. No license key is injected or bypassed; use only within the permissions of `ee/license.md`.

From `C:\Users\marcm\alga-psa-release` in PowerShell:

```powershell
.\local-stack.ps1 -ValidateOnly   # validate config, no changes
.\local-stack.ps1                 # start or resume; build EE image if absent
.\local-stack.ps1 -Status         # show container state
.\local-stack.ps1 -Stop           # stop all Alga containers; keep data/images
.\local-stack.ps1 -Rebuild        # rebuild EE image after local source edits
.\local-stack.ps1 -Fresh          # new clean database and first admin; keeps old DB
.\local-stack.ps1 -Pull           # fast-forward upstream release, rebuild, start
.\local-stack.ps1 -Pull -SyncFork # also push updated branch to fork/local-release
```

The first build can take a long time and use substantial RAM/disk space; the source image currently occupies roughly 13 GB on disk. Runtime is much lighter: it runs the compiled production app, PostgreSQL, PgBouncer, Redis, Temporal, and Mailpit. PostHog, ClickHouse, Turbopack, filesystem polling, and optional source-built workers are **not** started. The build also embeds `NEXT_PUBLIC_ALGA_USAGE_STATS=false` so the browser bundle does not initialize PostHog. To exercise distributed workflows, IMAP ingestion, or the Temporal worker, use `-Workers` on startup; this incurs extra build and memory cost. Shut those down with `-Stop`. The normal `-Stop` never removes volumes.

On this Windows PC, the one-time source build left Docker Desktop holding about 40 GB of build memory even though the running containers used roughly 1 GB. After the build, `-Stop`, `docker desktop restart`, and a normal start released that allocation; the PC then had about 42 GB free with the stack running. This Docker Desktop restart is only a post-build remedy, not part of normal daily up/down. PostgreSQL, Redis, PgBouncer, and Temporal are not exposed to the host; only Alga (`127.0.0.1:3000`) and Mailpit (`127.0.0.1:1025/8025`) are bound locally.

The first start after Docker volumes were deleted automatically creates a clean database volume, runs migrations **without demo seeds**, and invokes the repository's `create-tenant` CLI to create the first admin and leave onboarding pending. The email defaults to `admin@local.test`; set `LOCAL_ADMIN_EMAIL` and `LOCAL_TENANT_NAME` in the ignored root `.env` before first start to change them. The generated temporary password is printed once, not stored in `.env`; save it and change it after login. `-Fresh` repeats this on a new volume, preserving the old one. A normal start keeps the existing database and login. Do not use `docker compose down -v` if you want to keep uploaded files; the external PostgreSQL volume is separately protected, but the files volume is Compose-managed.

Open Alga at http://localhost:3000 and Mailpit at http://localhost:8025. SMTP from the app is routed to Mailpit, so outbound test mail stays on this PC. It is **not** a production mail provider or an inbox/IMAP connector; configure those separately if the trial warrants it. Level.io and Huntress credentials belong in the application's integration settings UI, never in source or Compose. Their connection and ticket/device flows still need credential-backed smoke tests before being called working.

The repo's tenant CLI requires a local packaging correction in this branch: the EE production image now includes its imported EE helper and compiled DB package, and `packages/db/package.json` exposes the DB subpath to the CLI's CommonJS loader. The launcher mounts a short `local-bootstrap.sh` wrapper that reads the existing Docker admin secret without putting it in `.env` or a host command line. The CLI was used successfully and an authenticated session was verified. To recheck SMTP delivery, run `docker exec alga-psa-server-1 node /app/server/local-email-check.cjs` and inspect Mailpit; its inbox is intentionally ephemeral across `-Stop`.

For upstream maintenance, commit local Compose/script/docs changes first. `-Pull` fetches and merges `origin/release/1.6.0` into `local-release`; it refuses a dirty tree and stops before touching containers if the merge needs conflict resolution. It rebuilds only when upstream changed. `-SyncFork` pushes the resulting `local-release` branch to the configured `fork` remote after the app passes its health check, without force-pushing. For a new upstream release branch, review the migration/build changes and switch the tracked branch deliberately before updating this launcher. A future prebuilt EE image can replace the source build only after confirming its release/version and Level.io/Huntress code match this source; `latest` currently does not.

`G:\projects\alga-psa` remains a clean upstream source checkout. This `C:\Users\marcm\alga-psa-release` checkout owns the local deployment overrides and ignored runtime secrets. No separate PostHog stack is required for this evaluation; with usage statistics disabled, feature-flag defaults are used instead.
