"""网络验收器只使用伪连接测试，不连接实际服务。"""

import json
from pathlib import Path
import tempfile
import unittest

from tmall_request_contract import RawSecurityFactors, RequestSnapshot, preview
from verify_tmall_anonymous_once import API, send_once, validate_candidate


def candidate():
    snapshot = RequestSnapshot.freeze(API, {}, timestamp="1700000000", app_key="test",
                                      protocol_version="test", utdid="synthetic", ttid="test")
    factors = RawSecurityFactors("sign+", "mini/", "sg=", "umt%")
    wire = preview(snapshot, factors)
    return {"parameters": dict(snapshot.parameters), "raw_factors": dict(factors.items()),
            "wire": {"path": wire.path, "query": wire.query, "headers": dict(wire.headers)}}


class FakeConnection:
    calls = 0
    status = 200
    ret = "SUCCESS::hidden response"
    fail = False

    def __init__(self, host, timeout):
        assert host == "acs.m.taobao.com"

    def request(self, method, path, headers):
        type(self).calls += 1
        assert method == "GET"
        assert path == "/gw/" + API + "/1.0/?data=%7B%7D"
        assert "cookie" not in {key.lower() for key in headers}
        if self.fail:
            raise OSError("PRIVATE_NETWORK_ERROR")

    def getresponse(self):
        return self

    def read(self, limit):
        return json.dumps({"ret": [self.ret], "data": "PRIVATE_RESPONSE"}).encode()

    def close(self):
        pass


class SenderTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.marker = Path(self.temp.name) / "once.json"
        FakeConnection.calls = 0
        FakeConnection.status = 200
        FakeConnection.ret = "SUCCESS::hidden response"
        FakeConnection.fail = False

    def send(self, value=None, now=1700000000):
        return send_once(candidate() if value is None else value, self.marker,
                         now=now, connection_factory=FakeConnection)

    def test_success_is_once_and_does_not_expose_response(self):
        result = self.send()
        self.assertTrue(result["success"])
        self.assertNotIn("PRIVATE_RESPONSE", json.dumps(result))
        self.assertFalse(self.send()["attempted"])
        self.assertEqual(FakeConnection.calls, 1)

    def test_network_failure_does_not_retry(self):
        FakeConnection.fail = True
        self.assertEqual(self.send()["result"], "NETWORK_FAILURE_NO_RETRY")
        self.assertFalse(self.send()["attempted"])
        self.assertEqual(FakeConnection.calls, 1)

    def test_invalid_sign_stops_and_unknown_codes_are_hidden(self):
        FakeConnection.ret = "FAIL_SYS_ILEGEL_SIGN::private detail"
        result = self.send()
        self.assertFalse(result["success"])
        self.assertEqual(result["business_codes"], ["FAIL_SYS_ILEGEL_SIGN"])

    def test_expired_or_cookie_candidate_never_connects(self):
        self.assertFalse(self.send(now=1700000121)["attempted"])
        value = candidate()
        value["wire"]["headers"]["Cookie"] = "PRIVATE_COOKIE"
        self.assertFalse(self.send(value)["attempted"])
        self.assertEqual(FakeConnection.calls, 0)
        self.assertFalse(self.marker.exists())

    def test_redirect_is_not_followed_or_treated_as_success(self):
        FakeConnection.status = 302
        self.assertFalse(self.send()["success"])
        self.assertEqual(FakeConnection.calls, 1)

    def test_unknown_error_is_not_echoed(self):
        FakeConnection.ret = "PRIVATE_TOKEN_AS_ERROR"
        self.assertEqual(self.send()["business_codes"], ["UNRECOGNIZED_CODE"])

    def test_registration_normalizes_api_before_signing_and_path(self):
        data = {"new_device": "true", "device_global_id": "synthetic", "c0": "Test", "c1": "Test",
                **{"c" + str(i): "" for i in range(2, 7)}}
        snapshot = RequestSnapshot.freeze("mtop.sys.newDeviceId", data, timestamp="1700000000",
            app_key="test", protocol_version="test", utdid="synthetic", ttid="test", biz_id="4099")
        factors = RawSecurityFactors("sign", "mini", "sg", "umt")
        wire = preview(snapshot, factors)
        self.assertEqual(snapshot.sign_parameters()["api"], "mtop.sys.newdeviceid")
        value = {"parameters": dict(snapshot.parameters), "raw_factors": dict(factors.items()),
                 "wire": {"path": wire.path, "query": wire.query, "headers": dict(wire.headers)}}
        self.assertEqual(validate_candidate(value, 1700000000, purpose="register").path,
                         "/gw/mtop.sys.newdeviceid/4.0/")
        self.assertNotIn("x-devid", dict(wire.headers))
        with self.assertRaises(ValueError):
            validate_candidate(value, 1700000000)  # 默认配置验收器拒绝注册。

    def test_reused_device_must_match_this_registration(self):
        snapshot = RequestSnapshot.freeze(API, {}, timestamp="1700000000", app_key="test",
            protocol_version="test", utdid="synthetic", ttid="test", device_id="new-id")
        factors = RawSecurityFactors("sign", "mini", "sg", "umt")
        wire = preview(snapshot, factors)
        value = {"parameters": dict(snapshot.parameters), "raw_factors": dict(factors.items()),
                 "wire": {"path": wire.path, "query": wire.query, "headers": dict(wire.headers)}}
        self.assertEqual(validate_candidate(value, 1700000000, purpose="registered_config",
                         expected_device_id="new-id"), wire)
        with self.assertRaises(ValueError):
            validate_candidate(value, 1700000000, purpose="registered_config", expected_device_id="old-id")

    def test_registered_id_only_passes_to_callback_after_valid_response(self):
        data = {"new_device": "true", "device_global_id": "synthetic", "c0": "Test", "c1": "Test",
                **{"c" + str(i): "" for i in range(2, 7)}}
        snapshot = RequestSnapshot.freeze("mtop.sys.newDeviceId", data, timestamp="1700000000",
            app_key="test", protocol_version="test", utdid="synthetic", ttid="test", biz_id="4099")
        factors = RawSecurityFactors("sign", "mini", "sg", "umt")
        wire = preview(snapshot, factors)
        value = {"parameters": dict(snapshot.parameters), "raw_factors": dict(factors.items()),
                 "wire": {"path": wire.path, "query": wire.query, "headers": dict(wire.headers)}}

        class RegistrationConnection(FakeConnection):
            device = "X" * 44

            def request(self, method, path, headers):
                assert "x-devid" not in headers

            def read(self, limit):
                return json.dumps({"ret": ["SUCCESS::ok"], "data": {"device_id": self.device}}).encode()

        received = []
        outcome = send_once(value, self.marker, now=1700000000, purpose="register",
                            connection_factory=RegistrationConnection, on_registered=received.append)
        self.assertTrue(outcome["success"])
        self.assertEqual(received, ["X" * 44])
        self.assertNotIn("X" * 44, json.dumps(outcome))
        RegistrationConnection.device = "invalid"
        received.clear()
        outcome = send_once(value, self.marker.with_name("invalid.json"), now=1700000000,
                            purpose="register", connection_factory=RegistrationConnection,
                            on_registered=received.append)
        self.assertFalse(outcome["success"])
        self.assertEqual(received, [])


if __name__ == "__main__":
    unittest.main()
