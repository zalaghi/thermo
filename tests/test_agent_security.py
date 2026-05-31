import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from agent.main import app, rate_limit_events


class AgentSecurityTests(unittest.TestCase):
    def setUp(self) -> None:
        rate_limit_events.clear()

    def test_temperature_requires_api_key(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "THERMO_AGENT_API_KEY": "secret",
                "THERMO_TEMP_COMMAND": "echo 42.5",
            },
            clear=True,
        ):
            with TestClient(app, client=("192.168.4.7", 5000)) as client:
                response = client.get("/temperature")

        self.assertEqual(response.status_code, 401)

    def test_temperature_blocks_disallowed_client_ip(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "THERMO_AGENT_API_KEY": "secret",
                "THERMO_TEMP_COMMAND": "echo 42.5",
                "THERMO_AGENT_ALLOWED_CLIENTS": "192.168.4.7",
            },
            clear=True,
        ):
            with TestClient(app, client=("192.168.4.8", 5000)) as client:
                response = client.get("/temperature", headers={"X-API-Key": "secret"})

        self.assertEqual(response.status_code, 403)

    def test_temperature_rate_limit(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "THERMO_AGENT_API_KEY": "secret",
                "THERMO_TEMP_COMMAND": "echo 42.5",
                "THERMO_AGENT_RATE_LIMIT_PER_MINUTE": "1",
            },
            clear=True,
        ):
            with TestClient(app, client=("192.168.4.7", 5000)) as client:
                first = client.get("/temperature", headers={"X-API-Key": "secret"})
                second = client.get("/temperature", headers={"X-API-Key": "secret"})

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 429)

    def test_temperature_allows_valid_key_and_allowed_ip(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "THERMO_AGENT_API_KEY": "secret",
                "THERMO_TEMP_COMMAND": "echo 42.5",
                "THERMO_AGENT_ALLOWED_CLIENTS": "192.168.4.0/24",
            },
            clear=True,
        ):
            with TestClient(app, client=("192.168.4.7", 5000)) as client:
                response = client.get("/temperature", headers={"X-API-Key": "secret"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"temperature": 42.5, "unit": "C"})

    def test_health_can_be_protected(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "THERMO_AGENT_API_KEY": "secret",
                "THERMO_AGENT_PROTECT_HEALTH": "true",
            },
            clear=True,
        ):
            with TestClient(app, client=("192.168.4.7", 5000)) as client:
                unauthorized = client.get("/health")
                authorized = client.get("/health", headers={"X-API-Key": "secret"})

        self.assertEqual(unauthorized.status_code, 401)
        self.assertEqual(authorized.status_code, 200)
        self.assertEqual(authorized.json(), {"ok": True})

    def test_invalid_allowlist_configuration_fails_closed(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "THERMO_AGENT_API_KEY": "secret",
                "THERMO_TEMP_COMMAND": "echo 42.5",
                "THERMO_AGENT_ALLOWED_CLIENTS": "not-an-ip",
            },
            clear=True,
        ):
            with TestClient(app, client=("192.168.4.7", 5000)) as client:
                response = client.get("/temperature", headers={"X-API-Key": "secret"})

        self.assertEqual(response.status_code, 500)
        self.assertNotIn("secret", response.text)


if __name__ == "__main__":
    unittest.main()
