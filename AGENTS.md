# Thermo Project Rules

- Keep Thermo minimal, readable, and homelab-friendly.
- Do not add SSH-based monitoring or management.
- Do not add Netdata, Grafana, Prometheus, Zabbix, LibreNMS, or similar heavy monitoring stacks.
- Use FastAPI for the backend, Jinja2 for server-rendered HTML, and SQLite for persistence.
- Keep the UI mobile-first, responsive, dark, and uncluttered.
- Preserve the simple central-app-plus-read-only-agent architecture.
- Do not expose full API keys in the UI after they are saved.
- Prefer small, complete changes over broad rewrites.
