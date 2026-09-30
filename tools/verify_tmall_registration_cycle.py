"""注册一次并复用一次；设备 ID 只在内存和探针私有目录中传递。"""

import argparse
import json
from pathlib import Path
import subprocess
import time

from tmall_request_contract import RequestSnapshot
from verify_tmall_anonymous_once import API, send_once


PACKAGE = "vip.mystery0.xhu.timetable.offlineprobe"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--attempt-dir", type=Path, required=True)
    parser.add_argument("--send-once", action="store_true", required=True)
    args = parser.parse_args()

    def adb(*command, data=None):
        result = subprocess.run([args.adb, "-s", args.serial, *command], input=data,
                                capture_output=True, timeout=20)
        if result.returncode:
            raise RuntimeError("ADB 操作失败；不回显原始输出")
        return result.stdout

    def read_candidate():
        return json.loads(adb("exec-out", "run-as", PACKAGE, "cat", "files/candidate.json"))

    candidate = read_candidate()
    registered = []
    outcome = send_once(candidate, args.attempt_dir / "registration-attempt.json",
                        purpose="register", on_registered=registered.append)
    print(json.dumps({"registration": outcome}), flush=True)
    if not outcome.get("success") or not registered:
        return
    device_id = registered[0]
    previous = candidate["parameters"]
    next_snapshot = RequestSnapshot.freeze(
        API, {}, timestamp=str(int(time.time())), app_key=previous["appKey"],
        protocol_version=previous["pv"], utdid=previous["utdid"], ttid=previous["ttid"],
        device_id=device_id, features=previous.get("x-features"), extdata=previous.get("extdata"),
    )
    # shell 指令为固定字面量；设备 ID 等只走 stdin，不进入命令参数或终端。
    adb("shell", "am", "force-stop", PACKAGE)
    adb("shell", "run-as " + PACKAGE + " sh -c 'cat > files/next-snapshot.json'",
        data=json.dumps(dict(next_snapshot.parameters)).encode())
    adb("shell", "am", "start", "-n", PACKAGE + "/.ProbeActivity",
        "--ez", "prepareCandidate", "true", "--ez", "useNextSnapshot", "true")
    # 只等待本地签名，不重试网络请求。
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            candidate = read_candidate()
            if candidate.get("parameters") == dict(next_snapshot.parameters):
                break
        except (RuntimeError, ValueError):
            pass
        time.sleep(0.5)
    else:
        print(json.dumps({"reuse": {"attempted": False, "result": "LOCAL_SIGNING_NOT_READY"}}))
        return
    outcome = send_once(candidate, args.attempt_dir / "registered-config-attempt.json",
                        purpose="registered_config", expected_device_id=device_id)
    print(json.dumps({"reuse": outcome}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        # 任何不确定结果均终止；不回显潜在敏感异常，不自动再次注册。
        print(json.dumps({"stopped": True, "result": "LOCAL_FAILURE_NO_RETRY"}))
        raise SystemExit(1)
