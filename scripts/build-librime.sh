#!/bin/bash
# 编译 librime 静态库（含 octagram、predict 插件），输出到 vendor/rime/{lib,include,bin}
#
# 必须在安全团队书面确认《开源组件清单》之后运行：
#   SAYFLOW_RIME_APPROVED=yes ./scripts/build-librime.sh
#
# 需要：命令行工具、Homebrew 的 cmake 和 boost（brew install cmake boost）。
# 关闭 Rime 日志（ENABLE_LOGGING=OFF），不带 librime-lua，不带外部插件加载。

set -euo pipefail
cd "$(dirname "$0")/.."

[ "${SAYFLOW_RIME_APPROVED:-}" = "yes" ] || { echo "安全团队确认组件清单后，用 SAYFLOW_RIME_APPROVED=yes 运行"; exit 1; }

LIBRIME_TAG="${LIBRIME_TAG:-1.17.0}"
OCTAGRAM_REF="${OCTAGRAM_REF:-master}"
PREDICT_REF="${PREDICT_REF:-master}"
SRC="build/librime-src"
OUT="vendor/rime"

command -v cmake >/dev/null || { echo "缺少 cmake：brew install cmake"; exit 1; }
BOOST_ROOT="${BOOST_ROOT:-$(brew --prefix boost 2>/dev/null || true)}"
[ -n "$BOOST_ROOT" ] && [ -d "$BOOST_ROOT/include/boost" ] || { echo "缺少 boost：brew install boost"; exit 1; }
export BOOST_ROOT

echo "==> 下载源码：librime $LIBRIME_TAG"
rm -rf "$SRC"
git clone --depth 1 --branch "$LIBRIME_TAG" --recurse-submodules --shallow-submodules https://github.com/rime/librime.git "$SRC"
git clone https://github.com/lotem/librime-octagram.git "$SRC/plugins/octagram"
git -C "$SRC/plugins/octagram" checkout "$OCTAGRAM_REF"
git clone https://github.com/rime/librime-predict.git "$SRC/plugins/predict"
git -C "$SRC/plugins/predict" checkout "$PREDICT_REF"

echo "==> 记录版本（写进提交说明）"
mkdir -p "$OUT"
{
  echo "librime $(git -C "$SRC" describe --tags --always) $(git -C "$SRC" rev-parse HEAD)"
  echo "librime-octagram $(git -C "$SRC/plugins/octagram" rev-parse HEAD)"
  echo "librime-predict $(git -C "$SRC/plugins/predict" rev-parse HEAD)"
  git -C "$SRC" submodule status
} | tee "$OUT/VERSIONS.txt"

export MACOSX_DEPLOYMENT_TARGET=13.0
export CMAKE_OSX_ARCHITECTURES=arm64

echo "==> 编译依赖（leveldb、marisa、opencc、yaml-cpp；不编 glog）"
(cd "$SRC" && make -f deps.mk ARCHS=arm64 leveldb marisa-trie opencc yaml-cpp)

echo "==> 编译 librime（静态库，插件合并进 librime.a）"
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_STATIC=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_MERGED_PLUGINS=ON \
  -DENABLE_EXTERNAL_PLUGINS=OFF \
  -DENABLE_LOGGING=OFF \
  -DBUILD_TEST=OFF \
  -DCMAKE_PREFIX_PATH="$PWD/$SRC" \
  -DBoost_ROOT="$BOOST_ROOT"
cmake --build "$SRC/build" --config Release -j "$(sysctl -n hw.ncpu)"

echo "==> 复制到 $OUT"
rm -rf "$OUT/lib" "$OUT/include" "$OUT/bin"
mkdir -p "$OUT/lib" "$OUT/include" "$OUT/bin"
find "$SRC/build" -name 'librime*.a' -exec cp {} "$OUT/lib/" \;
for lib in libleveldb.a libmarisa.a libopencc.a libyaml-cpp.a; do
  found="$(find "$SRC/lib" "$SRC/build" -name "$lib" 2>/dev/null | head -1)"
  [ -n "$found" ] && cp "$found" "$OUT/lib/" || echo "提示：没找到 $lib"
done
cp "$SRC"/src/rime_api*.h "$SRC"/src/rime_levers_api.h "$OUT/include/" 2>/dev/null || cp "$SRC"/src/rime_api*.h "$OUT/include/"
find "$SRC/build" -type f -perm -111 -name 'rime_deployer' -exec cp {} "$OUT/bin/" \;
ls -la "$OUT/lib" "$OUT/bin"
echo "完成。下一步：SAYFLOW_RIME_APPROVED=yes ./scripts/prepare-rime-data.sh"
