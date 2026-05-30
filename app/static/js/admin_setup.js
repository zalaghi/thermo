(function () {
  document.querySelectorAll("[data-copy-target]").forEach((button) => {
    const target = document.querySelector(button.getAttribute("data-copy-target"));
    const feedback = button.parentElement.querySelector("[data-copy-feedback]");

    if (!target || !feedback || !navigator.clipboard) {
      return;
    }

    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(target.textContent.trim());
        feedback.hidden = false;
        feedback.textContent = "Copied.";
      } catch (error) {
        feedback.hidden = false;
        feedback.textContent = "Copy failed. Select the command manually.";
      }
    });
  });

  const detail = document.querySelector("[data-pairing-status-url]");
  if (!detail) {
    return;
  }

  const statusUrl = detail.getAttribute("data-pairing-status-url");
  const statusLabel = detail.querySelector("[data-pairing-status]");
  const errorMessage = detail.querySelector("[data-pairing-error]");
  const completedActions = detail.querySelector("[data-completed-actions]");
  const serverEditLink = detail.querySelector("[data-server-edit-link]");
  const revokeForm = detail.querySelector("[data-revoke-form]");

  async function loadPairingStatus() {
    try {
      const response = await fetch(statusUrl, {
        headers: { Accept: "application/json" },
        cache: "no-store",
      });
      if (!response.ok) {
        throw new Error("Status request failed");
      }

      const payload = await response.json();
      updateStatus(payload);
      if (payload.completed || payload.revoked || payload.expired) {
        window.clearInterval(timer);
      }
    } catch (error) {
      if (errorMessage) {
        errorMessage.hidden = false;
        errorMessage.textContent = "Unable to refresh setup status.";
      }
    }
  }

  function updateStatus(payload) {
    if (statusLabel) {
      statusLabel.textContent = payload.status || "Waiting";
      statusLabel.className = "status-pill";
    }

    detail.querySelectorAll(".setup-status-panel").forEach((panel) => {
      panel.className = `setup-status-panel status-${payload.status_key || "waiting"}`;
    });

    if (errorMessage) {
      errorMessage.hidden = !payload.last_error;
      errorMessage.textContent = payload.last_error || "";
    }

    if (completedActions) {
      completedActions.hidden = !payload.completed;
    }

    if (serverEditLink && payload.server_edit_url) {
      serverEditLink.setAttribute("href", payload.server_edit_url);
    }

    if (revokeForm && !payload.can_revoke) {
      revokeForm.hidden = true;
    }
  }

  const timer = window.setInterval(loadPairingStatus, 3000);
  loadPairingStatus();
})();
