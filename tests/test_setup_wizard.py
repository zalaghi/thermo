import unittest
from urllib.parse import urlparse

from app.setup_wizard import (
    PairingFormValues,
    PLATFORM_VALUES,
    build_agent_temperature_url,
    build_install_commands,
    build_synology_docker_build_command,
    build_synology_installer_command,
    build_synology_wget_installer_command,
    default_pairing_form_data,
    validate_agent_temperature_url,
)


class SetupWizardUrlTests(unittest.TestCase):
    def test_agent_temperature_url_uses_correct_temperature_path_and_port(self) -> None:
        url = build_agent_temperature_url("192.168.4.2", 8090)
        parsed = urlparse(url)

        self.assertEqual(url, "http://192.168.4.2:8090/temperature")
        self.assertEqual(parsed.path, "/temperature")
        self.assertEqual(parsed.port, 8090)
        self.assertNotIn("temp" + "rature", url)

    def test_installer_url_validation_requires_port(self) -> None:
        error = validate_agent_temperature_url("http://192.168.4.2/temperature", require_port=True)

        self.assertIsNotNone(error)
        self.assertIn("port", error or "")

    def test_installer_url_validation_rejects_misspelled_path(self) -> None:
        bad_path = "/temp" + "rature"
        error = validate_agent_temperature_url(f"http://192.168.4.2:8090{bad_path}", require_port=True)

        self.assertIsNotNone(error)
        self.assertIn("/temperature", error or "")

    def test_installer_url_validation_rejects_non_http_scheme(self) -> None:
        error = validate_agent_temperature_url("file:///tmp/temperature", require_port=True)

        self.assertIsNotNone(error)
        self.assertIn("http:// or https://", error or "")

    def test_default_security_options_restrict_to_public_ip(self) -> None:
        form_data = default_pairing_form_data("http://192.168.4.7:8088")

        self.assertTrue(form_data["restrict_agent_to_thermo_ip"])
        self.assertEqual(form_data["allowed_client"], "192.168.4.7")
        self.assertEqual(form_data["rate_limit_per_minute"], "120")

    def test_install_command_includes_selected_security_options(self) -> None:
        values = PairingFormValues(
            server_name="Fedora",
            platform="generic_systemd_linux",
            thermo_url="http://192.168.4.7:8088",
            bind_host="0.0.0.0",
            agent_port=8090,
            warning_threshold=65,
            critical_threshold=80,
            restrict_agent_to_thermo_ip=True,
            allowed_client="192.168.4.7",
            protect_health=True,
            rate_limit_per_minute=60,
        )

        linux_command, _freebsd_fetch, _freebsd_curl = build_install_commands(
            thermo_url=values.thermo_url,
            raw_token="pairing-token",
            values=values,
        )

        self.assertIn('--allow-client "192.168.4.7"', linux_command)
        self.assertIn("--protect-health", linux_command)
        self.assertIn('--rate-limit "60"', linux_command)

    def test_synology_platform_is_available(self) -> None:
        self.assertIn("synology_dsm", PLATFORM_VALUES)

    def test_synology_installer_command_uses_dsm_install_dir_without_sudo(self) -> None:
        values = PairingFormValues(
            server_name="Synology",
            platform="synology_dsm",
            thermo_url="http://192.168.4.7:8088",
            bind_host="0.0.0.0",
            agent_port=8090,
            warning_threshold=65,
            critical_threshold=80,
            restrict_agent_to_thermo_ip=True,
            allowed_client="192.168.4.7",
            protect_health=False,
            rate_limit_per_minute=120,
        )

        command = build_synology_installer_command(
            thermo_url=values.thermo_url,
            raw_token="pairing-token",
            values=values,
        )

        self.assertIn('--install-dir "/volume1/@appdata/thermo-agent"', command)
        self.assertIn('--allow-client "192.168.4.7"', command)
        self.assertNotIn("sudo sh", command)

        wget_command = build_synology_wget_installer_command(
            thermo_url=values.thermo_url,
            raw_token="pairing-token",
            values=values,
        )
        self.assertIn("wget -q -O -", wget_command)
        self.assertIn('--install-dir "/volume1/@appdata/thermo-agent"', wget_command)

    def test_synology_docker_command_is_local_build_not_fake_published_image(self) -> None:
        command = build_synology_docker_build_command()

        self.assertIn("docker build", command)
        self.assertIn("thermo-agent:local", command)
        self.assertIn("main.tar.gz", command)


if __name__ == "__main__":
    unittest.main()
