# homelab

Infrastructure as code for my home servers: Docker Compose stacks deployed by
Portainer (GitOps polling), secrets encrypted with sops + age, and one
idempotent bootstrap script that turns a fresh Ubuntu host into a running
server.

| Stack | Host | Status |
|---|---|---|
| [omada](stacks/omada/) | macmini | ready |
| immich | macmini | planned |
| homeassistant, esphome | macmini | planned (migrating from the Pi) |

Design decisions and their reasons are in [docs/architecture.md](docs/architecture.md).

## Layout

```
bootstrap.sh                 converge a host: packages, Docker, sops, Portainer, stacks
lib/                         bootstrap internals (install, Portainer API, dotenv loader)
platform/portainer/          Portainer itself (run by bootstrap, not GitOps)
hosts/<host>/host.env        non-secret per-host settings (paths, TZ, STACKS)
hosts/<host>/secrets.sops.env  encrypted per-host secrets
hosts/_template/             starting point for a new host
stacks/<name>/               one Portainer stack: docker-compose.yml, stack.env.example, README.md
scripts/validate.sh          CI checks (compose renders, no plaintext secrets, shellcheck)
```

## How configuration flows

Each stack's `stack.env.example` lists the keys it needs. Bootstrap resolves
each key from `host.env` and the decrypted secrets, looking up `<STACK>__KEY`
first and then plain `KEY`. It sends only those keys to that stack in
Portainer. Portainer writes them to `stack.env` and runs compose with them.
Example for omada on the Mac mini:

```
host.env: TZ=America/New_York          ->  omada gets TZ=America/New_York
host.env: OMADA__DATA_DIR=/srv/omada/data  ->  omada gets DATA_DIR=/srv/omada/data
```

## One-time setup (on your PC)

Install the tools:

```bash
winget install --id FiloSottile.age
winget install --id SecretsOPerationS.SOPS
```

1. **Create the age key**, the one secret everything else depends on:
   ```bash
   age-keygen -o homelab.agekey
   ```
   Save the whole file in your password manager, then delete the local copy, or
   keep it at `%APPDATA%\sops\age\keys.txt` so sops on this PC can decrypt.
   Put the printed public key (`age1…`) into `.sops.yaml` and commit it. The
   public key is not secret.
2. **Create a fine-grained PAT** for Portainer at GitHub → Settings → Developer
   settings → Fine-grained tokens:
   - Repository access: only `homelab`
   - Permissions: Contents → Read-only
   - Choose an expiry and put a reminder in your calendar.
3. **Write the host's secrets.** This opens an editor and saves the file
   encrypted, so plaintext never touches disk. Keys are listed in
   [hosts/_template/secrets.env.example](hosts/_template/secrets.env.example).
   ```bash
   sops edit hosts/macmini/secrets.sops.env
   ```
   On Windows, set an editor first, e.g. `$env:EDITOR = "code --wait"`.
   Commit the encrypted file.
4. **Enable Renovate:** install the [Renovate GitHub App](https://github.com/apps/renovate)
   on this repo only. It reads `renovate.json` and opens a dependency dashboard issue.

## Bootstrap a new host

Prerequisites:
- Ubuntu Server (22.04 or 24.04), wired network.
- A stable IP. A DHCP reservation is best. Without one (the current Spectrum
  router can't do reservations), plain DHCP is fine for an always-on wired host,
  as long as you use `<hostname>.local` instead of the IP. If the address ever
  changes, Omada devices may need to be reconnected to the controller.
- `hosts/<hostname>/` exists in the repo with `host.env` and `secrets.sops.env`.

On the host:

```bash
# 1. Clone. Git asks for credentials: use your GitHub username and a PAT with
#    read access to this repo (the Portainer PAT works). They aren't stored.
sudo git clone https://github.com/Conn0r121/homelab.git /opt/homelab

# 2. Install the age private key (paste the full key file contents, then Ctrl-D).
sudo install -d -m 0700 /etc/homelab
sudo sh -c 'umask 077; cat > /etc/homelab/age.key'

# 3. Converge. Pass the host profile name if it differs from `hostname -s`.
sudo /opt/homelab/bootstrap.sh macmini
```

Bootstrap installs `curl jq git age avahi-daemon`, Docker Engine (from Docker's
apt repo, unless Docker is already present) and sops (pinned version, checksum
verified). It then starts Portainer at `https://<hostname>.local:9443`, creates
the admin user, registers this repo as a Git source and deploys every stack in
`STACKS`. Re-running it is safe: unchanged things are reported as `ok` and left
alone.

### Existing Portainer

If the host already runs Portainer that was started some other way (e.g.
`docker run --name portainer`), bootstrap **stops before touching it**. Choose
one:

- **Start fresh.** `docker stop portainer && docker rm portainer`, keeping its
  volume as a rollback, then re-run bootstrap. Containers from old stacks keep
  running but show as unmanaged in the new Portainer.
- **Keep its data.** Copy the old data volume into `PORTAINER_DATA_DIR`, set
  `PORTAINER_ADMIN_PASSWORD` to the existing admin password, remove the old
  container and re-run bootstrap. The old stacks stay managed.

## Day-to-day

| Task | How |
|---|---|
| Change a stack | Edit `stacks/<s>/docker-compose.yml`, open a PR, merge. Portainer redeploys within 5 minutes. |
| Change a host setting or secret | Edit `host.env` / `sops edit …secrets.sops.env`, merge, then on the host: `cd /opt/homelab && sudo git pull && sudo ./bootstrap.sh <host>` |
| Upgrade an image | Review and merge the Renovate PR (read the stack README's upgrade notes first). |
| Upgrade Portainer | Merge the Renovate PR, then `git pull` and re-run bootstrap on each host. |
| Rotate the Portainer PAT | Create a new PAT, `sops edit` it in, merge, re-run bootstrap (it updates the Git source). |
| Validate before pushing | `./scripts/validate.sh` (needs Docker; shellcheck is optional locally). |

## Add a stack

1. Create `stacks/<name>/docker-compose.yml`. Pin images as `tag@sha256:…`.
   Reference host values as `${VAR}` or via `env_file: stack.env`.
2. List every variable it needs in `stacks/<name>/stack.env.example`.
3. Add the values to `hosts/<host>/host.env` (prefix with `<NAME>__`) or secrets,
   and add `<name>` to `STACKS`.
4. Write `stacks/<name>/README.md` covering settings, first run, upgrade and restore.
5. PR → merge → re-run bootstrap on the host (only needed when adding a stack
   or changing its settings).

## Register a stack manually (without bootstrap)

This is useful for trying a stack on a host that wasn't bootstrapped. In
Portainer 2.45:

1. Create the data directories on the host (e.g. `sudo mkdir -p /srv/omada/{data,logs}`).
2. **Stacks → Add stack → Repository.** Use (or create) a Git source for
   `https://github.com/Conn0r121/homelab.git` with your username and the PAT,
   and set polling to `5m`.
3. Reference `refs/heads/main`, compose path `stacks/<name>/docker-compose.yml`.
4. Under environment variables, add every key from `stack.env.example` with
   this host's values (or upload a filled-in copy as a `.env` file).
5. Deploy.

The next bootstrap run adopts a stack with the same name, as long as it's
Git-backed.
