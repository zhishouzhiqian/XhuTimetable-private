#!/usr/bin/env python
"""检查 iOS 组件探针的接线一致性（可在 Windows 上运行，不编译 Objective-C）。

本机没有 Xcode/macOS 工具链，无法编译或运行 ProbeTests。这个脚本只做静态一致性
检查，把「改了实现却忘记加进构建脚本/忘记声明」这类错误提前暴露出来：

1. tools/ios-component-probe/*.h 里声明的 CampusProbe* C 函数必须有定义；
2. 每个工具目录里的 .m 文件都必须被 tools/build_campus_ios_probe.sh 编译并链接；
3. 诊断入口必须在头文件、实现、Swift 调用三处同时存在；
4. 正式入口的资源完整性门槛与「不展示路径」的既有约束仍在；
5. 源文件用到的 C 标识符必须有对应的 #include（本机无 Xcode，这是唯一能在
   CI 编译前拦住「用了 DIR 却漏了 <dirent.h>」这类回归的手段）。

用法：python tools/check_campus_probe_wiring.py
退出码 0 表示全部通过，1 表示存在不一致。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools" / "ios-component-probe"
APP = ROOT / "iosApp" / "iosApp"
BUILD_SCRIPT = ROOT / "tools" / "build_campus_ios_probe.sh"

failures = []


def fail(message):
    failures.append(message)


def read(path):
    if not path.is_file():
        fail("缺少文件：{}".format(path.relative_to(ROOT)))
        return ""
    return path.read_text(encoding="utf-8")


def declared_c_functions():
    """头文件里声明的 CampusProbe* C 函数名。"""
    names = set()
    for path in sorted(TOOLS.glob("*.h")):
        text = read(path)
        for match in re.finditer(r"^\s*(?:extern\s+)?[A-Za-z_][\w \*]*?\b(CampusProbe[A-Za-z0-9_]*)\s*\(",
                                text, re.MULTILINE):
            names.add(match.group(1))
    return names


def defined_c_functions(path):
    text = read(path)
    names = set()
    for match in re.finditer(r"^[A-Za-z_][\w \*]*?\b(CampusProbe[A-Za-z0-9_]*)\s*\([^;]*?\)\s*\{",
                            text, re.MULTILINE | re.DOTALL):
        names.add(match.group(1))
    return names


def check_c_functions():
    implementations = set()
    for path in sorted(TOOLS.glob("*.m")):
        implementations |= defined_c_functions(path)
    for name in sorted(declared_c_functions()):
        if name not in implementations:
            fail("头文件声明了 {}，但没有任何实现".format(name))


def check_build_script():
    script = read(BUILD_SCRIPT)
    if not script:
        return
    for path in sorted(TOOLS.glob("*.m")):
        relative = "tools/ios-component-probe/{}".format(path.name)
        if relative not in script:
            fail("构建脚本没有引用 {}".format(relative))
    # 工具目录下的 .m 若提供 CampusProbe* 实现，必须同时出现在测试链接与真机链接里。
    for path in sorted(TOOLS.glob("*.m")):
        if "CampusProbe" not in path.read_text(encoding="utf-8"):
            continue
        if path.name == "ProbeTests.m":
            continue  # 桩测试只链接进 macOS 测试目标，不进真机目标。
        relative = "tools/ios-component-probe/{}".format(path.name)
        if script.count(relative) < 2:
            fail("构建脚本只引用了一次 {}，需要在测试目标和真机目标都编译".format(relative))


def check_diagnostics_entry():
    header = read(APP / "CampusComponentProbe.h")
    implementation = read(APP / "CampusComponentProbe.m")
    swift = read(APP / "LaundryComponentCheckViewController.swift")
    if "runDiagnosticAtResourcePath" not in header:
        fail("头文件缺少诊断入口 runDiagnosticAtResourcePath")
    if "runDiagnosticAtResourcePath" not in implementation:
        fail("实现缺少诊断入口 runDiagnosticAtResourcePath")
    if "diagnosticVariants" not in header or "diagnosticVariants" not in implementation:
        fail("头文件或实现缺少 diagnosticVariants")
    if "runDiagnostic" not in swift or "diagnosticVariants" not in swift:
        fail("检查页没有接线诊断入口或变体列表")
    # 正式入口必须仍然以资源完整性为门槛，诊断入口必须显式绕过。
    if "if (resourcesValid) {" in implementation:
        fail("正式入口的资源完整性门槛已被改回旧写法；诊断入口应使用 resourcesValid || diagnostics")
    if "resourcesValid || diagnostics" not in implementation:
        fail("诊断入口没有绕过资源完整性门槛")
    if "CampusProbeDiagnosticVariants" not in implementation and "CampusProbeDiagnosticTable" not in implementation:
        fail("实现缺少对照变体表")


def check_report_hygiene():
    """报告脱敏约束：报告里不得出现文件系统路径特征，桩测试的脱敏断言必须保留。"""
    path_tokens = ["/Users/", "/var/", "/private/", "/tmp/", "/Library/",
                   "NSHomeDirectory", "fileSystemRepresentation", "NSTemporaryDirectory"]
    for relative in ["iosApp/iosApp/CampusComponentProbe.m",
                     "tools/ios-component-probe/ProbeResourceTrace.m",
                     "tools/ios-component-probe/ProbeContainerSnapshot.m"]:
        text = read(ROOT / relative)
        if not text:
            continue
        for match in re.finditer(r'@"[^"\n]*"', text):
            literal = match.group(0)
            for token in path_tokens:
                if token in literal:
                    line = text[:match.start()].count("\n") + 1
                    fail("{}:{} 报告字符串疑似包含路径特征 {}：{}".format(
                        relative, line, token, literal[:60]))
                    break
    tests = read(TOOLS / "ProbeTests.m")
    for marker in ["containsString:folder", 'containsString:@"private-"']:
        if marker not in tests:
            fail("桩测试缺少报告脱敏断言：{}".format(marker))


def strip_literals(text):
    """去掉字符串字面量与注释，避免括号计数被正文干扰。"""
    out = []
    index = 0
    size = len(text)
    while index < size:
        char = text[index]
        if char == '"':
            index += 1
            while index < size and text[index] != '"':
                index += 2 if text[index] == chr(92) else 1
            index += 1
            out.append('""')
            continue
        if char == "/" and index + 1 < size and text[index + 1] == "/":
            while index < size and text[index] != "\n":
                index += 1
            continue
        if char == "/" and index + 1 < size and text[index + 1] == "*":
            index += 2
            while index + 1 < size and not (text[index] == "*" and text[index + 1] == "/"):
                index += 1
            index += 2
            continue
        out.append(char)
        index += 1
    return "".join(out)


def check_brace_balance():
    """Objective-C 侧缺少编译器，至少保证去字面量后括号成对。"""
    targets = ["iosApp/iosApp/CampusComponentProbe.m",
               "tools/ios-component-probe/ProbeResourceTrace.m",
               "tools/ios-component-probe/ProbeContainerSnapshot.m",
               "tools/ios-component-probe/ProbeTests.m"]
    for relative in targets:
        text = strip_literals(read(ROOT / relative))
        if not text:
            continue
        for opener, closer in [("{", "}"), ("(", ")"), ("[", "]")]:
            delta = text.count(opener) - text.count(closer)
            if delta != 0:
                fail("{} 括号不平衡：{} 与 {} 相差 {}".format(relative, opener, closer, delta))


def check_header_dependencies():
    """C/ObjC 源文件的标识符依赖必须来自已 include 的头。

    这是 bc59d50 在 CI 上编译失败的直接教训：重写 ProbeResourceTrace.m 时丢掉了
    #include <dirent.h>，导致 DIR/opendir/closedir 全部未声明。本机无 Xcode，
    这类错误只能靠文本级审计在编译前拦住。只维护实际用到的最小映射表，
    宁可漏报也不误报（误报会阻塞 CI）。
    """
    # 标识符 -> 必须存在的 include（满足其一即可）。
    required = [
        (r'\bDIR\s*\*|\bopendir\s*\(|\bclosedir\s*\(|\breaddir\s*\(', '<dirent.h>'),
        (r'\bpthread_mutex_lock\s*\(|\bpthread_once\s*\(', '<pthread.h>'),
        (r'\bdlsym\s*\(|\bRTLD_NEXT\b', '<dlfcn.h>'),
        (r'\bva_start\s*\(|\bva_arg\s*\(', '<stdarg.h>'),
        (r'\berrno\b', '<errno.h>'),
        (r'\bCC_SHA256\s*\(', '<CommonCrypto/CommonDigest.h>'),
        (r'\bIMP\b|\bclass_getInstanceMethod\s*\(|\bmethod_setImplementation\s*\(', '<objc/runtime.h>'),
        (r'\bO_RDONLY\b|\bO_CREAT\b', '<fcntl.h>'),
        (r'\bstruct stat\b|\bfstat\s*\(|\bstat\s*\(', '<sys/stat.h>'),
        (r'\bfopen\s*\(|\bsnprintf\s*\(|\bfileno\s*\(', '<stdio.h>'),
        (r'\bmemcmp\s*\(|\bstrlen\s*\(|\bmemset\s*\(|\bstrcmp\s*\(', '<string.h>'),
        (r'\bmalloc\s*\(|\bfree\s*\(', '<stdlib.h>'),
        (r'\bclose\s*\(|\blseek\s*\(|\baccess\s*\(|\bunlink\s*\(|\bgetpid\s*\(', '<unistd.h>'),
    ]
    for path in sorted(TOOLS.glob('*.m')) + sorted(APP.glob('*.m')):
        text = read(path)
        # 去掉字符串字面量与注释，避免把文案里的词当成标识符使用。
        text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
        text = re.sub(r'//[^\n]*', ' ', text)
        text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
        included = set(re.findall(r'#\s*(?:include|import)\s*[<"]([^>"]+)[>"]', text))
        for pattern, header in required:
            if re.search(pattern, text):
                name = header.strip('<>')
                # 允许包含更具体的子路径（例如 CommonCrypto/CommonDigest.h）。
                if not any(item == name or item.endswith('/' + name) for item in included):
                    fail('{} 使用了 {} 相关标识符但未 include {}'.format(
                        path.name, name, header))


def check_host_channels():
    """宿主通道观察的接线：选项、拦截入口、诊断启用、自检标注四处必须同时存在。"""
    header = read(TOOLS / "ProbeResourceTrace.h")
    implementation = read(TOOLS / "ProbeResourceTrace.m")
    probe = read(APP / "CampusComponentProbe.m")
    if "CampusProbeTraceOptionsHostChannels" not in header:
        fail("ProbeResourceTrace.h 缺少 CampusProbeTraceOptionsHostChannels 选项")
    # 类方法只覆盖 +dataWithContentsOfFile: 一类；字节码可经 objc_msgSend 直接调用
    # 实例 init 族绕过类方法，故两者都必须拦截（上一轮真机零命中的直接教训）。
    for marker in ["ProbeInstallHostInterceptors",
                   "@selector(dataWithContentsOfFile:)",
                   "@selector(initWithContentsOfFile:)",
                   "@selector(dataWithContentsOfURL:)",
                   "@selector(initWithContentsOfURL:)",
                   "stringWithContentsOfFile:encoding:error:",
                   "initWithContentsOfFile:encoding:error:",
                   "contentsAtPath:",
                   "fileExistsAtPath:isDirectory:",
                   "contentsOfDirectoryAtPath:error:",
                   "fileHandleForReadingAtPath:",
                   "pathForResource:ofType:",
                   "bundleWithURL:",
                   "int access(const char *path, int mode)",
                   "DIR *opendir(const char *path)",
                   "int stat(const char *restrict path, struct stat *restrict sb)",
                   "int lstat(const char *restrict path, struct stat *restrict sb)",
                   "off_t lseek(int fd, off_t offset, int whence)",
                   "int fstat(int fd, struct stat *sb)",
                   "int close(int fd)",
                   "F_GETPATH"]:
        if marker not in implementation:
            fail("ProbeResourceTrace.m 缺少宿主通道入口：{}".format(marker))
    # dlsym 必须取与定义同代的 stat 符号：x86_64 上混用 _stat 与 _stat$INODE64
    # 会因 struct stat 布局不同读到垃圾值。
    if 'PROBE_STAT_SYMBOL' not in implementation or \
            '"stat$INODE64"' not in implementation:
        fail("ProbeResourceTrace.m 缺少 stat 的 $INODE64 同代符号处理")
    # 三个 stat 系定义必须存在，且不得带 __DARWIN_INODE64 标签：真机是 arm64（IR 已核对
    # 为纯 _stat），该宏在 arm64 上展开为空、加了纯属多余，且实测会让 clang 在定义处
    # 报 “expected ';' after top level declarator”。
    for definition in ["int stat(const char *restrict path, struct stat *restrict sb) {",
                       "int lstat(const char *restrict path, struct stat *restrict sb) {",
                       "int fstat(int fd, struct stat *sb) {"]:
        if definition not in implementation:
            fail("ProbeResourceTrace.m 缺少定义：{}".format(definition))
    if "PROBE_INODE64(" in implementation:
        fail("stat 系定义不得带 PROBE_INODE64 标签（arm64 上多余且导致编译失败）")
    if "CampusProbeTraceOptionsHostChannels" not in probe:
        fail("诊断入口没有启用宿主通道观察")
    # 自检判据必须同时接受 target 与 scoped：opendir/目录枚举只能命中 scoped，
    # 只看 target 会让目录类通道永久显示“自检未命中”，把可信结果误报成不可信。
    if "record->calls > 0 && (record->target > 0 || record->scoped > 0)" not in implementation:
        fail("宿主通道自检判据缺失：目录类通道只命中 scoped，不得只看 target")
    if "selfChecked" not in implementation:
        fail("宿主通道必须逐条标注自检命中，否则零命中无法解释")
    # 宿主通道不得参与窗口否决：任一通道的平台差异都不应作废整轮真机运行。
    host_block = implementation[implementation.index("if (hostChannels) {",
        implementation.index("BOOL valid =")):]
    if "valid = valid && record->selfChecked" in host_block:
        fail("宿主通道自检不得否决窗口有效性")
    # 每个被安装的 selector 都必须在自检块里被真实调用一次。
    # 这条断言防的是一类静默失败：selector 拼错时 ProbeInstallInterceptor 会返回 NO，
    # 进而 ProbeInstallHostInterceptors 返回 NO、整个窗口判无效——真机一轮直接作废，
    # 且报告只会说“拦截安装失败”，看不出是哪个 selector 拼错了。只要自检块调用了它，
    # 拼错的 selector 会在编译期就报错（本轮 fileHandleForReadingAtPath:error: 正是
    # 这样被拦下的），把运行期静默失败前移成编译期硬错误。
    installed = re.findall(r'ProbeInstallInterceptor\([^;]*?@selector\(([^)]*)\)', implementation)
    if not installed:
        fail("ProbeResourceTrace.m 没有安装任何拦截器")
    self_check_start = implementation.find("// 宿主通道同样需要自检")
    if self_check_start < 0:
        fail("找不到宿主通道自检块，无法核对 selector 是否被触发")
    else:
        self_check_block = implementation[self_check_start:]

        def selector_called(selector):
            """自检块里是否按顺序出现了该 selector 的每一段（形如 name:）。

            不用 [obj a:b:] 的整体正则：实例方法常写成 [[NSData alloc] init...]，
            嵌套方括号会让「不允许跨越方括号」的模式失配，造成误报。
            按段顺序查找足够严格，且不会因括号嵌套而漏判。
            """
            position = 0
            for part in selector.split(':'):
                if not part:
                    continue
                index = self_check_block.find(part + ':', position)
                if index < 0:
                    return False
                position = index + len(part) + 1
            return True

        for selector in installed:
            if not selector_called(selector):
                fail("已安装的 selector {} 未在自检块中被调用（拼错会导致窗口静默失效）".format(selector))
    tests = read(TOOLS / "ProbeTests.m")
    if "CheckHostChannelTrace" not in tests:
        fail("桩测试缺少宿主通道场景 CheckHostChannelTrace")
    # 上一轮真机零命中的盲区通道必须各自有断言，防止只测旧通道就通过。
    for case in ["NSDataInit", "NSStringInit", "opendir", "stat", "fd"]:
        if '"{}"'.format(case) not in tests:
            fail("桩测试缺少宿主通道场景断言：{}".format(case))


def main():
    check_c_functions()
    check_build_script()
    check_diagnostics_entry()
    check_host_channels()
    check_header_dependencies()
    check_report_hygiene()
    check_brace_balance()
    if failures:
        print("接线检查未通过（{} 项）：".format(len(failures)))
        for item in failures:
            print("  - {}".format(item))
        return 1
    print("静态接线检查通过；不代表 Objective-C/Swift 编译、原生测试或完整报告脱敏验证通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
