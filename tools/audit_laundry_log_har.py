"""离线读取校园 LZ4/protobuf 日志，仅输出业务字段结构，不输出原始日志或凭据。"""
import base64
import json
from pathlib import Path
from urllib.parse import urlsplit
import lz4.block


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError('截断 varint')
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError('无效 varint')


def fields(data):
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError('无效字段号')
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, offset = varint(data, offset)
            else:
                size = 8 if wire == 1 else 4
            if offset + size > len(data):
                raise ValueError('截断字段')
            value = data[offset:offset + size]
            offset += size
        else:
            raise ValueError('不支持的 wire 类型')
        yield number, wire, value


def log_rows(raw):
    for number, wire, value in fields(raw):
        if number != 1 or wire != 2:
            continue
        row = {}
        for n, w, v in fields(value):
            if n == 2 and w == 2:
                pair = {a: c.decode('utf-8') for a, b, c in fields(v) if b == 2 and a in (1, 2)}
                if 1 in pair and 2 in pair:
                    row[pair[1]] = pair[2]
        yield row


def records(path):
    entries = json.loads(Path(path).read_text('utf-8-sig'))['log']['entries']
    for entry in entries:
        request = entry['request']
        if urlsplit(request['url']).hostname != 'campus-2c-app.cn-hangzhou.log.aliyuncs.com':
            continue
        post = request.get('postData', {})
        if not post.get('text'):
            continue
        headers = {h['name'].lower(): h['value'] for h in request['headers']}
        size = int(headers.get('x-log-bodyrawsize', 0))
        if headers.get('x-log-compresstype') != 'lz4' or not 0 < size <= 8 * 1024 * 1024:
            raise ValueError('不支持的日志大小或压缩格式')
        if post.get('encoding') == 'base64':
            compressed = base64.b64decode(post['text'], validate=True)
        elif not post.get('encoding'):
            # 部分导出器把每个二进制字节存为 U+0000..U+00FF；严格还原，不忽略坏字符。
            compressed = post['text'].encode('latin-1', errors='strict')
        else:
            raise ValueError('不支持的日志编码')
        raw = lz4.block.decompress(compressed, uncompressed_size=size)
        if len(raw) != size:
            raise ValueError('解压长度不匹配')
        for row in log_rows(raw):
            api = row.get('arg1', '')
            if api.startswith('mtop.tmall.campus.') and 'arg6' in row and 'arg5' in row:
                yield api, json.loads(row['arg6']), json.loads(row['arg5'])


def shape(value):
    if isinstance(value, str):
        try:
            nested = json.loads(value)
            if isinstance(nested, (dict, list)):
                return {'jsonString': shape(nested)}
        except ValueError:
            pass
        return 'string'
    if isinstance(value, dict):
        return {key: shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    return type(value).__name__


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='+', type=Path)
    args = parser.parse_args()
    for file in args.files:
        seen = set()
        for api, request, response in records(file):
            if 'share.order.' not in api and 'cashier.checkout.query' not in api:
                continue
            schema = json.dumps([api, shape(request), shape(response)], ensure_ascii=False)
            if schema not in seen:
                print(file.name, schema)
                seen.add(schema)
