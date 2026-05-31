import unittest
from urllib.parse import urlparse

from app.setup_wizard import build_agent_temperature_url, validate_agent_temperature_url


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


if __name__ == "__main__":
    unittest.main()
