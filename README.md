# nginx_proxy_manager_build

Komodo stack running [Nginx Proxy Manager](https://nginxproxymanager.com/)
as hostname-based routing **behind a Cloudflare Tunnel**.

Designed to pair with
[cloudflare_tunnel_build](https://github.com/svnix-solutions/cloudflare_tunnel_build).

---

## Architecture

```
  Internet
     │
     ▼
  Cloudflare Edge          (TLS terminates here)
     │  (outbound-only QUIC/HTTP2)
     ▼
 ┌──────────────────────────────────────────────────┐
 │  Docker host                                     │
 │                                                  │
 │   ┌──────────────┐  "cloudflared" network        │
 │   │ cloudflared  │───────────┐                   │
 │   └──────────────┘           │                   │
 │                              ▼                   │
 │                     ┌──────────────────┐         │
 │                     │ nginx-proxy-     │         │
 │                     │ manager  :80     │         │
 │                     └────────┬─────────┘         │
 │                              │ routes by Host    │
 │            ┌─────────────────┼─────────────────┐ │
 │            ▼                 ▼                 ▼ │
 │        app-a:8080       app-b:3000    10.0.0.9:5050
 └──────────────────────────────────────────────────┘
```

Point a tunnel **Public Hostname** at `http://nginx-proxy-manager:80` and let
NPM route by `Host` header. Docker's embedded DNS resolves the container name
because both containers share the `cloudflared` network.

---

## No public ports

Ports 80 and 443 are deliberately **not published**. They exist only on the
`cloudflared` network, so the tunnel is the sole ingress and there is nothing
to firewall.

Only the admin UI is published, and it defaults to `127.0.0.1:81`. Set
`NPM_ADMIN_BIND` to a LAN address if you administer it from another machine.

---

## Do not use the Let's Encrypt tab

Cloudflare terminates TLS at its edge, so NPM should serve **plain HTTP** to
the tunnel.

Certificates in NPM are not merely redundant here — they cannot be issued.
HTTP-01 challenges require a publicly reachable port 80, which by design does
not exist in this topology. Leave the SSL tab alone, or use DNS-01 if you have
some separate reason to need a certificate.

---

## Setup

The external network must exist first, and Komodo will refuse to start the
stack otherwise:

```bash
docker network create cloudflared
cp .env.example .env    # then edit it
docker compose up -d
```

`NPM_ADMIN_EMAIL` and `NPM_ADMIN_PASSWORD` apply **only when the database is
first created**. Changing them later has no effect — change the password in
the NPM UI.

---

## Adding a backend

1. **Cloudflare Zero Trust → Networks → Tunnels → Public Hostname**
   Service: `http://nginx-proxy-manager:80`
2. **NPM → Hosts → Proxy Hosts → Add**
   Domain: the same hostname. Forward to either a container name on the
   `cloudflared` network, or a `host:port` reachable from this host.

Send one wildcard hostname to NPM and let it do the routing — that is the
point of having it in the path.

> Admin consoles reachable from the internet should sit behind a **Cloudflare
> Access** policy, not just the application's own login form.

---

## Backups

NPM keeps its state in SQLite **plus** files that are not in the database —
`keys.json` (JWT signing keys), access lists, custom certificates. So the
`/data` volume is what needs backing up, not just the database.

```bash
docker compose --profile backup run --rm backup
```

Output is `npm-data-<UTC timestamp>.tar.gz`, pruned after
`BACKUP_RETENTION_DAYS`.

The backup target is an **NFS-backed Docker volume** — the Docker daemon
performs the mount, so the host needs no `fstab` entry and no `nfs-common`.
That matters when Komodo's Periphery runs as an unprivileged container on the
host, since it cannot mount anything there itself. Set `NPMBACKUP_NFS_ADDR`
and `NPMBACKUP_NFS_EXPORT`; to use an already-mounted host path instead, see
the commented alternative in `compose.yaml`.

The target must contain a sentinel file:

```bash
docker run --rm -v npm_backup:/backup alpine:3 \
  sh -c 'echo sentinel > /backup/.npmbackup-target'
```

### Why it does not just copy the file

A plain `cp` of a live SQLite database can capture a **torn write** and produce
an archive that restores into a corrupt database — and you would not find out
until you needed it. The job instead uses SQLite's online backup API
(`.backup`), which is safe against concurrent writers, then runs
`pragma integrity_check` on the result.

That is also why the job runs on `alpine` rather than the NPM image: NPM ships
no `sqlite3` binary.

| Guard | Failure it prevents |
| --- | --- |
| `sqlite3 .backup` + `integrity_check` | a torn copy of a live database |
| `set -o pipefail` | a staging failure passing silently into the archive |
| write to `.partial`, `gzip -t`, `tar -tzf`, then rename | an interrupted run leaving a file that looks complete |
| sentinel file check | the NAS is not mounted, and "backups" fill local disk |

### Restoring

```bash
docker compose down
docker run --rm -v npm_data:/data -v npm_backup:/backup alpine:3 \
  sh -c 'rm -rf /data/* && tar -xzf /backup/npm-data-<ts>.tar.gz -C /data'
docker compose up -d
```

---

## Files

| File | Purpose |
| --- | --- |
| `compose.yaml` | the stack definition |
| `backup.sh` | snapshot `/data`, verify, prune |
| `.env.example` | template for `.env` |
