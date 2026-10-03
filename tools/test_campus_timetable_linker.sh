#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=build/ios-timetable-host/linker-test
mkdir -p "$output"
cat > "$output/entry.c" <<'C'
extern int retainedFactory(void);
int CampusOriginalProbeMain(void) { return retainedFactory(); }
const char *CampusTimetableHostVersion = "xhu-campus-timetable-host:1";
C
cat > "$output/cache.c" <<'C'
extern int campus_link_test_unavailable_api(void);
int unusedPlatformWrapper(void) { return campus_link_test_unavailable_api(); }
int retainedFactory(void) { return 7; }
C
cat > "$output/caller.c" <<'C'
extern int CampusOriginalProbeMain(void);
int main(void) { return CampusOriginalProbeMain() == 7 ? 0 : 1; }
C
xcrun --sdk macosx clang -c "$output/entry.c" -o "$output/entry.o"
xcrun --sdk macosx clang -c "$output/cache.c" -o "$output/cache.o"
xcrun ar rcs "$output/cache.a" "$output/cache.o"
# 动态库默认导出会保留未调用的包装器，复现本次构建失败的链接关系。
if xcrun --sdk macosx clang -dynamiclib "$output/entry.o" "$output/cache.a" \
    -Wl,-all_load,-dead_strip -o "$output/unrestricted.dylib" 2> "$output/unrestricted.log"; then
  echo '回归前提不成立：未限制导出时应报告缺失的测试 API。' >&2
  exit 1
fi
grep -q 'campus_link_test_unavailable_api' "$output/unrestricted.log"
# 使用生产的导出清单。真正的启动工厂仍被调用，未调用包装器应被剔除。
xcrun --sdk macosx clang -dynamiclib "$output/entry.o" "$output/cache.a" \
  -Wl,-all_load,-dead_strip -Wl,-exported_symbols_list,tools/ios-timetable-host/exports.list \
  -Wl,-install_name,"$PWD/$output/restricted.dylib" -o "$output/restricted.dylib"
xcrun nm -u "$output/restricted.dylib" > "$output/imports.txt"
if grep -q 'campus_link_test_unavailable_api' "$output/imports.txt"; then
  echo '未使用的测试 API 仍被保留。' >&2
  exit 1
fi
xcrun --sdk macosx clang "$output/caller.c" "$output/restricted.dylib" -o "$output/caller"
"$output/caller"
# 缺失 API 一旦成为真实调用依赖，必须失败，不能把问题推迟到应用启动。
cat > "$output/required.c" <<'C'
extern int campus_link_test_unavailable_api(void);
int retainedFactory(void) { return campus_link_test_unavailable_api(); }
C
xcrun --sdk macosx clang -c "$output/required.c" -o "$output/required.o"
if xcrun --sdk macosx clang -dynamiclib "$output/entry.o" "$output/required.o" \
    -Wl,-dead_strip -Wl,-exported_symbols_list,tools/ios-timetable-host/exports.list \
    -o "$output/required.dylib" 2> "$output/required.log"; then
  echo '真实调用依赖缺失时错误地链接成功。' >&2
  exit 1
fi
grep -q 'campus_link_test_unavailable_api' "$output/required.log"
echo '链接回归通过：剔除未使用包装器、保留启动工厂、拒绝缺失的真实依赖。'
