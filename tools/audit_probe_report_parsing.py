"""用 Python 精确模拟 ProbeResourceTrace.m 生成的宿主通道报告行，
并复现 ProbeTests.m 里 ParseHostRow 的解析逻辑，验证标签逐字对齐。

本机无 Xcode，ParseHostRow 只能这样验证：标签差一个字解析就会失败，
而失败会让 CheckHostChannelTrace 在 CI 上直接中止整轮构建。
只读，不修改任何文件。
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
impl = (root / 'tools' / 'ios-component-probe' / 'ProbeResourceTrace.m').read_text(
    encoding='utf-8', errors='replace')
tests = (root / 'tools' / 'ios-component-probe' / 'ProbeTests.m').read_text(
    encoding='utf-8', errors='replace')

errors = []

# 1. 取出 C 里的宿主通道行格式串与两个自检状态字面量
fmt_match = re.search(r'stringWithFormat:@"(%@；调用 %u[^"]*)"', impl)
if not fmt_match:
    print('找不到宿主通道行格式串')
    sys.exit(1)
fmt = fmt_match.group(1)
print(f'C 报告格式串：{fmt}')

state_match = re.search(r'selfChecked \? @"([^"]*)" : @"([^"]*)"', impl)
if not state_match:
    errors.append('找不到自检状态字面量')
else:
    state_ok, state_bad = state_match.group(1), state_match.group(2)
    print(f'自检状态字面量：命中="{state_ok}"  未命中="{state_bad}"')
    # ProbeTests 用 hasPrefix:@"自检命中" 判定 selfChecked
    prefix = re.search(r'value\.selfChecked = \[text hasPrefix:@"([^"]*)"\]', tests)
    if not prefix:
        errors.append('ParseHostRow 里找不到 hasPrefix 判据')
    elif prefix.group(1) != state_ok:
        errors.append(f'hasPrefix 判据 "{prefix.group(1)}" 与 C 侧 "{state_ok}" 不一致')

# 2. 取出 ParseHostRow 的标签数组（含开头单独扫描的「调用 」）
labels = re.findall(r'"(调用 )"|"([^"]*)"(\s*,)?', tests)
label_array = re.search(r'const char \*labels\[\] = \{([^}]*)\}', tests, re.S)
if not label_array:
    errors.append('找不到 ParseHostRow 的 labels 数组')
else:
    parsed_labels = ['调用 '] + re.findall(r'"([^"]*)"', label_array.group(1))
    print(f'ParseHostRow 标签（按扫描顺序）：{parsed_labels}')

    # 3. 模拟生成两种状态下的报告行，逐一按标签顺序扫描
    # C 格式串里的 %@ 与 %u 依次对应：状态、calls、target、targetSame、targetDiff、scoped、outside
    samples = {
        '自检命中': (state_ok, 7, 3, 2, 1, 1, 4),
        '自检未命中': (state_bad, 0, 0, 0, 0, 0, 0),
        '大数值': (state_ok, 1234, 567, 89, 101, 11, 22),
    }
    for name, values in samples.items():
        # 复刻 [NSString stringWithFormat:] 的替换顺序
        out = fmt
        for value in values:
            out = out.replace('%@', str(value), 1) if '%@' in out else out.replace('%u', str(value), 1)
        # ParseHostRow 等价实现：每个标签用「首次出现位置」定位，再取紧随的数字
        cursor_values = []
        text = out
        for label in parsed_labels:
            index = text.find(label)
            if index < 0:
                errors.append(f'{name}：标签 "{label}" 在报告行中不存在 → {out}')
                break
            tail = text[index + len(label):]
            m = re.match(r'\s*(-?\d+)', tail)
            if not m:
                errors.append(f'{name}：标签 "{label}" 后无法解析数字 → {out}')
                break
            cursor_values.append(int(m.group(1)))
        else:
            expected = list(values[1:])
            if cursor_values != expected:
                errors.append(f'{name}：解析 {cursor_values} != 期望 {expected}')
            else:
                print(f'  [{name}] 解析成功 → calls={cursor_values[0]} target={cursor_values[1]} '
                      f'same={cursor_values[2]} diff={cursor_values[3]} scoped={cursor_values[4]} '
                      f'outside={cursor_values[5]}')
        # hasPrefix 判据必须只在真正命中时为真
        should_check = name == '自检命中' or name == '大数值'
        if out.startswith(state_ok) != should_check:
            errors.append(f'{name}：hasPrefix 判定与期望不符')

# 4. 阶段行的标签也必须可解析（CheckHostChannelTrace 用「目标命中 」定位）
stage_fmt = re.search(r'@"(目标命中 %u；目录内 %u；目录外 %u)"', impl)
if not stage_fmt:
    errors.append('找不到阶段宿主通道行格式串')
else:
    print(f'C 阶段行格式串：{stage_fmt.group(1)}')
    stage_label = re.search(r'\[hostEndRow rangeOfString:@"([^"]*)"\]', tests)
    if not stage_label or stage_label.group(1) not in stage_fmt.group(1):
        errors.append(f'阶段行定位标签 {stage_label.group(1) if stage_label else None} 与格式串不一致')
    else:
        print(f'  阶段行定位标签 "{stage_label.group(1)}" 存在于格式串中')

print()
if errors:
    print('报告行解析模拟：发现问题')
    for item in errors:
        print('  ✗', item)
    sys.exit(1)
print('报告行解析模拟：全部通过（格式串、状态字面量、5+1 个标签、阶段行逐字对齐）')
