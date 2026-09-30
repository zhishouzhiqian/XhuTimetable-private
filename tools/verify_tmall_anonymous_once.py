"""一次匿名公开配置验收：签名组件不联网，本机只发一次 HTTPS GET。"""

import argparse
import http.client
import json
import re
from pathlib import Path
import subprocess
import time

from tmall_request_contract import RawSecurityFactors, RequestSnapshot, WirePreview, check_wire


API = "mtop.tmall.campus.guide.advertising.config.list"
HOST = "acs.m.taobao.com"
KNOWN_CODES = {
    "SUCCESS", "FAIL_SYS_ILEGEL_SIGN", "FAIL_SYS_PROTOVER_MISSED",
    "FAIL_SYS_SESSION_EXPIRED", "FAIL_SYS_TOKEN_EMPTY", "FAIL_SYS_TOKEN_EXOIRED",
    "FAIL_SYS_ILLEGAL_ACCESS", "FAIL_SYS_USER_VALIDATE", "FAIL_SYS_TRAFFIC_LIMIT",
}


def validate_candidate(candidate, now, *, purpose="config", expected_device_id=None):
    params = candidate["parameters"]
    allowed = {"api", "v", "data", "t", "appKey", "pv", "utdid", "ttid", "x-features", "extdata"}
    if purpose not in {"config", "register", "registered_config"}:
        raise ValueError("未知验收阶段")
    registration = purpose == "register"
    if registration:
        allowed.add("bizId")
    if purpose == "registered_config":
        allowed.add("deviceId")
        if not expected_device_id or params.get("deviceId") != expected_device_id:
            raise ValueError("设备 ID 不来自本次注册响应")
    expected_api = "mtop.sys.newdeviceid" if registration else API
    if set(params) - allowed or params.get("api") != expected_api:
        raise ValueError("不符合匿名配置请求范围")
    data = json.loads(params["data"])
    if registration:
        if not isinstance(data, dict) or set(data) != {"new_device", "device_global_id", *("c" + str(i) for i in range(7))}:
            raise ValueError("注册字段不符合已观察样本")
        if data["new_device"] != "true" or params.get("bizId") != "4099":
            raise ValueError("注册标记或业务 ID 不一致")
        if not all(isinstance(v, str) for v in data.values()) or not data["c0"] or not data["c1"]:
            raise ValueError("注册型号字段缺失")
        if any(data["c" + str(i)] for i in range(2, 7)):
            raise ValueError("本次诊断不采集硬件身份字段")
    elif params.get("data") != "{}":
        raise ValueError("配置请求正文应为空对象")
    if abs(now - int(params["t"])) > 120:
        raise ValueError("快照已过时，不发送")
    snapshot = RequestSnapshot.freeze(
        expected_api, data, timestamp=params["t"], app_key=params["appKey"], protocol_version=params["pv"],
        utdid=params["utdid"], ttid=params["ttid"], features=params.get("x-features"),
        extdata=params.get("extdata"), device_id=params.get("deviceId"), biz_id=params.get("bizId"),
    )
    if dict(snapshot.parameters) != params:
        raise ValueError("快照与参数不一致")
    factors = candidate["raw_factors"]
    if set(factors) != {"x-sign", "x-mini-wua", "x-sgext", "x-umt"}:
        raise ValueError("安全字段集合不一致")
    raw = RawSecurityFactors(*(factors[k] for k in ("x-sign", "x-mini-wua", "x-sgext", "x-umt")))
    value = candidate["wire"]
    wire = WirePreview(value["path"], value["query"], tuple(value["headers"].items()))
    if check_wire(snapshot, raw, wire):
        raise ValueError("发送前契约核对失败")
    return wire


def send_once(candidate, marker, *, now=None, connection_factory=http.client.HTTPSConnection,
              purpose="config", expected_device_id=None, on_registered=None):
    try:
        wire = validate_candidate(candidate, time.time() if now is None else now,
                                  purpose=purpose, expected_device_id=expected_device_id)
    except (ValueError, KeyError, TypeError, AttributeError, UnicodeError):
        return {"attempted": False, "result": "CANDIDATE_REJECTED"}
    # 在建连前排他创建标记；即使超时、断线或程序崩溃，也不能用同一标记重试。
    try:
        with marker.open("x", encoding="utf-8") as file:
            json.dump({"attempt_reserved": True, "scope": purpose}, file)
    except FileExistsError:
        return {"attempted": False, "result": "ATTEMPT_ALREADY_RESERVED"}
    connection = None
    try:
        connection = connection_factory(HOST, timeout=15)
        # 不跟随跳转，不设置 Cookie，不启用调试日志，不使用系统浏览器会话。
        connection.request("GET", wire.path + "?" + wire.query, headers=dict(wire.headers))
        response = connection.getresponse()
        payload = response.read(1024 * 1024 + 1)
        codes = []
        body = None
        if len(payload) <= 1024 * 1024:
            try:
                body = json.loads(payload)
                ret = body.get("ret", []) if isinstance(body, dict) else []
                if isinstance(ret, list):
                    for item in ret:
                        code = item.split("::", 1)[0] if isinstance(item, str) else ""
                        codes.append(code if code in KNOWN_CODES else "UNRECOGNIZED_CODE")
            except (ValueError, UnicodeError):
                pass
        outcome = {"attempted": True, "http_status": response.status, "business_codes": codes,
                   "success": response.status == 200 and "SUCCESS" in codes}
        if purpose == "register" and outcome["success"]:
            data = body.get("data") if isinstance(body, dict) else None
            device_id = data.get("device_id") if isinstance(data, dict) else None
            valid = isinstance(device_id, str) and re.fullmatch(r"[A-Za-z0-9_=\-]{44}", device_id) is not None
            outcome["registered_device_id_valid"] = valid
            outcome["success"] = valid
            if valid and on_registered is not None:
                on_registered(device_id)  # 只交给调用者内存，不放入结果或日志。
        return outcome
    except (OSError, http.client.HTTPException):
        return {"attempted": True, "result": "NETWORK_FAILURE_NO_RETRY"}
    finally:
        if connection is not None:
            connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--attempt-marker", type=Path, required=True)
    parser.add_argument("--send-once", action="store_true", required=True)
    args = parser.parse_args()
    # 原始字段只从探针私有文件读入内存，绝不输出 adb 的原始结果。
    result = subprocess.run([args.adb, "-s", args.serial, "exec-out", "run-as",
                             "vip.mystery0.xhu.timetable.offlineprobe", "cat", "files/candidate.json"],
                            capture_output=True, timeout=15)
    try:
        if result.returncode:
            raise ValueError()
        candidate = json.loads(result.stdout)
    except (ValueError, UnicodeError):
        parser.exit(1, "无法读取本次候选请求，未发送。\n")
    outcome = send_once(candidate, args.attempt_marker)
    print(json.dumps(outcome, ensure_ascii=False))


if __name__ == "__main__":
    main()
