(function () {
  const form = document.querySelector("[data-server-form]");
  if (!form) {
    return;
  }

  const apiKeyInput = form.querySelector("#server-api-key");
  const urlInput = form.querySelector("#server-url");
  const csrfInput = form.querySelector("input[name='csrf_token']");
  const allowMissingPortInput = form.querySelector("input[name='allow_missing_port']");
  const testResult = form.querySelector("[data-test-result]");
  const generateButton = form.querySelector("[data-generate-api-key]");
  const testButton = form.querySelector("[data-test-agent]");

  if (generateButton && apiKeyInput) {
    generateButton.addEventListener("click", () => {
      apiKeyInput.value = generateApiKey();
      apiKeyInput.type = "text";
      showResult("Generated a new key. Save this form and copy it into the agent env file.", "ok");
    });
  }

  if (testButton) {
    testButton.addEventListener("click", async () => {
      showResult("Testing agent...", "pending");
      testButton.disabled = true;

      try {
        const response = await fetch("/admin/servers/test", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: JSON.stringify({
            csrf_token: csrfInput ? csrfInput.value : "",
            server_id: form.dataset.serverId || null,
            url: urlInput ? urlInput.value : "",
            api_key: apiKeyInput ? apiKeyInput.value : "",
            allow_missing_port: Boolean(allowMissingPortInput && allowMissingPortInput.checked),
          }),
        });

        const payload = await response.json();
        if (!response.ok || !payload.ok) {
          showResult(payload.error || payload.detail || "Agent test failed.", "error");
          return;
        }

        showResult(`Agent OK. Temperature: ${payload.temperature} ${payload.unit || "C"}.`, "ok");
      } catch (error) {
        showResult("Agent test failed. Check the URL and network path.", "error");
      } finally {
        testButton.disabled = false;
      }
    });
  }

  function generateApiKey() {
    const bytes = new Uint8Array(32);
    if (window.crypto && window.crypto.getRandomValues) {
      window.crypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
    }
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  function showResult(message, state) {
    if (!testResult) {
      return;
    }
    testResult.hidden = false;
    testResult.textContent = message;
    testResult.dataset.state = state;
  }
})();
