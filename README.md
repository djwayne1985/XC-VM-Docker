# XC_VM Docker

## Env File Setup (Edit Before Deploy)

The stack reads settings from `.env` in this folder.

| Variable | Default | Purpose |
|---|---|---|
| `UPDATE_ON_START` | `false` | `false` keeps current install on restart; `true` checks/updates install on startup. |
| `MYSQL_REMOTE_USER` | `xcvm_admin` | External MariaDB account created by entrypoint. |
| `MYSQL_REMOTE_PASSWORD` | `ChangeMeNow123!` | Password for external MariaDB account. |
| `PANEL_RESET_ON_START` | `true` | Reapply panel admin credentials from `.env` during startup. |
| `PANEL_ADMIN_USERNAME` | `admin@Fladnag2018` | Panel admin username to enforce. |
| `PANEL_ADMIN_PASSWORD` | `AdminPass123!` | Panel admin password to enforce. |
| `START_COMMAND` | `sleep infinity` | Container keepalive command after startup routines. |

Recommended first-time actions:
1. Open `.env` and change at least:
   - `MYSQL_REMOTE_PASSWORD`
   - `PANEL_ADMIN_PASSWORD`
2. Save `.env`.
3. Recreate container so new values apply:
   - `docker compose up -d --build --force-recreate`
4. Verify startup used env values:
   - `docker compose logs --tail 200 xc-vm`

If login/access code issues happen after changing `.env`, recreate again:
- `docker compose down`
- `docker compose up -d --build`

## XC_VM Docker - Quick Start (First-Time Build)

1. Open terminal in this folder:
   - `cd /path/to/xc-vm-docker`
2. Ensure entrypoint is executable:
   - `chmod +x entrypoint.sh`
3. Build and start the container:
   - `docker compose up -d --build`
4. Check container status:
   - `docker compose ps`
5. View startup logs:
   - `docker compose logs --tail 250 xc-vm`
6. Print panel URL line only:
   - `docker compose logs --tail 300 xc-vm | grep "XC_VM Panel URL"`

## Notes

- If you edit `.env`, recreate the stack to apply changes:
  - `docker compose up -d --build --force-recreate`
- For a full reset/restart cycle:
  - `docker compose down`
  - `docker compose up -d --build`
