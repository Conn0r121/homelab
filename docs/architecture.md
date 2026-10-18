# Architecture decisions

Short records of why the repo looks the way it does. Update a record when its
decision changes, rather than leaving it to drift from the code.

## 1. One infra repo, one Portainer stack per `stacks/<name>/`

All deployable configuration lives here. App repos (e.g. `e-paper`) stay
separate and publish images. This repo references those images by pinned tag.

A stack is a directory with three files:

- `docker-compose.yml`: no host-specific values inline.
- `stack.env.example`: the stack's contract, i.e. every variable it needs.
- `README.md`: settings, first run, upgrade, restore.

## 2. Portainer CE stays; the repo is the source of truth

Portainer gives a UI and Git polling. Its database is treated as disposable:
everything it holds (stacks, env vars, Git credentials) is recreated from this
repo and the encrypted secrets by `bootstrap.sh`.

Portainer is run from `platform/portainer/` by bootstrap, **not** as a
Portainer stack, because a stack that updates Portainer would stop its own
deployer partway through.

*Alternative considered:* plain `docker compose` plus a systemd timer doing
`git pull`. It has fewer moving parts, but gives up the UI. That trade-off
could be revisited later.

## 3. Secrets: sops + age, encrypted in the repo

- `hosts/<host>/secrets.sops.env` is encrypted with age in dotenv format.
- The age private key exists in two places only: your password manager and
  `/etc/homelab/age.key` (root, 0600) on each host.
- Bootstrap decrypts in memory. Plaintext is never written to disk.
- Rebuilding a host means: install Ubuntu, clone, place the age key, run
  bootstrap.
- There is one key for now. Per-host keys can be added later as extra
  `creation_rules` in `.sops.yaml`, then running `sops updatekeys`.

## 4. Public repo; no Git credentials anywhere

The repo is public. Secrets are sops-encrypted, so what's visible is the
service inventory, folder layout, time zone and the *names* of secret keys.
There are no IPs and no secret values.

In exchange, there's no Git authentication at all: Portainer and the host
checkout clone anonymously, so there's no token to expire, rotate or lose. The
repo started private with a fine-grained PAT. That PAT was the main source of
friction, so it was dropped.

If the repo ever goes private again, set `PORTAINER_GIT_USERNAME` and
`PORTAINER_GIT_TOKEN` in a host's secrets. Bootstrap passes them to the
Portainer Git source when present.

## 5. Polling every 5 minutes, not webhooks

Webhooks would require GitHub to reach Portainer from the internet. Polling
needs no inbound exposure.

In Portainer 2.45 the polling interval and the credentials live on a
**Git source** (one per repo), and stacks reference that source by `SourceID`.

Any commit changes the repo hash, so every stack re-runs `compose up`. That is
a no-op for stacks whose files didn't change, because images are pinned and
re-pull is off.

## 6. Configuration: `host.env` + secrets → per-stack env

```
hosts/<host>/host.env         non-secret: TZ, paths, STACKS, repo URL
hosts/<host>/secrets.sops.env secret: Portainer admin, DB passwords
stacks/<s>/stack.env.example  which keys stack <s> receives
```

For each key in a stack's example, bootstrap looks up `<STACK>__KEY` first,
then `KEY`, and fails if neither exists. Only the keys a stack declares are
sent to it, so one stack never sees another stack's secrets.

The prefix lets stacks keep upstream variable names. For example, Immich's
`DB_PASSWORD` comes from `IMMICH__DB_PASSWORD`, so the Immich compose file
stays close to the official one, which makes upgrades a simple diff.

Any `*_DIR` or `*_LOCATION` key holding an absolute path is created on the
host if missing. Existing directories are never re-owned.

### How Portainer applies it (verified against Portainer 2.45.2 source)

- Env vars set through the API are written to `stack.env` in the **root of
  Portainer's clone** (`api/exec/compose_stack.go`, `createEnvFile`).
- Compose runs with the **clone root as its working directory**
  (`libstack.Options{WorkingDir: stack.ProjectPath}`). Relative paths in a
  compose file under `stacks/<s>/` therefore resolve against the repo root.
  That means `env_file: stack.env` finds Portainer's file.
- The same file is also passed as `--env-file`, so `${VAR}` interpolation
  works too. Omada uses interpolation; Immich will use `env_file:`, following
  the upstream compose file.
- A `.env` next to a compose file would be merged into `stack.env` by
  Portainer. `.env` is gitignored for that reason.
- Relative bind mounts that pull files out of the repo (Portainer's "relative
  path volumes") are **Business Edition only**. Config that has to come from
  the repo into a container (e.g. Home Assistant YAML) will use a git-sync
  sidecar instead.

## 7. Storage: paths are host settings

Every data path is a `host.env` value. On the Mac mini the plan is:

- Now: everything on the HDD (`DB_STORAGE_TYPE=HDD` for Immich).
- When the SSD arrives: OS, `/srv/*` and all databases on the SSD; bulk media
  (Immich library) stays on the HDD. The move is: edit `host.env`, rsync, re-run
  bootstrap.

Immich's docs require its database on local SSD storage, never a network share.

## 8. Upgrades: Renovate with pinned tags and digests

- Images are pinned as `tag@sha256:digest`, so rebuilds under the same tag
  also show up as PRs.
- Stateful images are never automerged. Majors wait for approval on the
  dependency dashboard.
- Immich server and machine-learning will be grouped, because their versions
  must match.
- Portainer upgrades need a bootstrap re-run (see decision 2). The Renovate PR
  says so.

## 9. Bootstrap is bash, for now

There are one or two hosts and a short list of steps, so Ansible's
control-node dependency isn't worth it yet. Each step checks state before
acting.

Revisit when the Raspberry Pi rejoins or the host count passes about three.

## 10. Names over IPs

Bootstrap installs avahi, so each host answers as `<hostname>.local` over
mDNS. Windows resolves `.local` names natively. The Spectrum router may not
allow local DNS records, so mDNS is the zero-infrastructure option.

Hosts should keep a stable IP, because Omada devices find their controller by
IP. The Spectrum router can't do DHCP reservations, so for now the Mac mini
stays on plain DHCP. An always-on wired host keeps its lease in practice. A
static netplan address was rejected because the router's DHCP pool isn't
visible, so a static address could collide with one the router hands out.
The planned fix is an Omada gateway behind the Spectrum router, which gives
reservations, local DNS and VLANs.
