import asyncio
from io import BytesIO
from pathlib import Path
import unittest
from unittest.mock import patch

from starlette.datastructures import Headers, UploadFile

from app.app_config import (
    get_branding_upload_dir,
    is_probably_safe_svg,
    is_valid_public_url,
    save_branding_upload,
    validate_settings_form,
)
from app.settings import get_settings


class AppConfigTests(unittest.TestCase):
    def test_public_url_validation_requires_http_host(self) -> None:
        self.assertTrue(is_valid_public_url("http://192.168.4.7:8088"))
        self.assertTrue(is_valid_public_url("https://thermo.example.test"))
        self.assertFalse(is_valid_public_url("file:///tmp/thermo"))
        self.assertFalse(is_valid_public_url("/tmp/thermo"))

    def test_invalid_public_url_is_warning_not_error(self) -> None:
        result = validate_settings_form(
            {
                "app_name": "Thermo Lab",
                "public_url": "file:///tmp/thermo",
                "accent_color": "#49c6e5",
            }
        )

        self.assertEqual(result.errors, [])
        self.assertEqual(result.values["public_url"], "")
        self.assertTrue(result.warnings)

    def test_branding_upload_generates_safe_served_path(self) -> None:
        with patch.dict("os.environ", {"THERMO_DB_PATH": "/private/tmp/thermo-test.db"}, clear=False):
            try:
                get_settings.cache_clear()
                upload = UploadFile(
                    BytesIO(b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"></svg>'),
                    filename="../../icon.svg",
                    headers=Headers({"content-type": "image/svg+xml"}),
                )

                path, error = asyncio.run(save_branding_upload(upload, "favicon"))

                self.assertIsNone(error)
                self.assertIsNotNone(path)
                self.assertTrue(str(path).startswith("/uploads/branding/favicon-"))
                self.assertFalse(".." in str(path))

                uploaded_file = get_branding_upload_dir() / Path(str(path)).name
                try:
                    self.assertTrue(uploaded_file.exists())
                finally:
                    uploaded_file.unlink(missing_ok=True)
            finally:
                get_settings.cache_clear()

    def test_svg_active_content_is_rejected(self) -> None:
        self.assertFalse(is_probably_safe_svg(b'<svg><script>alert(1)</script></svg>'))
        self.assertTrue(is_probably_safe_svg(b'<svg xmlns="http://www.w3.org/2000/svg"></svg>'))


if __name__ == "__main__":
    unittest.main()
