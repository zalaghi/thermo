(function () {
  document.querySelectorAll("[data-copy-target]").forEach((button) => {
    const target = document.querySelector(button.getAttribute("data-copy-target"));
    const feedback = button.parentElement.querySelector("[data-copy-feedback]");

    if (!target) {
      return;
    }

    button.addEventListener("click", async () => {
      const originalText = button.textContent;
      try {
        await copyText(target.textContent.trim());
        button.textContent = "Copied";
        if (feedback) {
          feedback.hidden = false;
          feedback.textContent = "Copied.";
        }
      } catch (error) {
        if (feedback) {
          feedback.hidden = false;
          feedback.textContent = "Copy failed. Select the command manually.";
        }
      } finally {
        window.setTimeout(() => {
          button.textContent = originalText;
        }, 1600);
      }
    });
  });

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.top = "-1000px";
    textarea.style.left = "-1000px";
    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();

    try {
      if (!document.execCommand("copy")) {
        throw new Error("copy command failed");
      }
    } finally {
      textarea.remove();
    }
  }

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
  const stateMessage = detail.querySelector("[data-pairing-state-message]");
  const newTokenActions = detail.querySelector("[data-new-token-actions]");
  const completedSummary = detail.querySelector("[data-completed-summary]");
  const createdServerName = detail.querySelector("[data-created-server-name]");
  const createdServerUrl = detail.querySelector("[data-created-server-url]");

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
      statusLabel.textContent = payload.status_label || payload.status || "Waiting";
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

    if (completedSummary) {
      completedSummary.hidden = !payload.completed;
    }

    if (stateMessage) {
      stateMessage.textContent = statusMessage(payload);
    }

    if (newTokenActions) {
      newTokenActions.hidden = !(payload.failed || payload.expired);
    }

    if (serverEditLink && payload.server_edit_url) {
      serverEditLink.setAttribute("href", payload.server_edit_url);
    }

    if (createdServerName && payload.created_server_name) {
      createdServerName.textContent = payload.created_server_name;
    }

    if (createdServerUrl && payload.created_server_url) {
      createdServerUrl.textContent = payload.created_server_url;
    }

    if (revokeForm && !payload.can_revoke) {
      revokeForm.hidden = true;
    }
  }

  function statusMessage(payload) {
    if (payload.completed) {
      return "Agent registered successfully.";
    }
    if (payload.failed) {
      return "Setup failed. Review the error and create a new token if needed.";
    }
    if (payload.expired) {
      return "Pairing token expired.";
    }
    if (payload.revoked) {
      return "Pairing token revoked.";
    }
    return "Waiting for agent...";
  }

  const timer = window.setInterval(loadPairingStatus, 3000);
  loadPairingStatus();
})();
