#!/bin/bash
# 双击运行：安装编译工具 → 编译 librime 引擎 → 准备词库 → 重新打包 SayFlow
# 安全团队已确认《开源组件清单》（2026-11-17）。全部输出保存在 build/rime.log
cd "$(dirname "$0")" || exit 1
mkdir -p build
{
  echo "==== $(date '+%Y-%m-%d %H:%M:%S') 开始 ===="
  set -e
  command -v brew >/dev/null || { echo "缺少 Homebrew"; exit 1; }
  echo "==> 安装 cmake、boost"
  brew list cmake >/dev/null 2>&1 || brew install cmake
  brew list boost >/dev/null 2>&1 || brew install boost
  export SAYFLOW_RIME_APPROVED=yes
  if [ -f vendor/rime/lib/librime.a ] && [ -f vendor/rime/include/rime_api.h ]; then
    echo "==> librime 已编译过，跳过（要重编就删掉 vendor/rime）"
  else
    ./scripts/build-librime.sh
  fi
  ./scripts/prepare-rime-data.sh
  ./scripts/build.sh
  ./scripts/selfcheck.sh || true
  echo "==== 验证：用和输入法一样的 Swift 方式打字 ===="
  swift build -c release --arch arm64 --product RimeProbe 2>&1 | grep -E "error|Build complete" | tail -2
  PR="$(swift build -c release --arch arm64 --show-bin-path)/RimeProbe"
  rm -rf build/verify; mkdir -p build/verify
  v() { NO_MAINT=1 SCHEMA="$1" INPUTS="$2" "$PR" "$PWD/vendor/rime-data" "$PWD/build/verify" | grep -v "data_size\|variant\|LC_\|跳过部署"; }
  v rime_ice "wo weishenme jintianxiawusandiankaihui wsm"
  v rime_ice_nolearn "weishenme"
  v double_pinyin_flypy "wwufme"
  v wubi86 "wq"
  v wubi86_pinyin "wq weishenme zhong"
  echo "==== 符号键 ===="
  rm -rf build/verify2; mkdir -p build/verify2
  NO_MAINT=1 KEYS='? = - @ # $ % * ( ) , . / ; shift' INPUTS="" "$PR" "$PWD/vendor/rime-data" "$PWD/build/verify2" | grep -v "data_size\|variant\|LC_\|跳过部署"
  echo "RIME_RESULT=OK"
} 2>&1 | tee build/rime.log
grep -q "RIME_RESULT=OK" build/rime.log || echo "RIME_RESULT=FAILED" | tee -a build/rime.log
echo
echo "日志已保存到 build/rime.log，可以关掉这个窗口了。"
