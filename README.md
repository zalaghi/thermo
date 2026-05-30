# Thermo

Thermo is a minimal, mobile-friendly temperature dashboard for small server and homelab environments.

The central web app runs FastAPI, Jinja2, SQLite, plain CSS, and plain JavaScript. Each monitored server runs a tiny read-only HTTP temperature agent protected by an API key. Thermo does not use SSH and does not depend on Grafana, Prometheus, Netdata, Zabbix, LibreNMS, or any heavy monitoring stack.

## Quick Start: Central App

Review and change the default secrets in `docker-compose.yml` before real use:

```yaml
THERMO_ADMIN_PASSWORD: change-me-now
THERMO_SECRET_KEY: change-me-to-a-long-random-secret
```

Start Thermo:

```bash
docker compose up --build -d
```

Open:

```text
http://127.0.0.1:8088
```

The central container listens on `8080`, the host exposes `8088`, and SQLite is stored in `./data:/data`.

## Admin Workflow

1. Open `/admin/login`.
2. Sign in with `THERMO_ADMIN_USER` and `THERMO_ADMIN_PASSWORD`.
3. Open `/admin/setup-agent`.
4. Choose the target platform.
5. Enter the server name, Thermo URL reachable from the target server, agent bind host, agent port, and thresholds.
6. Copy the generated one-line command.
7. Run it on the target server.
8. Return to `/` to see the live temperature card.

The setup command contains a short-lived single-use pairing token. It does not contain the permanent agent API key. Thermo generates the permanent API key during registration, stores it, and returns it only to the installer.

## Agent Setup Wizard

The wizard supports:

- Proxmox
- Debian / Ubuntu
- Generic systemd Linux
- FreeBSD
- TrueNAS CORE
- Other / Advanced

The generated command uses the public installer script:

```text
https://raw.githubusercontent.com/zalaghi/thermo/main/scripts/install-agent.sh
```

The installer downloads Thermo source from:

```text
https://github.com/zalaghi/thermo/archive/refs/heads/main.tar.gz
```

The target server registers back with:

```text
POST /api/setup/register
```

Registration creates or updates the saved server entry using the wizard values.

## Proxmox / Debian / Ubuntu Agent

Use the wizard first. It generates the command you should run on the target server.

The installer will try to:

- install `python3`, `python3-venv`, `curl`, `tar`, and `lm-sensors` with `apt`
- install the agent into `/opt/thermo-agent`
- create `/etc/thermo-agent.env`
- create and start `thermo-agent.service` when systemd is available
- test `/health`
- test `/temperature` with the permanent API key

Before or after installation, confirm sensors work:

```bash
sudo apt update
sudo apt install -y lm-sensors
sudo sensors-detect
sensors
```

The default Linux temperature command is:

```bash
sensors | awk '/Package id 0|Tctl|CPU/ {print $0; exit}' | grep -oE '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n1 | tr -d '+°C'
```

If your hardware reports a different sensor label, edit `THERMO_TEMP_COMMAND` in `/etc/thermo-agent.env` and restart:

```bash
sudo systemctl restart thermo-agent.service
```

## TrueNAS CORE / FreeBSD Agent

Use the wizard to generate the command, but keep expectations practical: TrueNAS CORE is FreeBSD-based, may not use Docker natively, and service setup can depend on jails and local TrueNAS configuration.

The installer will try to:

- install Python/curl/tar dependencies with `pkg` when available
- install the agent into `/usr/local/thermo-agent`
- create `/usr/local/etc/thermo-agent.env`
- create an rc.d service when supported
- print a manual run command if no supported service manager is available

The FreeBSD temperature command is:

```sh
sysctl -n dev.cpu.0.temperature | sed 's/C//'
```

If TrueNAS exposes temperature through a different sysctl path, update `THERMO_TEMP_COMMAND` in `/usr/local/etc/thermo-agent.env`.

## Testing an Agent

From the central Thermo host:

```bash
curl http://192.168.1.10:8090/health
curl -H 'X-API-Key: replace-with-agent-key' http://192.168.1.10:8090/temperature
```

The installer tests these locally during setup. The saved permanent API key is not shown in full in the admin UI after registration.

## Existing Manual CRUD

Manual server management is still available at:

```text
/admin/servers
```

Use it for advanced cases, corrections, or deleting servers. Saved API keys are masked in the UI.

## API

Dashboard data is available at:

```text
GET /api/status
```

This endpoint never exposes agent API keys or pairing secrets.

## Security Checklist

- No SSH is required or used.
- Use HTTPS or a reverse proxy if the dashboard is reachable outside your LAN.
- Change `THERMO_ADMIN_PASSWORD` immediately.
- Set a long random `THERMO_SECRET_KEY`.
- Use long random agent API keys.
- Pairing tokens are short-lived, single-use, revocable, and stored hashed.
- Do not expose agent ports to the public internet.
- Firewall each agent so only the central Thermo server IP can connect.
- Prefer binding agents to LAN/private IPs.

Example UFW rule on a Debian/Proxmox agent:

```bash
sudo ufw allow from 192.168.1.50 to any port 8090 proto tcp
```

Replace `192.168.1.50` with the central Thermo host IP.

## Troubleshooting

Central app does not start:

- Run `docker compose logs -f thermo`.
- Check `docker compose config`.
- Check that `./data` is writable.

Cannot sign in:

- Confirm `THERMO_ADMIN_USER` and `THERMO_ADMIN_PASSWORD`.
- If a user already exists, changing env defaults will not rewrite that existing user.

Generated command cannot register:

- Confirm the `Thermo URL reachable from target` is reachable from the target server.
- Confirm the pairing token has not expired or been revoked.
- Generate a new wizard command if the token was already used.

Agent shows offline:

- From the central host, run `curl -H 'X-API-Key: ...' http://agent-ip:8090/temperature`.
- Check the agent service logs.
- Confirm the firewall allows the central Thermo IP.
- Confirm the URL in admin ends with `/temperature`.

Temperature command returns nothing:

- On Debian/Proxmox, run `sensors` directly and adjust `THERMO_TEMP_COMMAND`.
- On TrueNAS CORE/FreeBSD, confirm `sysctl -n dev.cpu.0.temperature` exists.

Ports:

- Central Docker app: `http://host:8088`
- Central container port: `8080`
- Agent examples: `8090`
