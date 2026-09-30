import unittest
import base64
import json
import tempfile
from pathlib import Path
import lz4.block
from audit_laundry_log_har import fields, log_rows, shape, records


def blob(number, value):
    if len(value) >= 128:
        raise ValueError()
    return bytes([number * 8 + 2, len(value)]) + value


class LaundryLogsTest(unittest.TestCase):
    def test_protobuf_log_pairs(self):
        pair = blob(1, b'arg1') + blob(2, b'mtop.test')
        log = b'\x08\x01' + blob(2, pair)
        self.assertEqual(list(log_rows(blob(1, log))), [{'arg1': 'mtop.test'}])

    def test_truncated_value_rejected(self):
        with self.assertRaises(ValueError):
            list(fields(b'\x0a\x05ab'))

    def test_truncated_varint_rejected(self):
        with self.assertRaises(ValueError):
            list(fields(b'\x80'))

    def test_schema_does_not_emit_secrets(self):
        result = shape({'token': 'FAKE_SECRET', 'requestJson': '{"phone":"FAKE_PHONE"}'})
        self.assertNotIn('FAKE_', str(result))
        self.assertEqual(result['requestJson'], {'jsonString': {'phone': 'string'}})

    def test_both_lossless_binary_encodings(self):
        pairs = {'arg1': 'mtop.tmall.campus.test', 'arg6': '{}', 'arg5': '{}'}
        raw = blob(1, b''.join(blob(2, blob(1, k.encode()) + blob(2, v.encode())) for k, v in pairs.items()))
        compressed = lz4.block.compress(raw, store_size=False)
        for encoding in ('base64', None):
            with self.subTest(encoding=encoding), tempfile.TemporaryDirectory() as directory:
                post = {'text': base64.b64encode(compressed).decode() if encoding else compressed.decode('latin1')}
                if encoding:
                    post['encoding'] = encoding
                request = {'url': 'https://campus-2c-app.cn-hangzhou.log.aliyuncs.com/logstores/campus-app/shards/lb',
                           'headers': [{'name': 'x-log-compresstype', 'value': 'lz4'},
                                       {'name': 'x-log-bodyrawsize', 'value': str(len(raw))}], 'postData': post}
                file = Path(directory) / 'synthetic.har'
                file.write_text(json.dumps({'log': {'entries': [{'request': request}]}}), encoding='utf-8')
                self.assertEqual(list(records(file)), [('mtop.tmall.campus.test', {}, {})])


if __name__ == '__main__':
    unittest.main()
