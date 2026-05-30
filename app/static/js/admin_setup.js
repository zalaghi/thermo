(function () {
  const copyButton = document.querySelector("[data-copy-command]");
  const command = document.querySelector(".setup-command-panel pre code");
  const feedback = document.querySelector("[data-copy-feedback]");

  if (!copyButton || !command || !feedback || !navigator.clipboard) {
    return;
  }

  copyButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(command.textContent.trim());
      feedback.hidden = false;
      feedback.textContent = "Copied.";
    } catch (error) {
      feedback.hidden = false;
      feedback.textContent = "Copy failed. Select the command manually.";
    }
  });
})();
