# Thermo

Thermo is a minimal, mobile-friendly temperature dashboard for small server and homelab environments.

The central web app runs FastAPI, server-rendered Jinja2 HTML, plain CSS, plain JavaScript, and SQLite. Each monitored server runs a tiny read-only HTTP temperature agent protected by an API key. Thermo does not use SSH and is not intended to become a heavy monitoring stack.

## Current Status

Parts 1 through 7 currently provide:

- FastAPI central web app
- Jinja2 dashboard route at `/`
- Dark mobile-first dashboard UI
- SQLite database for users, servers, and latest status
- Session-based admin login
- Admin CRUD for monitored temperature-agent servers
- Background HTTP polling for enabled agents
- `/api/status` JSON for latest status
- Tiny authenticated temperature agent
- Docker setup for the central app
- Direct Python install docs for agents

Not implemented yet:

- Security hardening and final QA pass

## Central App: Docker Quick Start

Review and change the default secrets in `docker-compose.yml` before using Thermo beyond local testing:

```yaml
THERMO_ADMIN_PASSWORD: change-me-now
THERMO_SECRET_KEY: change-me-to-a-long-random-secret
```

Start the central panel:

```bash
docker compose up --build -d
```

Open:

```text
http://127.0.0.1:8088
```

The compose file maps host port `8088` to container port `8080` and stores SQLite data in:

```text
./data:/data
```

The central app uses:

```text
THERMO_DB_PATH=/data/thermo.db
THERMO_ADMIN_USER=admin
THERMO_ADMIN_PASSWORD=change-me-now
THERMO_SECRET_KEY=change-me-to-a-long-random-secret
THERMO_POLL_INTERVAL=5
TZ=Asia/Tehran
```

Check logs:

```bash
docker compose logs -f thermo
```

Stop the central panel:

```bash
docker compose down
```

## Central App: Direct Python Run

For development without Docker:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
mkdir -p data
export THERMO_DB_PATH=./data/thermo.db
export THERMO_ADMIN_USER=admin
export THERMO_ADMIN_PASSWORD=change-me-now
export THERMO_SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
export THERMO_POLL_INTERVAL=5
uvicorn app.main:app --host 0.0.0.0 --port 8080
```

Open:

```text
http://127.0.0.1:8080
```

## Admin Workflow

1. Open `/admin/login`.
2. Sign in with the configured admin username and password.
3. Change the default admin password in your environment before real use.
4. Open `/admin/servers`.
5. Add a server with:
   - Name
   - Agent URL, for example `http://192.168.1.10:8090/temperature`
   - Agent API key
   - Warning and critical thresholds
6. Return to `/` to view real-time temperature cards.

Saved API keys are not shown in full in the admin UI or `/api/status`.

## Temperature Agent

The Thermo agent is a tiny read-only FastAPI service. It exposes:

- `GET /health`, public, returns `{"ok": true}`
- `GET /temperature`, protected by `X-API-Key`, returns `{"temperature": 42.5, "unit": "C"}`

Required agent environment:

```text
THERMO_AGENT_API_KEY=<long-random-secret>
THERMO_TEMP_COMMAND=<read-only-temperature-command>
```

Optional:

```text
THERMO_TEMP_TIMEOUT_SECONDS=3
```

Generate a good API key:

```bash
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
```

Test an agent:

```bash
curl http://192.168.1.10:8090/health
curl -H 'X-API-Key: replace-with-the-agent-secret' http://192.168.1.10:8090/temperature
```

## Proxmox/Debian Agent Install

Run these commands on the monitored Proxmox/Debian server.

Install OS dependencies:

```bash
sudo apt update
sudo apt install -y python3 python3-venv lm-sensors
sudo sensors-detect
sensors
```

Create a dedicated directory and copy the Thermo agent files into it:

```bash
sudo mkdir -p /opt/thermo-agent
sudo cp -r agent /opt/thermo-agent/
sudo chown -R root:root /opt/thermo-agent
cd /opt/thermo-agent
```

Create a Python virtual environment:

```bash
sudo python3 -m venv .venv
sudo ./.venv/bin/pip install -r agent/requirements.txt
```

Test the command manually:

```bash
sensors | awk '/Package id 0|Tctl|CPU/ {print $0; exit}' | grep -oE '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n1 | tr -d '+°C'
```

Run the agent manually first. Bind to a LAN/private IP when possible:

```bash
export THERMO_AGENT_API_KEY='replace-with-a-long-random-secret'
export THERMO_TEMP_COMMAND="sensors | awk '/Package id 0|Tctl|CPU/ {print \$0; exit}' | grep -oE '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
/opt/thermo-agent/.venv/bin/uvicorn agent.main:app --host 192.168.1.10 --port 8090
```

Replace `192.168.1.10` with the server LAN IP.

Create a systemd service:

```bash
sudo tee /etc/systemd/system/thermo-agent.service >/dev/null <<'EOF'
[Unit]
Description=Thermo temperature agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/thermo-agent
Environment="THERMO_AGENT_API_KEY=replace-with-a-long-random-secret"
Environment="THERMO_TEMP_COMMAND=sensors | awk '/Package id 0|Tctl|CPU/ {print $0; exit}' | grep -oE '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n1 | tr -d '+°C'"
Environment="THERMO_TEMP_TIMEOUT_SECONDS=3"
ExecStart=/opt/thermo-agent/.venv/bin/uvicorn agent.main:app --host 192.168.1.10 --port 8090
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now thermo-agent.service
sudo systemctl status thermo-agent.service
```

Test from the central Thermo host:

```bash
curl http://192.168.1.10:8090/health
curl -H 'X-API-Key: replace-with-a-long-random-secret' http://192.168.1.10:8090/temperature
```

## TrueNAS CORE / FreeBSD Agent Install

TrueNAS CORE is FreeBSD-based and may not run Docker natively. Do not assume systemd. A practical approach is to run the Thermo agent directly with Python, preferably inside a jail or another service location you control.

Example layout:

```sh
mkdir -p /usr/local/thermo-agent
cp -R agent /usr/local/thermo-agent/
cd /usr/local/thermo-agent
python3 -m venv .venv
./.venv/bin/pip install -r agent/requirements.txt
```

Test the FreeBSD temperature command:

```sh
sysctl -n dev.cpu.0.temperature | sed 's/C//'
```

Run manually:

```sh
export THERMO_AGENT_API_KEY='replace-with-a-long-random-secret'
export THERMO_TEMP_COMMAND="sysctl -n dev.cpu.0.temperature | sed 's/C//'"
./.venv/bin/uvicorn agent.main:app --host 192.168.1.30 --port 8090
```

Replace `192.168.1.30` with the TrueNAS/jail LAN IP.

For a simple FreeBSD-style service, create a wrapper script:

```sh
cat >/usr/local/thermo-agent/run-agent.sh <<'EOF'
#!/bin/sh
export THERMO_AGENT_API_KEY='replace-with-a-long-random-secret'
export THERMO_TEMP_COMMAND="sysctl -n dev.cpu.0.temperature | sed 's/C//'"
export THERMO_TEMP_TIMEOUT_SECONDS=3
cd /usr/local/thermo-agent
exec ./.venv/bin/uvicorn agent.main:app --host 192.168.1.30 --port 8090
EOF
chmod 700 /usr/local/thermo-agent/run-agent.sh
```

An rc.d wrapper can run that script in a FreeBSD jail or host environment where custom services are appropriate:

```sh
cat >/usr/local/etc/rc.d/thermo_agent <<'EOF'
#!/bin/sh
# PROVIDE: thermo_agent
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="thermo_agent"
rcvar="thermo_agent_enable"
pidfile="/var/run/${name}.pid"
command="/usr/sbin/daemon"
command_args="-f -p ${pidfile} /usr/local/thermo-agent/run-agent.sh"

load_rc_config $name
: ${thermo_agent_enable:="NO"}

run_rc_command "$1"
EOF
chmod 755 /usr/local/etc/rc.d/thermo_agent
sysrc thermo_agent_enable=YES
service thermo_agent start
```

TrueNAS CORE service setup can vary by release, boot environment, and whether you use jails. Keep the manual command working first, then adapt the service approach to your TrueNAS configuration.

## Optional Agent Docker

Docker is optional for agents and is not required for TrueNAS CORE:

```bash
docker build -f agent/Dockerfile -t thermo-agent .
docker run --rm -p 8090:8989 \
  -e THERMO_AGENT_API_KEY='replace-with-a-long-random-secret' \
  -e THERMO_TEMP_COMMAND='echo 42.5' \
  thermo-agent
```

Then add this URL in Thermo admin:

```text
http://agent-host-ip:8090/temperature
```

## Security Checklist

- Use long random API keys for every agent.
- Use a long random `THERMO_SECRET_KEY`.
- Change `THERMO_ADMIN_PASSWORD` immediately.
- Do not expose agent ports to the public internet.
- Firewall each agent so only the central Thermo server IP can connect.
- Prefer binding agents to LAN/private IPs, not `0.0.0.0`, where practical.
- Use HTTPS through a reverse proxy if the dashboard is reachable outside your LAN.
- Keep the central SQLite database in `./data` backed up if the data matters.

Example Debian firewall rule with UFW:

```bash
sudo ufw allow from 192.168.1.50 to any port 8090 proto tcp
```

Replace `192.168.1.50` with the central Thermo host IP.

## Troubleshooting

Central app does not start:

- Run `docker compose logs -f thermo`.
- Check that `./data` is writable.
- Check that `THERMO_SECRET_KEY` and admin environment values are set as intended.

Cannot sign in:

- Confirm `THERMO_ADMIN_USER` and `THERMO_ADMIN_PASSWORD`.
- If a user already exists, changing env defaults will not rewrite that existing user.

Agent shows offline:

- From the central host, run `curl -H 'X-API-Key: ...' http://agent-ip:8090/temperature`.
- Check the agent service logs.
- Confirm the firewall allows the central Thermo IP.
- Confirm the URL in admin ends with `/temperature`.

Temperature command returns nothing:

- On Debian/Proxmox, run `sensors` directly and adjust `THERMO_TEMP_COMMAND` for that hardware.
- On TrueNAS CORE/FreeBSD, confirm `sysctl -n dev.cpu.0.temperature` exists. Some hardware exposes a different sensor path.

Wrong port:

- Central Docker app: `http://host:8088`
- Central container port: `8080`
- Agent examples: `8090`

## Firewall Notes

Agents should only be reachable from the central Thermo app host, and each agent must require an API key through `X-API-Key`. Do not expose agent ports directly to the public internet.
