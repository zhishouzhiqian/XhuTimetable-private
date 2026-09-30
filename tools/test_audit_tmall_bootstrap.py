"""仅用合成数据检查编码、注册关联和脱敏输出。"""

import base64
import json
import unittest
from urllib.parse import quote_plus

from audit_tmall_bootstrap import audit


def entry(api, headers, body, data=None, encoded=False):
    text = json.dumps(body)
    content = {"text": text}
    if encoded:
        content = {"text": base64.b64encode(text.encode()).decode(), "encoding": "base64"}
    return {
        "request": {
            "url": "https://acs.m.taobao.com/gw/" + api + "/4.0/?data="
            + quote_plus(json.dumps(data or {})),
            "headers": [{"name": k, "value": v} for k, v in headers.items()],
        },
        "response": {"content": content},
    }


class BootstrapAuditTest(unittest.TestCase):
    def test_registration_encoding_reuse_and_no_secrets(self):
        secret = "SYNTHETIC_PRIVATE_DEVICE"
        utdid = "SYNTHETIC+UTDID/= "
        rows = [entry(
            "mtop.sys.newdeviceid", {"X-Sign": quote_plus("a+b/= "), "x-utdid": quote_plus(utdid)},
            {"ret": ["SUCCESS::调用成功"], "data": {"device_id": secret}},
            {"device_global_id": utdid}, encoded=True,
        ), entry(
            "mtop.example", {"x-sign": "signature", "x-devid": secret, "cookie": "PRIVATE_COOKIE"},
            {"ret": ["SUCCESS::调用成功"]},
        )]
        result = audit({"log": {"entries": rows}})
        self.assertTrue(result["registrations"][0]["global_id_matches_decoded_utdid"])
        self.assertEqual(result["registrations"][0]["later_records_reusing_id"], 1)
        self.assertEqual(result["groups"]["without_device_id"]["header_lengths"]["x-sign"]
                         ["form_decoded_once"], [6])
        output = json.dumps(result)
        for value in (secret, utdid, "PRIVATE_COOKIE", "signature"):
            self.assertNotIn(value, output)

    def test_failure_cannot_register_device_or_count_as_success(self):
        rows = [entry("mtop.sys.newdeviceid", {"x-sign": "private"}, {
            "ret": ["FAIL_SYS_ILEGEL_SIGN::private"], "data": {"device_id": "private"},
        }), entry("mtop.example", {"x-sign": "private", "x-devid": "private"}, {
            "ret": ["SUCCESSFUL_BUT_NOT_SUCCESS"],
        })]
        result = audit({"log": {"entries": rows}})
        self.assertIsNone(result["registrations"][0]["returned_device_id_length"])
        self.assertEqual(result["registrations"][0]["later_records_reusing_id"], 0)
        self.assertEqual(result["groups"]["with_device_id"]["successful_count"], 0)

    def test_unparseable_response_is_reported_without_body(self):
        row = entry("mtop.example", {"x-sign": "private"}, {})
        row["response"]["content"]["text"] = "PRIVATE_NON_JSON"
        result = audit({"log": {"entries": [row]}})
        self.assertEqual(result["signed_mtop_response_parse_failures"], 1)
        self.assertNotIn("PRIVATE_NON_JSON", json.dumps(result))

    def test_canonical_encoding_is_not_proof_of_single_encoding(self):
        rows = [entry("mtop.example", {"x-sign": "a%252Bb"}, {"ret": ["SUCCESS::ok"]}),
                entry("mtop.example", {"x-sign": "a/b"}, {"ret": ["SUCCESS::ok"]})]
        result = audit({"log": {"entries": rows}})
        # 双重编码仍可能规范；只有握有原始输出的契约检查才能发现多编码一层。
        self.assertEqual(result["encoding_observations"]["headers"]["x-sign"],
                         {"present": 2, "canonical_java_form": 1})


if __name__ == "__main__":
    unittest.main()
