(function () {
  const POLL_INTERVAL_MS = 5000;
  const grid = document.querySelector("#temperature-grid");
  const emptyState = document.querySelector("#dashboard-empty");
  const updatedLabel = document.querySelector("#dashboard-updated");

  if (!grid || !emptyState || !updatedLabel) {
    return;
  }

  async function loadStatus() {
    try {
      const response = await fetch("/api/status", {
        headers: { Accept: "application/json" },
        cache: "no-store",
      });

      if (!response.ok) {
        throw new Error("Status request failed");
      }

      const servers = await response.json();
      renderServers(Array.isArray(servers) ? servers : []);
      updatedLabel.textContent = `Updated ${formatLocalTime(new Date())}`;
    } catch (error) {
      updatedLabel.textContent = "Unable to sync";
      grid.querySelectorAll(".temperature-card").forEach((card) => {
        card.classList.add("is-stale");
      });
    }
  }

  function renderServers(servers) {
    emptyState.hidden = servers.length !== 0;
    grid.hidden = servers.length === 0;

    if (servers.length === 0) {
      grid.replaceChildren();
      return;
    }

    grid.replaceChildren(...servers.map(createServerCard));
  }

  function createServerCard(server) {
    const card = document.createElement("article");
    const status = normalizeStatus(server.status);
    card.className = `temperature-card status-${status}`;

    const header = document.createElement("div");
    header.className = "temperature-card-header";

    const titleBlock = document.createElement("div");
    const name = document.createElement("h3");
    name.textContent = server.name || "Unnamed server";
    const url = document.createElement("p");
    url.className = "server-url";
    url.textContent = server.url || "";
    titleBlock.append(name, url);

    const badge = document.createElement("span");
    badge.className = "status-badge";
    badge.textContent = displayStatus(server.status);
    header.append(titleBlock, badge);

    const body = document.createElement("div");
    body.className = "temperature-card-body";

    const temperature = document.createElement("strong");
    temperature.className = "temperature-value";
    temperature.innerHTML = formatTemperature(server.temperature, server.unit);
    body.append(temperature);

    const meta = document.createElement("p");
    meta.className = "last-checked";
    meta.textContent = `Last checked ${formatCheckedAt(server.checked_at)}`;
    body.append(meta);

    if (server.error) {
      const error = document.createElement("p");
      error.className = "temperature-error";
      error.textContent = server.error;
      body.append(error);
    }

    card.append(header, body);
    return card;
  }

  function normalizeStatus(status) {
    const normalized = String(status || "").toLowerCase();
    if (normalized === "ok") return "ok";
    if (normalized === "warm") return "warm";
    if (normalized === "hot") return "hot";
    if (normalized === "offline") return "offline";
    if (normalized === "disabled") return "offline";
    return "pending";
  }

  function displayStatus(status) {
    return status || "Pending";
  }

  function formatTemperature(value, unit) {
    if (typeof value !== "number" || !Number.isFinite(value)) {
      return "--<span>&deg;C</span>";
    }

    const formatted = value.toFixed(Math.abs(value) >= 100 ? 0 : 1);
    const suffix = unit === "C" ? "&deg;C" : escapeHtml(unit || "C");
    return `${formatted}<span>${suffix}</span>`;
  }

  function formatCheckedAt(value) {
    if (!value) {
      return "not yet";
    }

    const checkedAt = new Date(value);
    if (Number.isNaN(checkedAt.getTime())) {
      return "unknown";
    }

    return formatLocalTime(checkedAt);
  }

  function formatLocalTime(date) {
    return new Intl.DateTimeFormat(undefined, {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).format(date);
  }

  function escapeHtml(value) {
    const node = document.createElement("span");
    node.textContent = value;
    return node.innerHTML;
  }

  loadStatus();
  window.setInterval(loadStatus, POLL_INTERVAL_MS);
})();
