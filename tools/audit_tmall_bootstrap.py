"""离线核对首次启动 HAR；只输出计数、字段长度和相等性，不联网或输出凭据。"""

import argparse
import base64
import json
from pathlib import Path
from urllib.parse import parse_qsl, unquote_plus, urlsplit

from tmall_request_contract import FACTOR_HEADERS, HEADER_MAP, java_form_encode


SECURITY_HEADERS = ("x-sign", "x-mini-wua", "x-sgext", "x-umt", "x-utdid")


def response_json(entry):
    content = entry["response"].get("content", {})
    text = content.get("text", "")
    if content.get("encoding") == "base64":
        text = base64.b64decode(text).decode("utf-8")
    value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("响应不是对象")
    return value


def successful(body):
    ret = body.get("ret")
    return isinstance(ret, list) and any(
        isinstance(item, str) and item.split("::", 1)[0] == "SUCCESS"
        for item in ret
    )


def audit(har):
    entries = har["log"]["entries"]
    rows = []
    skipped = 0
    for index, entry in enumerate(entries, 1):
        request = entry["request"]
        url = urlsplit(request["url"])
        headers = {h["name"].lower(): h["value"] for h in request.get("headers", [])}
        if url.hostname != "acs.m.taobao.com" or not headers.get("x-sign"):
            continue
        try:
            body = response_json(entry)
        except (ValueError, UnicodeError):
            skipped += 1
            continue
        rows.append((index, entry, headers, body))

    registrations = []
    for index, entry, headers, body in rows:
        url = urlsplit(entry["request"]["url"])
        if url.path.lower() != "/gw/mtop.sys.newdeviceid/4.0/":
            continue
        params = dict(parse_qsl(url.query, keep_blank_values=True))
        try:
            data = json.loads(params.get("data", "{}"))
            if not isinstance(data, dict):
                raise ValueError()
        except ValueError:
            data = {}
        response_data = body.get("data")
        device_id = response_data.get("device_id") if isinstance(response_data, dict) else None
        valid_device = isinstance(device_id, str) and bool(device_id) and successful(body)
        registrations.append({
            "entry_one_based": index,
            "successful": successful(body),
            "request_has_device_id": bool(headers.get("x-devid")),
            "request_has_session": bool(headers.get("x-sid")),
            "request_has_cookie": bool(headers.get("cookie")),
            "global_id_matches_decoded_utdid": bool(data.get("device_global_id"))
            and data.get("device_global_id") == unquote_plus(headers.get("x-utdid", "")),
            "returned_device_id_length": len(device_id) if valid_device else None,
            # HAR 顺序不等于请求完成顺序，此处只做记录顺序和数据相等性核对。
            "later_records_reusing_id": sum(
                valid_device and later_index > index
                and unquote_plus(later_headers.get("x-devid", "")) == device_id
                for later_index, _, later_headers, _ in rows
            ),
        })

    groups = {}
    for present in (False, True):
        selected = [r for r in rows if bool(r[2].get("x-devid")) == present]
        groups["with_device_id" if present else "without_device_id"] = {
            "count": len(selected),
            "successful_count": sum(successful(r[3]) for r in selected),
            "header_lengths": {
                key: {
                    "present_count": sum(key in r[2] for r in selected),
                    "wire": sorted({len(r[2][key]) for r in selected if key in r[2]}),
                    "form_decoded_once": sorted({
                        len(unquote_plus(r[2][key])) for r in selected if key in r[2]
                    }),
                }
                for key in SECURITY_HEADERS
            },
        }
    return {
        "entry_count": len(entries),
        "signed_mtop_response_parse_failures": skipped,
        "registrations": registrations,
        "groups": groups,
        "encoding_observations": encoding_observations(rows),
    }


def encoding_observations(rows):
    """只检查线路编码规范性；不能从 HAR 倒推出真实签名前内容或编码层数。"""
    counts = {key: {"present": 0, "canonical_java_form": 0}
              for key in dict.fromkeys((*HEADER_MAP, *FACTOR_HEADERS))}
    bodies = {"present": 0, "canonical_java_form": 0}
    for _, entry, headers, _ in rows:
        for key, count in counts.items():
            if key in headers:
                count["present"] += 1
                count["canonical_java_form"] += (
                    java_form_encode(unquote_plus(headers[key])) == headers[key]
                )
        request = entry["request"]
        for form in (urlsplit(request["url"]).query,
                     request.get("postData", {}).get("text", "")):
            for pair in form.split("&"):
                if pair.startswith("data="):
                    value = pair[5:]
                    bodies["present"] += 1
                    bodies["canonical_java_form"] += java_form_encode(unquote_plus(value)) == value
    return {"headers": counts, "bodies": bodies}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("har", type=Path)
    args = parser.parse_args()
    try:
        result = audit(json.loads(args.har.read_text(encoding="utf-8-sig")))
    except (OSError, ValueError, KeyError, TypeError):
        # 不输出异常原文，避免解析失败时泄露原始数据或本机路径。
        parser.exit(1, "无法解析 HAR，请检查文件与结构。\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
