from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parent.parent
INSTALLER = PROJECT_ROOT / "scripts" / "install-agent.sh"


class InstallerScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = INSTALLER.read_text(encoding="utf-8")

    def test_local_temperature_test_uses_agent_api_key_header(self) -> None:
        self.assertIn('test_url_body "$temp_url" "X-API-Key: $AGENT_API_KEY"', self.script)
        self.assertIn('fail "Installer bug: missing generated agent API key from bootstrap response."', self.script)
        self.assertIn('verify_agent_api_key_env_consistency', self.script)

    def test_bootstrap_parser_extracts_agent_api_key_and_tarball_url(self) -> None:
        self.assertIn('payload.get("agent_api_key", "")', self.script)
        self.assertIn('payload.get("source_tarball_url") or payload.get("source_tarbball_url")', self.script)
        self.assertIn('BOOTSTRAP_AGENT_PORT', self.script)
        self.assertIn('BOOTSTRAP_BIND_HOST', self.script)

    def test_temperature_url_registration_includes_port_and_correct_path(self) -> None:
        self.assertIn('agent_url="http://$DETECTED_IP:$AGENT_PORT/temperature"', self.script)
        self.assertNotIn("/temp" + "rature", self.script)

    def test_unauthorized_temperature_response_is_handled_before_json_parse(self) -> None:
        test_agent_start = self.script.index("test_agent() {")
        status_check = self.script.index('if [ "$HTTP_STATUS" = "401" ]; then', test_agent_start)
        json_parse = self.script.index('payload = json.loads(os.environ["TEMP_JSON"])', test_agent_start)

        self.assertLess(status_check, json_parse)
        self.assertIn("Agent rejected the API key during local test.", self.script)
        self.assertIn("This means the service did not receive the same THERMO_AGENT_API_KEY", self.script)

    def test_systemd_start_restarts_existing_service_to_reload_env_file(self) -> None:
        start_service = self.script[
            self.script.index("start_systemd_service() {"):
            self.script.index("start_freebsd_service() {")
        ]

        self.assertIn('systemctl enable "$SERVICE_NAME"', start_service)
        self.assertIn('systemctl is-active --quiet "$SERVICE_NAME"', start_service)
        self.assertIn('systemctl restart "$SERVICE_NAME"', start_service)
        self.assertIn('systemctl start "$SERVICE_NAME"', start_service)
        self.assertNotIn('enable --now "$SERVICE_NAME"', start_service)

    def test_env_file_uses_generated_temperature_script_not_shell_pipeline(self) -> None:
        self.assertIn("write_temperature_command_script", self.script)
        self.assertIn("printf '%s\\n' \"$TEMP_COMMAND\"", self.script)
        self.assertIn("THERMO_TEMP_COMMAND=$temp_command_path", self.script)
        self.assertIn("verify_agent_env_temperature_command", self.script)
        self.assertNotIn("THERMO_TEMP_COMMAND=$temp_command_quoted", self.script)


if __name__ == "__main__":
    unittest.main()
