# omada

TP-Link Omada Software Controller, using the community image
[mbentley/omada-controller](https://github.com/mbentley/docker-omada-controller)
(v6.x, embedded MongoDB 8).

| | |
|---|---|
| UI | `https://<host>.local:8043` (self-signed cert) |
| Networking | `network_mode: host` (required for reliable L2 discovery/adoption) |
| State | `${DATA_DIR}` (default `/srv/omada/data`), includes `autobackup/` |
| CPU | MongoDB 8 needs AVX on amd64. The 2011 Mac mini's Sandy Bridge CPU has it. |
| RAM | Roughly 1–1.5 GB in use (Java + MongoDB) |

## Settings

| Key (stack.env) | host.env / secrets key | Meaning |
|---|---|---|
| `TZ` | `TZ` (global) | Controller time zone |
| `DATA_DIR` | `OMADA__DATA_DIR` | Controller data, bind-mounted |
| `LOGS_DIR` | `OMADA__LOGS_DIR` | Server and MongoDB logs |

There are no secrets. The controller admin account is created in the setup
wizard and lives in the controller's database, which the backups cover.

## First run

1. Add `omada` to `STACKS` in `hosts/<host>/host.env` and run bootstrap (or
   register the stack manually, see the top-level README).
2. Open `https://<host>.local:8043` and complete the wizard. Create a local
   admin and skip cloud access unless you want it.
3. **Before adopting anything:** Settings → Maintenance → Backup → turn on
   **Auto Backup** (e.g. daily, keep 7). Backups are written to
   `${DATA_DIR}/autobackup/`, so they sit on the host with the rest of the
   stack's state, ready for the backup job that comes later.
4. Adopt the switch: Devices → it should show as *Pending* → Adopt. If it
   doesn't appear, the controller and switch must be on the same L2 segment.
   Also check that nothing on the host is blocking UDP 29810.

> **Adoption locks the switch to the controller.** After adoption, the switch's
> standalone web UI no longer works. If you lose the controller *and* its
> backups, the only way back is a factory reset of the switch. Keep auto-backup
> on and download a manual backup before every upgrade.

## Upgrades

Renovate opens a PR when a new image is published. The tag and digest are
pinned, e.g. `6.3.0.45@sha256:…`.

1. Read the upstream release notes. Major versions (5→6, 6→7) can require a
   separate MongoDB migration while the controller is stopped.
2. Download a manual backup (Settings → Maintenance → Backup → Export).
3. Merge. Portainer picks up the change on its next poll (≤ 5 min).

You **cannot downgrade** after the controller migrates its database. Rolling
back means restoring a backup taken on the older version, into the older
version.

## Restore

On a fresh host, after bootstrap has deployed the stack:

1. Open the wizard, then choose **Restore from backup** and upload a `.cfg`
   from `autobackup/` or a manual export.
2. Restore into the same or a newer controller version, never an older one.
3. Devices reconnect on their own if the controller keeps the same IP. If the IP
   changed, set the controller address on each device or re-adopt it. This is
   why the host needs a fixed IP.

## Ports (host network)

| Port | Proto | Use |
|---|---|---|
| 8043 | tcp | Management UI (https) |
| 8088 | tcp | Management UI (http) / portal |
| 8843 | tcp | Captive portal (https) |
| 27001 | udp | Omada app discovery |
| 29810 | udp | Device discovery |
| 29811–29817 | tcp | Device management, adoption, upgrades |

If `ufw` is enabled on the host, these must be allowed from the LAN.
