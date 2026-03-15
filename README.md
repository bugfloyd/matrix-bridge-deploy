# matrix-bridge-deploy — Secure Matrix Messaging

A fully automated Ansible deployment of [Matrix](https://matrix.org/) (Synapse) + [Element Web](https://element.io/) for secure messaging with E2E encryption.

Supports multi-region deployment with two distinct connectivity profiles:

- **Iran** — limited/no direct internet; uses SSH-tunneled proxy for apt, Iranian Docker registry mirrors for images, and locally-obtained TLS certificates pushed to the server.
- **Europe** — direct internet access; pulls images from Docker Hub, runs certbot on-server for TLS via Cloudflare DNS-01.

Both regions use the same playbook, with per-region variable files controlling behavior.

**Key properties:**

- End-to-end encrypted messages — if the server is seized, message content is unreadable
- Federation between regions via SSH tunnels with iptables DNAT forwarding
- Runs entirely on internal network after initial setup
- Automated setup via Ansible

## Architecture

```
┌──────────────── Iran Server ────────────────┐    SSH tunnel    ┌──────────────── EU Server ──────────────────┐
│                                             │◄────────────────►│                                             │
│  ┌───────────┐     ┌──────────┐             │   :8448 ◄► :8449 │  ┌───────────┐     ┌──────────┐             │
│  │  Nginx    │────►│ Synapse  │──┐          │                  │  │  Nginx    │────►│ Synapse  │──┐          │
│  │  :443     │     │ (Matrix) │  │ ┌──────┐ │                  │  │  :443     │     │ (Matrix) │  │ ┌──────┐ │
│  │  :8448    │     └──────────┘  ├►│Pg 16 │ │                  │  │  :8449    │     └──────────┘  ├►│Pg 16 │ │
│  └───────────┘     ┌──────────┐  │ └──────┘ │                  │  └───────────┘     ┌──────────┐  │ └──────┘ │
│       │            │ Element  │──┘          │                  │       │            │ Element  │──┘          │
│       └───────────►│  (Web)   │             │                  │       └───────────►│  (Web)   │             │
│                    └──────────┘             │                  │                    └──────────┘             │
└─────────────────────────────────────────────┘                  └─────────────────────────────────────────────┘
  Docker mirrors: arvancloud, runflare                             Direct Docker Hub + certbot auto-renewal
  Apt via SSH proxy tunnel                                         Direct apt
```

All services run in Docker containers managed by Docker Compose.

## Prerequisites

**On your local machine:**

- Python 3
- Ansible (`pip install ansible`)
- SSH access to the target server(s)
- **Unrestricted internet access** — required to provide the SSH proxy for Iran's apt/Docker setup and to obtain TLS certificates via Cloudflare DNS-01 (using `get-cert.sh`)

**On the target server:**

- Ubuntu 24.04 or Debian 12+
- Root access (or a sudo-capable user — set `ansible_user` in your inventory accordingly)
- At least 2GB RAM
- **Iran server:** DNS servers must be able to resolve Iranian local domains (e.g. `docker.arvancloud.ir`) if using Docker registry mirrors. If DNS is broken, set `docker_pull_proxy` to pull images through the SSH-tunneled HTTP proxy instead.
- **Iran server:** If default DNS resolvers are unreachable, configure Iranian DNS servers before running the playbook (see [DNS Resolvers for Iran](#dns-resolvers-for-iran) below).

**For federation tunnel (Iran server only):**

- A SOCKS5 proxy running on `127.0.0.1:2080` — this can be any v2ray-based proxy (v2ray, xray, sing-box), a DNSTT-based tunnel, or any other SOCKS5-compatible proxy. Setting up this proxy is out of scope for this project. The tunnel service will auto-reconnect when the proxy becomes available.

**A domain:**

- A real domain with DNS managed by Cloudflare

## DNS Setup

Each region needs its own DNS records. Cloudflare proxy (orange cloud) must be **OFF** — use DNS only (grey cloud).

### Iran

| Type | Name               | Value          |
| ---- | ------------------ | -------------- |
| A    | `ir.example.com`   | Iran server IP |
| A    | `chat.example.com` | Iran server IP |

### Europe

| Type | Name                  | Value        |
| ---- | --------------------- | ------------ |
| A    | `eu.example.com`      | EU server IP |
| A    | `chat-eu.example.com` | EU server IP |

### Federation SRV records (optional)

These help other Matrix servers discover your federation endpoints:

| Type | Name                              | Priority | Weight | Port | Target           |
| ---- | --------------------------------- | -------- | ------ | ---- | ---------------- |
| SRV  | `_matrix-fed._tcp.ir.example.com` | 10       | 0      | 8448 | `ir.example.com` |
| SRV  | `_matrix-fed._tcp.eu.example.com` | 10       | 0      | 8449 | `eu.example.com` |

Note: Iran uses port **8448** and Europe uses port **8449** for federation. The `.well-known/matrix/server` endpoint on each server advertises the correct port automatically.

## Step-by-step Setup

### DNS Resolvers for Iran

If the Iran server's default DNS resolvers are blocked or unreachable, configure Iranian DNS servers before deploying. On Ubuntu 24.04 with systemd-resolved:

```bash
# Set global DNS
ssh iran-ssh-host "sudo mkdir -p /etc/systemd/resolved.conf.d && sudo tee /etc/systemd/resolved.conf.d/dns.conf > /dev/null << 'EOF'
[Resolve]
DNS=217.218.127.127 217.218.155.155
EOF
sudo systemctl restart systemd-resolved"

# Override per-interface DNS (if interfaces have unreachable DNS servers)
ssh iran-ssh-host "sudo resolvectl dns eth0 217.218.127.127 217.218.155.155"

# Verify
ssh iran-ssh-host "resolvectl status | head -10"
```

### Step 1 — Clone and configure

```bash
git clone git@github.com:bugfloyd/matrix-bridge-deploy.git
cd matrix-bridge-deploy
cp inventory/hosts.example.yml inventory/hosts.yml
cp group_vars/iran.example.yml group_vars/iran.yml
cp group_vars/europe.example.yml group_vars/europe.yml
```

Edit `inventory/hosts.yml` with your SSH hosts:

```yaml
all:
  children:
    iran:
      hosts:
        matrix-iran:
          ansible_host: iran-ssh-host # SSH config alias or IP
          ansible_user: root # or "ubuntu" if root login is disabled
    europe:
      hosts:
        matrix-eu:
          ansible_host: eu-ssh-host # SSH config alias or IP
          ansible_user: root
```

> **Note:** If the server disables root login (e.g., "Please login as ubuntu"), set `ansible_user` to the sudo-capable user. The playbook uses `become: true` so it will escalate to root via sudo.

Edit `group_vars/iran.yml` and `group_vars/europe.yml` with your domains and federation settings.

### Step 2 — Deploy

```bash
# Deploy Iran instance (starts SSH proxy, uses Docker mirrors)
./scripts/setup.sh iran

# Deploy Europe instance (direct internet, certbot on server)
./scripts/setup.sh europe
```

The `setup.sh` script accepts a **target** argument — a group name (`iran`, `europe`) or a specific host name. It automatically detects whether the target needs a proxy by reading `use_proxy` from the matching `group_vars/<target>.yml`.

**What the Iran deployment does:**

1. Starts a local HTTP forward proxy (`proxy.py`) on your machine
2. Creates an SSH reverse tunnel (`-R`) so the server can reach the proxy
3. Configures apt on the server to use the tunnel for package downloads
4. Installs Docker (with Iranian registry mirrors if configured, or pulls images through the SSH-tunneled proxy)
5. Deploys Synapse, Element, Nginx, Postgres via Docker Compose
6. Adds `/etc/hosts` entries and iptables DNAT rules for federation
7. Cleans up the apt proxy config when finished

**What the Europe deployment does:**

1. Installs Docker, pulls images directly from Docker Hub
2. Deploys all services with hardening applied
3. Installs certbot + Cloudflare DNS plugin on the server
4. Obtains TLS certificates for `eu.example.com`, `chat-eu.example.com`, and any federation peer hostnames
5. Sets up weekly auto-renewal cron job (Mondays 03:30, restarts nginx on renewal)
6. Adds `/etc/hosts` entries and iptables DNAT rules for federation

Secrets are auto-generated on first run and saved to `credentials/` (gitignored).

### Step 3 — Federation tunnel

After both servers are deployed, set up the SSH tunnel for federation:

```bash
./scripts/setup-tunnel.sh
```

This generates an SSH key on the Iran server, deploys a systemd service that maintains a bidirectional tunnel through the SOCKS proxy, and authorizes the key on the EU server. See [Setting up the SSH tunnel](#setting-up-the-ssh-tunnel) for details.

**Prerequisite:** A SOCKS5 proxy must be running on the Iran server at `127.0.0.1:2080` before running this. This can be any v2ray-based (v2ray, xray, sing-box) or DNSTT-based proxy. Setting up this proxy is out of scope for this project.

### Step 4 — TLS certificates

**Iran (no internet on server):**

Obtain a wildcard certificate locally using Cloudflare DNS-01 challenge, then push it to the server:

```bash
# Get wildcard cert for *.example.com (runs certbot locally)
./scripts/get-cert.sh example.com

# Push certs to Iran server
./scripts/sync-certs.sh example.com localhost iran-ssh-host
```

The `get-cert.sh` script will prompt for a Cloudflare API token if one isn't saved in `credentials/cloudflare_token`. It installs certbot locally if needed.

The `sync-certs.sh` script takes three arguments: the domain, a source (`localhost` for local certs, or a remote SSH host), and the target SSH destination (e.g. `ir-ssh-alias` or `user@ip`). It copies `fullchain.pem` + `privkey.pem` to the target server, then reloads nginx.

**Europe (certbot on server):**

If you set `cloudflare_api_token` in `group_vars/europe.yml` or saved it in `credentials/cloudflare_token`, certbot runs automatically during deployment. Nothing extra needed.

**Creating a Cloudflare API token:**

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Use the "Edit zone DNS" template with:
   - Permission: **Zone > DNS > Edit**
   - Zone resource: **Include > Specific zone > your domain**

### Step 5 — Create users

```bash
# Create admin user on Iran
./scripts/create-user.sh ir-ssh-alias admin --admin

# Create regular user on Iran
./scripts/create-user.sh ir-ssh-alias alice

# Create users on Europe
./scripts/create-user.sh root@203.0.113.1 admin --admin
./scripts/create-user.sh root@203.0.113.1 bob
```

The first argument is an SSH destination — either a `~/.ssh/config` alias (e.g. `ir-ssh-alias`) or `user@ip` (e.g. `root@203.0.113.1`). The second is the Matrix username, and the optional `--admin` flag grants admin privileges.

**Delete a user** (requires admin credentials — you will be prompted):

```bash
./scripts/delete-user.sh ir-ssh-alias alice
./scripts/delete-user.sh root@203.0.113.1 bob
```

### Step 6 — Connect

- **Iran:** Open `https://chat.example.com`
- **Europe:** Open `https://chat-eu.example.com`

For mobile, download Element and set the homeserver to `https://ir.example.com` or `https://eu.example.com`.

## Federation (Connecting Servers)

Federation lets users on different servers communicate. In this setup, federation traffic flows through SSH tunnels between servers because they may not have direct network connectivity.

### How federation works in this deployment

Each server uses a different federation port:

- **Iran:** listens on port **8448**
- **Europe:** listens on port **8449**

Traffic between them flows through SSH tunnels:

```
Iran Synapse ──► 127.0.0.1:8449 ──► [SSH tunnel] ──► EU Nginx :8449
EU Synapse   ──► 127.0.0.1:8448 ──► [SSH tunnel] ──► Iran Nginx :8448
```

The mechanism uses four pieces, all configured automatically by the playbook:

1. **`/etc/hosts` entries** — Each server resolves the other's hostname to `127.0.0.1`, so federation traffic goes to localhost instead of the real IP.

2. **SSH tunnels** — Persistent SSH tunnels (set up by you via autossh/systemd) forward the remote federation port to localhost. For example, on the Iran server: `ssh -L 8449:localhost:8449 eu-ssh-host` makes EU's port 8449 available at Iran's `localhost:8449`.

3. **iptables DNAT** — Synapse runs inside Docker and resolves federated hostnames to `172.17.0.1` (the Docker bridge IP via `host-gateway`). An iptables PREROUTING rule DNATs `172.17.0.1:<port>` to `127.0.0.1:<port>`, routing traffic to the SSH tunnel. The `route_localnet` sysctl is enabled to allow DNAT to localhost.

4. **`.well-known` proxy in Nginx** — Before federating, Synapse checks `https://<server>:443/.well-known/matrix/server` to discover the federation port. Since the hostname resolves to localhost, this request hits the local Nginx. The playbook adds an Nginx server block for each federated peer's hostname that returns the correct `.well-known` response (e.g., `{"m.server": "ir.example.com:8448"}`). Without this, Synapse would see the local server's `.well-known` and fail.

### Federation configuration

In `group_vars/iran.yml`:

```yaml
matrix_federation_port: 8448

federation_peers:
  - { hostname: "eu.example.com", port: 8449 }

matrix_federation_whitelist:
  - "eu.example.com"
```

In `group_vars/europe.yml`:

```yaml
matrix_federation_port: 8449

federation_peers:
  - { hostname: "ir.example.com", port: 8448 }

matrix_federation_whitelist:
  - "ir.example.com"
```

Each `federation_peers` entry configures:

- `/etc/hosts`: resolves `hostname` to `127.0.0.1`
- `extra_hosts` in docker-compose: resolves `hostname` to `host-gateway` (`172.17.0.1`)
- iptables DNAT: forwards `172.17.0.1:<port>` to `127.0.0.1:<port>`
- Nginx server block: serves correct `.well-known` for `hostname` returning `port`

### SRV DNS records

SRV records help external Matrix servers discover your federation endpoints. They're optional for the SSH tunnel setup between your own servers but recommended:

| Type | Name                  | Priority | Weight | Port | Target           |
| ---- | --------------------- | -------- | ------ | ---- | ---------------- |
| SRV  | `_matrix-fed._tcp.ir` | 10       | 0      | 8448 | `ir.example.com` |
| SRV  | `_matrix-fed._tcp.eu` | 10       | 0      | 8449 | `eu.example.com` |

Note the different ports: Iran uses **8448**, Europe uses **8449**.

Re-run both playbooks after changing federation settings:

```bash
./scripts/setup.sh iran
./scripts/setup.sh europe
```

### Setting up the SSH tunnel

A separate playbook (`tunnel.yml`) automates the federation tunnel setup. It creates a persistent, bidirectional SSH tunnel from the Iran server to the EU server using a systemd service.

**Prerequisites:**

The Iran server must have a **SOCKS proxy** running on `127.0.0.1:2080`. This can be any SOCKS5-compatible proxy — for example, a v2ray-based proxy (v2ray, xray, sing-box) or a DNSTT-based tunnel. Setting up this proxy is **out of scope** for this project; it is assumed to already be running before the tunnel playbook is executed.

**What the tunnel playbook does:**

1. Generates an ed25519 SSH key pair on the Iran server (`/root/.ssh/matrix_ed25519`)
2. Installs `netcat-openbsd` on the Iran server (provides `nc` with SOCKS5 support for the SSH ProxyCommand)
3. Deploys a `matrix-tunnel.service` systemd unit that:
   - Opens a local forward (`-L`) for the EU federation port (e.g. 8449) — so Iran's Synapse can reach EU
   - Opens a reverse forward (`-R`) for Iran's federation port (e.g. 8448) — so EU's Synapse can reach Iran
   - Routes the SSH connection through the local SOCKS proxy via `nc -X 5 -x 127.0.0.1:2080`
   - Auto-restarts on failure
4. Authorizes the generated public key on the EU server's `authorized_keys`

**Run it:**

```bash
./scripts/setup-tunnel.sh
```

Or directly:

```bash
ansible-playbook tunnel.yml
```

**Configuration** — edit `group_vars/iran.yml`:

```yaml
tunnel_eu_ip: "203.0.113.1" # EU server's public IP
tunnel_eu_federation_port: 8449 # EU's federation port (matches europe.yml)
tunnel_ssh_key_path: "/root/.ssh/matrix_ed25519"
tunnel_socks_port: 2080 # SOCKS proxy port on Iran server
```

**Check tunnel status:**

```bash
ssh iran-ssh-host "systemctl status matrix-tunnel"
ssh iran-ssh-host "journalctl -u matrix-tunnel -f"
```

### Federation troubleshooting

**Check that federation ports are listening:**

```bash
# On Iran server — should show :8448 listening (Nginx) and :8449 (SSH tunnel)
ss -tlnp | grep -E '8448|8449'

# On EU server — should show :8449 listening (Nginx) and :8448 (SSH tunnel)
ss -tlnp | grep -E '8448|8449'
```

**Check /etc/hosts entries:**

```bash
ssh iran-ssh-host "grep example.com /etc/hosts"
# Expected: 127.0.0.1    eu.example.com

ssh eu-ssh-host "grep example.com /etc/hosts"
# Expected: 127.0.0.1    ir.example.com
```

**Check iptables DNAT rules:**

```bash
ssh iran-ssh-host "iptables -t nat -L PREROUTING -n | grep 8449"
# Expected: DNAT tcp -- 0.0.0.0/0 172.17.0.1 tcp dpt:8449 to:127.0.0.1:8449

ssh eu-ssh-host "iptables -t nat -L PREROUTING -n | grep 8448"
# Expected: DNAT tcp -- 0.0.0.0/0 172.17.0.1 tcp dpt:8448 to:127.0.0.1:8448
```

**Check route_localnet is enabled:**

```bash
ssh iran-ssh-host "sysctl net.ipv4.conf.docker0.route_localnet"
# Expected: net.ipv4.conf.docker0.route_localnet = 1
```

**Test federation endpoint through the tunnel (from inside the Synapse container):**

```bash
# On Iran, test reaching EU's federation endpoint
ssh iran-ssh-host "cd /opt/matrix && docker compose exec synapse \
  curl -sf https://eu.example.com:8449/_matrix/federation/v1/version -k"

# On EU, test reaching Iran's federation endpoint
ssh eu-ssh-host "cd /opt/matrix && docker compose exec synapse \
  curl -sf https://ir.example.com:8448/_matrix/federation/v1/version -k"
```

**Check .well-known delegation (from inside the Synapse container — this is critical):**

```bash
# On EU, check what Synapse sees when looking up Iran's .well-known
ssh eu-ssh-host "docker exec synapse curl -sk https://ir.example.com/.well-known/matrix/server"
# Expected: {"m.server": "ir.example.com:8448"}

# On Iran, check what Synapse sees when looking up EU's .well-known
ssh iran-ssh-host "docker exec synapse curl -sk https://eu.example.com/.well-known/matrix/server"
# Expected: {"m.server": "eu.example.com:8449"}
```

If the `.well-known` returns the **local** server's info instead of the peer's, the Nginx proxy block for the federated hostname is missing or misconfigured.

**Check Synapse federation logs:**

```bash
ssh iran-ssh-host "cd /opt/matrix && docker compose logs synapse 2>&1 | grep -i federation | tail -20"
```

**Important:** Each server in a federated room sees room membership and message timestamps (metadata). Message **content** remains E2E encrypted.

## Security Hardening

Applied automatically on all instances:

| Measure           | Detail                                        |
| ----------------- | --------------------------------------------- |
| E2E encryption    | Enabled by default on all rooms               |
| Registration      | Disabled — admin creates accounts manually    |
| Email/phone       | Not required or stored                        |
| Federation        | Whitelist-only (only listed servers allowed)  |
| Message retention | Auto-purge after 30 days (configurable)       |
| Logging           | WARNING level only — minimal metadata in logs |
| Telemetry         | Disabled (`report_stats: false`)              |
| Key servers       | No external key servers configured            |
| Guest access      | Disabled                                      |
| Rate limiting     | Relaxed for internal use (10/s, burst 50)     |

### What is protected if the server is seized

- **Message content** — encrypted with Megolm/Olm, keys only on client devices
- **Media in E2E rooms** — encrypted at rest

### What is NOT protected

- **Metadata** — who talked to whom, room membership, timestamps
- **User accounts** — usernames (but no email/phone if not configured)
- **Unencrypted rooms** — if any user manually disables encryption

## Certificate Renewal

**Iran** — Let's Encrypt certificates expire after 90 days. Re-run locally:

```bash
./scripts/get-cert.sh example.com
./scripts/sync-certs.sh example.com localhost iran-ssh-host
```

**Europe** — auto-renewal is set up via a weekly cron job during deployment (`certbot renew` every Monday at 03:30, restarts nginx on success). No manual action needed.

## Maintenance

**Re-run playbook** (idempotent):

```bash
./scripts/setup.sh iran
./scripts/setup.sh europe
```

**View logs:**

```bash
ssh iran-ssh-host "cd /opt/matrix && docker compose logs -f synapse"
ssh eu-ssh-host "cd /opt/matrix && docker compose logs -f synapse"
```

**Restart services:**

```bash
ssh iran-ssh-host "cd /opt/matrix && docker compose restart"
```

**Update container images:**

```bash
ssh eu-ssh-host "cd /opt/matrix && docker compose pull && docker compose up -d"
```

## Multi-Region Configuration

The project uses Ansible host groups with per-region variable files. The `setup.sh` script limits the playbook run to the specified group or host using `--limit`.

```
group_vars/
├── all.yml          # Shared settings (secrets, paths, hardening, retention)
├── iran.yml         # Iran: proxy, Docker mirrors, federation port 8448
└── europe.yml       # Europe: direct internet, certbot, federation port 8449
```

### Iran vs Europe differences

| Feature          | Iran                                     | Europe                                |
| ---------------- | ---------------------------------------- | ------------------------------------- |
| Internet access  | SSH-tunneled proxy for apt               | Direct                                |
| Docker images    | SSH-tunneled proxy or Iranian mirrors    | Docker Hub                            |
| TLS certificates | Local certbot + push via `sync-certs.sh` | Certbot on server (Cloudflare DNS-01) |
| Federation port  | 8448                                     | 8449                                  |
| Timezone         | Asia/Tehran                              | Europe/Berlin                         |
| Element country  | IR                                       | DE                                    |
| Element URL      | `chat.example.com`                       | `chat-eu.example.com`                 |

To add a new region, create `group_vars/<region>.yml`, add hosts to the inventory, and run `./scripts/setup.sh <region>`.

### Variable reference

#### Shared variables (`group_vars/all.yml`)

| Variable                            | Default        | Description                                   |
| ----------------------------------- | -------------- | --------------------------------------------- |
| `matrix_registration_shared_secret` | auto-generated | Secret for user registration API              |
| `matrix_macaroon_secret_key`        | auto-generated | Macaroon signing key                          |
| `matrix_form_secret`                | auto-generated | Form signing secret                           |
| `postgres_password`                 | auto-generated | PostgreSQL password                           |
| `matrix_base_dir`                   | `/opt/matrix`  | Base directory for all Matrix files on server |
| `matrix_enable_registration`        | `false`        | Public registration (always off)              |
| `matrix_retention_max_lifetime`     | `30d`          | Message retention period before auto-purge    |
| `matrix_minimal_logging`            | `true`         | Use WARNING-level logging only                |
| `apt_proxy_port`                    | `8185`         | Port for SSH-tunneled apt proxy               |

#### Per-region variables (`group_vars/iran.yml`, `group_vars/europe.yml`)

| Variable                      | Iran                                         | Europe                                       | Description                                                                                              |
| ----------------------------- | -------------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `use_proxy`                   | `true`                                       | `false`                                      | Whether to tunnel apt through SSH reverse proxy                                                          |
| `docker_registry_mirrors`     | `[]` (or Iranian mirrors if DNS works)       | `[]`                                         | Docker daemon registry mirrors                                                                           |
| `docker_pull_proxy`           | `http://127.0.0.1:8185`                      | —                                            | HTTP proxy for Docker image pulls (uses the SSH-tunneled proxy when mirrors are unreachable)             |
| `certbot_on_server`           | `false`                                      | `true`                                       | Whether to run certbot directly on the server                                                            |
| `cloudflare_api_token`        | —                                            | from `credentials/cloudflare_token`          | Cloudflare API token for DNS-01 challenge                                                                |
| `matrix_server_name`          | `ir.example.com`                             | `eu.example.com`                             | Matrix server identity (cannot change after first run)                                                   |
| `matrix_hostname`             | `ir.example.com`                             | `eu.example.com`                             | Hostname Nginx listens on for client API                                                                 |
| `element_hostname`            | `chat.example.com`                           | `chat-eu.example.com`                        | Hostname for Element web client                                                                          |
| `matrix_tls_cert_dir`         | `/etc/letsencrypt/live/example.com`          | `/etc/letsencrypt/live/eu.example.com`       | Directory containing `fullchain.pem` and `privkey.pem`                                                   |
| `matrix_timezone`             | `Asia/Tehran`                                | `Europe/Berlin`                              | Server timezone                                                                                          |
| `element_country_code`        | `IR`                                         | `DE`                                         | Default country code in Element phone number picker                                                      |
| `matrix_federation_port`      | `8448`                                       | `8449`                                       | Port Nginx listens on for federation traffic                                                             |
| `federation_peers`            | `[{hostname: "eu.example.com", port: 8449}]` | `[{hostname: "ir.example.com", port: 8448}]` | Federated servers: configures /etc/hosts, iptables DNAT, docker extra_hosts, and Nginx .well-known proxy |
| `matrix_federation_whitelist` | `["eu.example.com"]`                         | `["ir.example.com"]`                         | Servers allowed to federate (empty list disables federation)                                             |
| `tunnel_eu_ip`                | `203.0.113.1`                                | —                                            | EU server's public IP (used by tunnel service on Iran)                                                   |
| `tunnel_eu_federation_port`   | `8449`                                       | —                                            | EU's federation port to forward locally                                                                  |
| `tunnel_ssh_key_path`         | `/root/.ssh/matrix_ed25519`                  | —                                            | SSH private key path for the tunnel                                                                      |
| `tunnel_socks_port`           | `2080`                                       | —                                            | SOCKS5 proxy port on Iran server (v2ray, DNSTT, etc.)                                                    |

## File Structure

```
matrix-bridge-deploy/
├── ansible.cfg                         # Ansible settings (pipelining, SSH args)
├── inventory/hosts.yml                 # SSH hosts (gitignored)
├── group_vars/
│   ├── all.yml                         # Shared: secrets, paths, retention, proxy port
│   ├── iran.yml                        # Iran: proxy, mirrors, federation port 8448
│   └── europe.yml                      # Europe: certbot, direct access, port 8449
├── playbook.yml                        # Main deployment: pre_tasks (proxy), roles, post_tasks (cleanup)
├── tunnel.yml                          # Federation tunnel: SSH key setup + systemd service on Iran
├── credentials/                        # Auto-generated secrets + cloudflare token (gitignored)
├── roles/
│   ├── common/tasks/main.yml           # Base packages, timezone, /etc/hosts, sysctl
│   ├── docker/tasks/main.yml           # Docker CE install, registry mirrors, proxy config
│   ├── federation/tasks/main.yml       # route_localnet, iptables DNAT (runs after Docker)
│   ├── certbot/tasks/main.yml          # On-server certbot + Cloudflare DNS (EU only)
│   ├── tunnel/
│   │   ├── tasks/main.yml              # SSH key generation, netcat install, systemd service
│   │   └── templates/
│   │       └── matrix-tunnel.service.j2  # Bidirectional SSH tunnel systemd unit
│   └── matrix/
│       ├── tasks/                      # Deployment logic
│       ├── handlers/                   # Service restart triggers
│       └── templates/
│           ├── docker-compose.yml.j2   # Synapse, Postgres, Element, Nginx containers
│           ├── homeserver.yaml.j2      # Synapse config (federation whitelist, retention, E2E)
│           ├── element-config.json.j2  # Element web client config
│           ├── nginx.conf.j2           # Nginx: :443 client, :8448/:8449 federation, Element vhost
│           └── log.config.j2           # Python logging config for Synapse
└── scripts/
    ├── setup.sh                        # Deploy: ./setup.sh <region|host> (auto-detects proxy need)
    ├── setup-tunnel.sh                 # Set up federation SSH tunnel between Iran and EU
    ├── proxy.py                        # HTTP forward proxy for SSH tunnel (Iran deployments)
    ├── get-cert.sh                     # Get wildcard cert locally via Cloudflare DNS-01
    ├── sync-certs.sh                   # Push certs to server: ./sync-certs.sh <domain> <source> <target-ssh-host>
    ├── create-user.sh                  # Create user: ./create-user.sh <ssh-host> <username> [--admin]
    └── delete-user.sh                  # Delete user: ./delete-user.sh <ssh-host> <username>
```

## Playbook Execution Flow

The playbook (`playbook.yml`) runs in this order:

1. **pre_tasks** — If `use_proxy` is true, writes apt proxy config pointing to `127.0.0.1:<apt_proxy_port>` and tests connectivity
2. **Role: common** — Installs base packages, sets timezone, adds `/etc/hosts` entries for federation, creates `/opt/matrix`
3. **Role: docker** — Installs Docker CE, configures `daemon.json` with registry mirrors, sets up Docker proxy if `docker_pull_proxy` is defined, restarts Docker if config changed
4. **Role: federation** — (after Docker) Enables `route_localnet` for `docker0`, adds iptables DNAT rules for federation ports, persists iptables rules
5. **Role: matrix** — Renders templates (docker-compose, homeserver.yaml, nginx.conf, element-config), pulls images, starts containers
6. **Role: certbot** — (EU only, skipped when `certbot_on_server` is false) Installs certbot + Cloudflare plugin, obtains certificates, sets up weekly renewal cron
7. **post_tasks** — Removes apt proxy and Docker proxy configurations if they were set
