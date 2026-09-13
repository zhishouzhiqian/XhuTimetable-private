"""校验双 Profile 并生成 CI 使用的导出配置，不打印凭据内容。"""

import argparse
import datetime
import os
import plistlib
from pathlib import Path

APP_ID = "vip.mystery0.xhu.timetable"
WIDGET_ID = APP_ID + ".widgets"
APP_GROUP = "group." + APP_ID


def validate_profile(profile, bundle_id):
    """拒绝 App ID、共享组、有效期或发布类型不匹配的描述文件。"""
    entitlements = profile.get("Entitlements", {})
    prefix = profile.get("ApplicationIdentifierPrefix", [""])[0]
    if entitlements.get("application-identifier") != f"{prefix}.{bundle_id}":
        raise ValueError(f"Profile does not match bundle ID: {bundle_id}")
    if APP_GROUP not in entitlements.get("com.apple.security.application-groups", []):
        raise ValueError(f"Profile is missing the shared App Group: {bundle_id}")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime) or expires.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError(f"Profile has expired: {bundle_id}")
    if entitlements.get("get-task-allow", False) or profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices", False):
        raise ValueError(f"An App Store Connect distribution profile is required: {bundle_id}")
    if not profile.get("UUID") or not profile.get("TeamIdentifier"):
        raise ValueError(f"Profile metadata is incomplete: {bundle_id}")
    return profile["UUID"], profile["TeamIdentifier"][0]


def configure(app, widget, export):
    app_uuid, team = validate_profile(app, APP_ID)
    widget_uuid, widget_team = validate_profile(widget, WIDGET_ID)
    if team != widget_team:
        raise ValueError("Both profiles must belong to the same team")
    if not set(app.get("DeveloperCertificates", [])) & set(widget.get("DeveloperCertificates", [])):
        raise ValueError("Both profiles must include the same signing certificate")
    export = dict(export)
    export.setdefault("method", "app-store-connect")
    export["signingStyle"] = "manual"
    export["teamID"] = team
    profiles = dict(export.get("provisioningProfiles", {}))
    profiles.update({APP_ID: app_uuid, WIDGET_ID: widget_uuid})
    export["provisioningProfiles"] = profiles
    return export, {"app_uuid": app_uuid, "widget_uuid": widget_uuid, "team_id": team}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-profile", type=Path, required=True)
    parser.add_argument("--widget-profile", type=Path, required=True)
    parser.add_argument("--export-options", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    inputs = [plistlib.loads(path.read_bytes()) for path in (args.app_profile, args.widget_profile, args.export_options)]
    export, outputs = configure(*inputs)
    args.output.write_bytes(plistlib.dumps(export))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")
    print("Validated app and widget provisioning profiles")


if __name__ == "__main__":
    main()
