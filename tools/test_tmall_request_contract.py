"""请求契约的离线回归测试，全部使用合成身份和合成安全字段。"""

from dataclasses import replace
import unittest

from tmall_request_contract import (
    RawSecurityFactors, RequestSnapshot, check_wire, java_form_encode, preview,
)


CONFIG = "mtop.tmall.campus.guide.advertising.config.list"
REGISTER = "mtop.sys.newdeviceid"
FIELDS = dict(timestamp="1700000000", app_key="synthetic-app", protocol_version="test",
              utdid="SYNTHETIC+UTDID/=", ttid="synthetic@test")
FACTORS = RawSecurityFactors("synthetic+sign/=", "synthetic%wua", "synthetic~sg*", "合成 umt")


class RequestContractTest(unittest.TestCase):
    def test_java_encoding_vectors(self):
        self.assertEqual(java_form_encode("AZaz09.-*_~ +/=%"), "AZaz09.-*_%7E+%2B%2F%3D%25")
        self.assertEqual(java_form_encode("中文😀"), "%E4%B8%AD%E6%96%87%F0%9F%98%80")
        self.assertEqual(java_form_encode("%2B"), "%252B")  # 原始百分号串不能被自动解码。

    def test_freezes_body_once_before_source_mutation(self):
        data = {"new_device": "true", "device_global_id": FIELDS["utdid"], "c0": "合成 +/%"}
        snapshot = RequestSnapshot.freeze(REGISTER, data, **FIELDS)
        original_md5 = snapshot.body_md5()
        data["c0"] = "changed after signing"
        self.assertEqual(snapshot.body_md5(), original_md5)
        self.assertEqual(snapshot.sign_parameters()["data"], snapshot.body_text)
        self.assertNotIn("changed after signing", snapshot.body_text)
        with self.assertRaises(TypeError):
            snapshot.sign_parameters()["t"] = "1700000001"
        self.assertEqual(check_wire(snapshot, FACTORS, preview(snapshot, FACTORS)), ())

    def test_newdevice_has_no_preset_id_and_matches_utdid(self):
        with self.assertRaises(ValueError):
            RequestSnapshot.freeze(REGISTER, {"device_global_id": "wrong"}, **FIELDS)
        with self.assertRaises(ValueError):
            RequestSnapshot.freeze(REGISTER, {"device_global_id": FIELDS["utdid"]},
                                   device_id="fabricated", **FIELDS)
        snapshot = RequestSnapshot.freeze(REGISTER, {"device_global_id": FIELDS["utdid"]}, **FIELDS)
        self.assertNotIn("x-devid", dict(preview(snapshot, FACTORS).headers))

    def test_registered_id_used_in_parameters_and_header(self):
        snapshot = RequestSnapshot.freeze(CONFIG, {}, device_id="SYNTHETIC/REGISTERED+ID", **FIELDS)
        self.assertEqual(snapshot.sign_parameters()["deviceId"], "SYNTHETIC/REGISTERED+ID")
        self.assertEqual(dict(preview(snapshot, FACTORS).headers)["x-devid"], "SYNTHETIC%2FREGISTERED%2BID")
        # 本测试只验证值一致；注册来源必须由上层注册流程验证。

    def test_timestamp_or_device_changed_after_signing(self):
        snapshot = RequestSnapshot.freeze(CONFIG, {}, device_id="SYNTHETIC_ID", **FIELDS)
        wire = preview(snapshot, FACTORS)
        for header in ("x-t", "x-devid", "x-utdid", "x-pv"):
            headers = dict(wire.headers)
            headers[header] = "changed"
            self.assertIn("HEADER_ENCODING_OR_VALUE_CHANGED",
                          check_wire(snapshot, FACTORS, replace(wire, headers=tuple(headers.items()))))

    def test_rejects_missing_or_double_encoding(self):
        snapshot = RequestSnapshot.freeze(CONFIG, {}, **FIELDS)
        wire = preview(snapshot, FACTORS)
        for value in (FACTORS.sign, java_form_encode(dict(wire.headers)["x-sign"])):
            headers = dict(wire.headers)
            headers["x-sign"] = value
            self.assertIn("HEADER_ENCODING_OR_VALUE_CHANGED",
                          check_wire(snapshot, FACTORS, replace(wire, headers=tuple(headers.items()))))
        for query in ("data=" + java_form_encode(java_form_encode(snapshot.body_text)),
                      "data=%7B%20%7D", wire.query + "&data=%7B%7D"):
            self.assertIn("SIGNED_BODY_DIFFERS_FROM_WIRE",
                          check_wire(snapshot, FACTORS, replace(wire, query=query)))

    def test_missing_factors_duplicate_headers_or_account_cookie(self):
        snapshot = RequestSnapshot.freeze(CONFIG, {}, **FIELDS)
        with self.assertRaises(ValueError):
            preview(snapshot, RawSecurityFactors("", "a", "b", "c"))
        wire = preview(snapshot, FACTORS)
        self.assertIn("DUPLICATE_HEADER", check_wire(snapshot, FACTORS,
                      replace(wire, headers=wire.headers + (("X-T", "1700000000"),))))
        self.assertIn("UNEXPECTED_OR_MISSING_HEADERS", check_wire(snapshot, FACTORS,
                      replace(wire, headers=wire.headers + (("Cookie", "PRIVATE_COOKIE"),))))

    def test_rejects_milliseconds_or_unsupported_api(self):
        with self.assertRaises(ValueError):
            RequestSnapshot.freeze(CONFIG, {}, **{**FIELDS, "timestamp": "1700000000000"})
        with self.assertRaises(ValueError):
            RequestSnapshot.freeze("mtop.taobao.mloginservice.snslogin", {}, **FIELDS)

    def test_mismatch_and_object_repr_do_not_expose_values(self):
        snapshot = RequestSnapshot.freeze(CONFIG, {}, **FIELDS)
        wire = preview(snapshot, FACTORS)
        result = check_wire(snapshot, FACTORS, replace(wire, query="data=PRIVATE_SECRET"))
        self.assertNotIn("PRIVATE_SECRET", repr(result))
        for obj in (snapshot, FACTORS, wire):
            self.assertNotIn("synthetic", repr(obj).lower())


if __name__ == "__main__":
    unittest.main()
