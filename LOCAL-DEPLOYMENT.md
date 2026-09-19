# Local Alga PSA test deployment

This worktree follows `origin/release/1.6.0` on the local `local-release` branch. The upstream Compose and application files are unchanged. Local Compose changes are in `compose.yaml`; ignored `.env` files and `secrets/` hold runtime configuration. The three version-specific PostHog source adapters are under `local-overrides/` and mounted read-only by Compose.

Run from this directory (`C:\Users\marcm\alga-psa-release`) in PowerShell:

```powershell
.\local-stack.ps1 -ValidateOnly  # check local configuration without changing containers
.\local-stack.ps1                # rebuild/recreate, keep the selected database and login
.\local-stack.ps1 -Pull          # fetch/merge upstream release/1.6.0, then rebuild/recreate
.\local-stack.ps1 -Fresh         # new empty database and new tenant/admin login
```

`-Fresh` prompts for `FRESH`, stops only the Alga Compose project, creates a new named PostgreSQL volume, runs setup/migrations/seeds, and creates a tenant/admin. It prints the new email/password and saves them as `LOCAL_ADMIN_EMAIL` and `LOCAL_ADMIN_PASSWORD` in the ignored root `.env`. Set `LOCAL_ADMIN_EMAIL` and `LOCAL_TENANT_NAME` there before running if you want different names. The previous PostgreSQL volume is kept; to return to it, set `ALGA_PG_VOLUME` in `.env` to its previous name and run the normal command. The normal command never creates a new login or removes a volume.

For source updates within this release branch, `-Pull` fetches `origin/release/1.6.0` from Nine-Minds and merges it into `local-release` before touching containers. Push the updated branch to your fork with `git push fork local-release`. To switch to a newer release branch or tag, fetch and switch Git yourself first, then run the normal command. Review the three `local-overrides/` files against their new upstream equivalents before building. The local files to retain are `compose.yaml`, `local-stack.ps1`, `LOCAL-DEPLOYMENT.md`, `.gitattributes`, `Dockerfile.dev.dockerignore`, `local-overrides/`, the ignored `.env` and `server/.env`, and `secrets/`. The PostgreSQL volume is external to Compose so even `docker compose down -v` cannot remove it.

PostHog is a separate local stack under `C:\Users\marcm\alga-psa-source-ee\.posthog-local`, exposed at `http://localhost:8010`. The Alga Compose file points to it, but does not own or remove its containers. Mailpit is at `http://localhost:8025`; the application is at `http://localhost:3000`.

On this Windows host, running PostHog's full auxiliary set alongside Alga exhausted the paging file. The PostHog worker, plugins, livestream, and two personhog containers are currently stopped with their Docker restart policies disabled. The web UI and event capture/ingestion were verified, but advanced PostHog background features may need those services and more host memory. A direct `docker compose up` in the separate PostHog project may restore its original restart policies.

The original `G:\projects\alga-psa` checkout is clean upstream source and is not the live bind-mounted source. Do not delete the old `C:\Users\marcm\alga-psa-source-ee` directory until PostHog's bind mounts have been migrated separately.
