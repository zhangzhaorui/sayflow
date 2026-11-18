#!/bin/bash
# 双击运行：编译 → 单元测试 → 打包 DMG → 安全自查。全部输出保存在 build/build.log
cd "$(dirname "$0")" || exit 1
mkdir -p build
{
  echo "==== $(date '+%Y-%m-%d %H:%M:%S') 开始 ===="
  ./scripts/build.sh && BUILD_OK=1 || BUILD_OK=0
  if [ "$BUILD_OK" = "1" ]; then
    echo; echo "==> 单元检查"
    swift run -c release --arch arm64 SayFlowCoreChecks 2>&1 | tail -30
    echo; ./scripts/selfcheck.sh || true
    echo "BUILD_RESULT=OK"
  else
    echo "BUILD_RESULT=FAILED"
  fi
} 2>&1 | tee build/build.log
echo
echo "日志已保存到 build/build.log，可以关掉这个窗口了。"
