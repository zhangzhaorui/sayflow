#!/bin/bash
# 安全自查：在打包好的 App 上执行检查命令，原始输出和逐项判断一起保存到 build/selfcheck.txt
# 用法：./scripts/selfcheck.sh [App 路径，默认 build/SayFlow.app]

set -u
cd "$(dirname "$0")/.." || exit 1

APP="${1:-build/SayFlow.app}"
BIN="$APP/Contents/MacOS/SayFlow"
OUT="build/selfcheck.txt"
CONN="com.sayflow.inputmethod.SayFlow_Connection"
[ -d "$APP" ] || { echo "找不到 ${APP}，请先运行 ./scripts/build.sh"; exit 1; }
mkdir -p build
: > "$OUT"

log() { echo "$*" | tee -a "$OUT"; }
run() {
  log "\$ $*"
  "$@" 2>&1 | tee -a "$OUT"
  log ""
}

log "SayFlow 输入法提交前自查  $(date '+%Y-%m-%d %H:%M:%S')"
log ""
log "########## 原始输出 ##########"
run codesign -dv --verbose=4 "$APP"
run codesign -d --entitlements - "$APP"
run plutil -p "$APP/Contents/Info.plist"
log "\$ find $APP -type f | grep -v rime-data"
find "$APP" -type f | grep -v '/rime-data/' | tee -a "$OUT"
log ""
run otool -L "$BIN"
log "\$ strings $BIN | grep -Eo 'https?://[^\" ]+' | sort -u"
strings "$BIN" | grep -Eo 'https?://[^" ]+' | sort -u | tee -a "$OUT"
log ""

log "########## 逐项判断 ##########"
FAILS=0
pass() { log "PASS  $*"; }
info() { log "INFO  $*"; }
fail() { log "FAIL  $*"; FAILS=$((FAILS + 1)); }

sig="$(codesign -dv --verbose=4 "$APP" 2>&1)"
flags="$(echo "$sig" | grep -Eo 'flags=0x[0-9a-fA-F]+\([^)]*\)' | head -1)"
case "$flags" in *runtime*) pass "已开启 Hardened Runtime（${flags}）" ;; *) fail "没有开启 Hardened Runtime（${flags}）" ;; esac
cdhash="$(echo "$sig" | awk -F= '/^CDHash=/{print $2}' | head -1)"
[ -n "$cdhash" ] && info "CDHash=${cdhash}（本版本的签名指纹，ad-hoc 签名）"

entxml="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
ents="$(echo "$entxml" | grep -Eo 'com\.apple\.security\.[A-Za-z0-9.-]+' | sort -u | tr '\n' ' ')"
expected_ents="com.apple.security.app-sandbox com.apple.security.device.audio-input com.apple.security.network.client com.apple.security.temporary-exception.mach-register.global-name "
[ "$ents" = "$expected_ents" ] && pass "entitlements 只有沙盒、network.client、audio-input、mach-register" || fail "entitlements 异常：$ents"
mach="$(echo "$entxml" | tr -d '\n\t ' | grep -Eo 'mach-register\.global-name</key><array>(<string>[^<]*</string>)*</array>' | grep -Eo '<string>[^<]*</string>' | sed 's/<[^>]*>//g' | tr '\n' ' ')"
[ "$mach" = "$CONN " ] && pass "mach-register 只注册输入法连接名 $CONN" || fail "mach-register 异常：$mach"
echo "$entxml" | tr -d '\n\t ' | grep -q 'app-sandbox</key><true/>' && pass "已开启 App Sandbox" || fail "没有开启 App Sandbox"

plist="$(plutil -p "$APP/Contents/Info.plist")"
bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
case "$bid" in *.inputmethod.*) pass "bundle ID 为输入法格式：$bid" ;; *) fail "bundle ID 不含 .inputmethod.：$bid" ;; esac
conn="$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' "$APP/Contents/Info.plist")"
[ "$conn" = "$CONN" ] && pass "InputMethodConnectionName=$conn" || fail "InputMethodConnectionName 异常：$conn"
usage="$(echo "$plist" | grep -Eo '"NS[A-Za-z]+UsageDescription"' | tr -d '"' | sort -u | tr '\n' ' ')"
[ "$usage" = "NSMicrophoneUsageDescription " ] && pass "用途说明只有 NSMicrophoneUsageDescription" || fail "用途说明异常：$usage"
if echo "$plist" | grep -Eq '"(CFBundleURLTypes|NSAppleScriptEnabled|OSAScriptingDefinition|SUFeedURL|NSServices|XPCService)"'; then
  fail "Info.plist 含 URL scheme / AppleScript / 服务 / 自动更新"
else
  pass "没有 URL scheme、AppleScript、Services、XPC、自动更新"
fi

if find "$APP" -type f \( -name '*.lua' -o -name '*.js' -o -name '*.py' -o -name '*.rb' -o -name '*.sh' -o -name '*.dylib' -o -name '*.so' \) | grep -q .; then
  fail "发现脚本或动态库"
else
  pass "没有脚本文件和动态库"
fi
[ -d "$APP/Contents/Frameworks" ] && fail "存在 Frameworks 目录" || pass "没有 Frameworks 目录"
[ -d "$APP/Contents/XPCServices" ] && fail "存在 XPCServices 目录" || pass "没有 XPC 服务"
[ -d "$APP/Contents/PlugIns" ] && fail "存在 PlugIns 目录" || pass "没有 PlugIns 目录"

libs="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
bad_libs="$(echo "$libs" | grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
[ -z "$bad_libs" ] && pass "只链接 /System/Library/ 和 /usr/lib/ 下的系统库（librime 静态编入）" || fail "链接了非系统库：$bad_libs"

urls="$(strings "$BIN" | grep -Eo 'https?://[^" ]+' | sort -u)"
bad_urls="$(echo "$urls" | grep -v '^https://api\.example\.com' | grep -v '^$' || true)"
[ -z "$bad_urls" ] && pass "程序里没有硬编码的外部网址" || info "程序里出现网址字符串（多为开源库注释或许可证，请逐条确认，程序不会访问）：$(echo $bad_urls)"

if strings "$BIN" | grep -Eq 'luaL_newstate|lua_pcall|JSContext|PyRun_'; then fail "发现脚本引擎符号"; else pass "没有 Lua / JavaScript / Python 脚本引擎"; fi
if nm -u "$BIN" 2>/dev/null | grep -Eq '_(system|popen|posix_spawn|execv|execvp|NSTask)$'; then
  fail "发现启动外部命令的调用：$(nm -u "$BIN" | grep -E '_(system|popen|posix_spawn|execv|execvp)$' | tr '\n' ' ')"
else
  pass "没有 system / popen / posix_spawn / exec 调用"
fi
if [ -d "$APP/Contents/Resources/rime-data" ]; then
  info "词库目录：$(du -sh "$APP/Contents/Resources/rime-data" | cut -f1)，$(find "$APP/Contents/Resources/rime-data" -type f | wc -l | tr -d ' ') 个文件"
  lua_files=""
  for f in "$APP"/Contents/Resources/rime-data/*.yaml "$APP"/Contents/Resources/rime-data/build/*.yaml; do
    [ -f "$f" ] || continue
    # 去掉 # 后面的注释再检查
    if sed 's/#.*$//' "$f" | grep -qE 'lua_(translator|filter|processor|segmentor)'; then lua_files="$lua_files $(basename "$f")"; fi
  done
  if [ -n "$lua_files" ]; then
    fail "方案里还有 lua 组件：$lua_files"
  else
    pass "方案里没有 lua 组件（注释除外）"
  fi
else
  info "这个版本没有放入 Rime 词库（英文直通版）"
fi

log ""
log "结果：$FAILS 项不通过"
echo
echo "已保存到 $OUT"
[ "$FAILS" -eq 0 ]
