"""离线请求契约：固定签名输入与线路编码，不实现签名、不提供网络发送能力。

本模块只覆盖匿名配置查询和设备注册的待核对字段，不是完整 MTOP 客户端。
字段映射依据本机 APK 的 InnerNetworkConverter；安全组件上下文仍待验证。
"""

from dataclasses import dataclass
import hashlib
import json
from types import MappingProxyType
from urllib.parse import parse_qsl


SUPPORTED_APIS = {
    "mtop.tmall.campus.guide.advertising.config.list": "1.0",
    "mtop.sys.newdeviceid": "4.0",
}
HEADER_MAP = {
    "x-t": "t", "x-appkey": "appKey", "x-pv": "pv",
    "x-ttid": "ttid", "x-utdid": "utdid", "x-devid": "deviceId",
    "x-features": "x-features", "x-extdata": "extdata",
}
FACTOR_HEADERS = ("x-sign", "x-mini-wua", "x-sgext", "x-umt")


def java_form_encode(value):
    """Java URLEncoder UTF-8 语义；与普通 URL 编码的 *、~、空格规则不同。"""
    safe = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_"
    return "".join(
        chr(byte) if byte in safe else "+" if byte == 32 else f"%{byte:02X}"
        for byte in value.encode("utf-8")
    )


@dataclass(frozen=True, repr=False)
class RequestSnapshot:
    api: str
    version: str
    body_text: str
    parameters: tuple[tuple[str, str], ...]

    def __repr__(self):
        return "RequestSnapshot(<内容已隐藏>)"

    @classmethod
    def freeze(cls, api, data, *, timestamp, app_key, protocol_version,
               utdid, ttid, device_id=None, features=None, extdata=None, biz_id=None):
        # InnerProtocolParamBuilderImpl.buildParams 在签名前以 Locale.US 转小写。
        api = api.lower()
        if api.lower() not in SUPPORTED_APIS:
            raise ValueError("离线契约只覆盖匿名配置查询和设备注册")
        if not isinstance(data, dict):
            raise ValueError("请求正文必须为对象")
        if any(not isinstance(v, str) or not v for v in
               (timestamp, app_key, protocol_version, utdid, ttid)):
            raise ValueError("缺少必要的原始协议字段")
        if not timestamp.isascii() or not timestamp.isdecimal() or len(timestamp) != 10:
            raise ValueError("时间戳必须为十位秒值，不能使用毫秒")
        for value in (device_id, features, extdata):
            if value is not None and (not isinstance(value, str) or not value):
                raise ValueError("可选字段必须非空或明确省略")
        if biz_id is not None and (api.lower() != "mtop.sys.newdeviceid" or biz_id != "4099"):
            raise ValueError("业务 ID 仅适用于已核对的设备注册流程")
        if api.lower() == "mtop.sys.newdeviceid":
            if device_id is not None:
                raise ValueError("首次注册不得携带预设设备 ID")
            if data.get("device_global_id") != utdid:
                raise ValueError("注册正文与原始 UTDID 不一致")
        elif data:
            raise ValueError("当前配置查询样本正文应为空对象")
        # 序列化仅发生一次。此后不得从字典重建正文或在发送前替换字段。
        body_text = json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        params = {
            "api": api, "v": SUPPORTED_APIS[api.lower()], "data": body_text,
            "t": timestamp, "appKey": app_key, "pv": protocol_version,
            "utdid": utdid, "ttid": ttid,
        }
        for key, value in (("deviceId", device_id), ("x-features", features), ("extdata", extdata), ("bizId", biz_id)):
            if value is not None:
                params[key] = value
        return cls(api, SUPPORTED_APIS[api.lower()], body_text, tuple(params.items()))

    def sign_parameters(self):
        # 只提供 SDK 组装前的参数，不能把这张表称为完整签名串或签名算法。
        return MappingProxyType(dict(self.parameters))

    def body_md5(self):
        # 只在内存比较，不用于认证，也不输出摘要。
        return hashlib.md5(self.body_text.encode("utf-8")).hexdigest()


@dataclass(frozen=True, repr=False)
class RawSecurityFactors:
    sign: str
    mini_wua: str
    sgext: str
    umt: str

    def __repr__(self):
        return "RawSecurityFactors(<内容已隐藏>)"

    def items(self):
        values = (self.sign, self.mini_wua, self.sgext, self.umt)
        if any(not isinstance(value, str) or not value for value in values):
            raise ValueError("缺少原始安全字段；不得用空值冒充有效签名")
        return tuple(zip(FACTOR_HEADERS, values))


@dataclass(frozen=True, repr=False)
class WirePreview:
    path: str
    query: str
    headers: tuple[tuple[str, str], ...]

    def __repr__(self):
        return "WirePreview(<内容已隐藏；仅供离线核对>)"


def preview(snapshot, raw_factors):
    params = snapshot.sign_parameters()
    headers = {
        header: java_form_encode(params[key])
        for header, key in HEADER_MAP.items() if key in params
    }
    headers.update((key, java_form_encode(value)) for key, value in raw_factors.items())
    return WirePreview(
        path=f"/gw/{snapshot.api.lower()}/{snapshot.version}/",
        query="data=" + java_form_encode(snapshot.body_text),
        headers=tuple(headers.items()),
    )


def check_wire(snapshot, raw_factors, wire):
    """比较冻结输入与待发送内容。只返回固定错误码，不回显不匹配值。"""
    expected = preview(snapshot, raw_factors)
    issues = []
    if wire.path != expected.path:
        issues.append("API_OR_VERSION_CHANGED")
    if wire.query != expected.query:
        issues.append("QUERY_ENCODING_OR_CONTENT_CHANGED")
    try:
        pairs = parse_qsl(wire.query, keep_blank_values=True, strict_parsing=True,
                          encoding="utf-8", errors="strict")
        if pairs != [("data", snapshot.body_text)]:
            issues.append("SIGNED_BODY_DIFFERS_FROM_WIRE")
    except (ValueError, UnicodeError):
        issues.append("INVALID_QUERY_ENCODING")
    headers = {}
    for key, value in wire.headers:
        key = key.lower()
        if key in headers:
            issues.append("DUPLICATE_HEADER")
        headers[key] = value
    # 此契约不接收任意额外头，防止诊断请求混入会话或覆盖固定参数。
    if headers.keys() != dict(expected.headers).keys():
        issues.append("UNEXPECTED_OR_MISSING_HEADERS")
    for key, value in expected.headers:
        if headers.get(key) != value:
            issues.append("HEADER_ENCODING_OR_VALUE_CHANGED")
            break
    return tuple(dict.fromkeys(issues))
