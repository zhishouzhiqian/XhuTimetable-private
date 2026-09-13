"""使用合成描述文件验证签名配置，不读取真实证书。"""

import datetime
import unittest
from configure_signing import APP_GROUP, APP_ID, WIDGET_ID, configure


def profile(bundle_id, uuid):
    return {
        "UUID": uuid,
        "TeamIdentifier": ["TESTTEAM"],
        "ApplicationIdentifierPrefix": ["TESTTEAM"],
        "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30),
        "DeveloperCertificates": [b"test-certificate"],
        "Entitlements": {
            "application-identifier": "TESTTEAM." + bundle_id,
            "com.apple.security.application-groups": [APP_GROUP],
        },
    }


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.app = profile(APP_ID, "app-uuid")
        self.widget = profile(WIDGET_ID, "widget-uuid")

    def test_separate_profiles_preserve_export_options(self):
        export, outputs = configure(self.app, self.widget, {"uploadSymbols": True})
        self.assertEqual(export["provisioningProfiles"], {APP_ID: "app-uuid", WIDGET_ID: "widget-uuid"})
        self.assertTrue(export["uploadSymbols"])
        self.assertEqual(outputs["team_id"], "TESTTEAM")

    def test_app_profile_cannot_sign_widget(self):
        with self.assertRaisesRegex(ValueError, "bundle ID"):
            configure(self.app, self.app, {})

    def test_missing_app_group(self):
        self.widget["Entitlements"]["com.apple.security.application-groups"] = []
        with self.assertRaisesRegex(ValueError, "App Group"):
            configure(self.app, self.widget, {})

    def test_expired_profile(self):
        self.app["ExpirationDate"] = datetime.datetime(2020, 1, 1)
        with self.assertRaisesRegex(ValueError, "expired"):
            configure(self.app, self.widget, {})

    def test_wrong_team_or_certificate(self):
        self.widget["TeamIdentifier"] = ["OTHERTEAM"]
        with self.assertRaisesRegex(ValueError, "same team"):
            configure(self.app, self.widget, {})
        self.widget["TeamIdentifier"] = ["TESTTEAM"]
        self.widget["DeveloperCertificates"] = [b"another-certificate"]
        with self.assertRaisesRegex(ValueError, "same signing certificate"):
            configure(self.app, self.widget, {})

    def test_development_profile_rejected(self):
        self.widget["Entitlements"]["get-task-allow"] = True
        with self.assertRaisesRegex(ValueError, "distribution profile"):
            configure(self.app, self.widget, {})


if __name__ == "__main__":
    unittest.main()
