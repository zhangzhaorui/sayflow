#!/bin/bash
# 准备词库和方案，输出到 vendor/rime-data（打包时放进 App 包，签名后只读）：
#   雾凇拼音（全拼、小鹤 / 自然码 / 微软双拼）、五笔 86、语言模型（octagram）、预测词库（predict）
# 去掉方案里所有 lua 组件，并用 rime_deployer 预先编译，同事电脑上不需要再生成。
#
# 必须在安全团队书面确认《开源组件清单》之后运行：
#   SAYFLOW_RIME_APPROVED=yes ./scripts/prepare-rime-data.sh

set -euo pipefail
cd "$(dirname "$0")/.."
[ "${SAYFLOW_RIME_APPROVED:-}" = "yes" ] || { echo "安全团队确认组件清单后，用 SAYFLOW_RIME_APPROVED=yes 运行"; exit 1; }
[ -f vendor/rime/lib/librime.a ] || { echo "请先运行 scripts/build-librime.sh"; exit 1; }

echo "==> 编译预编译工具 rime_prebuild（只在本机用，不进 App）"
mkdir -p build
LIBS=""
for lib in vendor/rime/lib/lib*.a; do
  name="$(basename "$lib" .a)"; name="${name#lib}"
  [ "$name" = "rime" ] && continue
  LIBS="$LIBS -l$name"
done
clang -c scripts/rime_prebuild.c -Ivendor/rime/include -o build/rime_prebuild.o
clang++ build/rime_prebuild.o -Lvendor/rime/lib \
  -Wl,-force_load,vendor/rime/lib/librime.a $LIBS -framework CoreFoundation -o build/rime_prebuild

RIME_ICE_TAG="${RIME_ICE_TAG:-2026.06.30}"
GRAM_URL="${GRAM_URL:-https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram}"
PREDICT_DB_URL="${PREDICT_DB_URL:-}"
WORK="build/rime-data-src"
OUT="vendor/rime-data"

# 已下载过的源码和模型直接复用（删掉 build/rime-data-src 可强制重新下载）
rm -rf "$OUT"
mkdir -p "$WORK" "$OUT"

if [ -d "$WORK/rime-ice/.git" ]; then
  echo "==> 雾凇拼音已下载，跳过"
else
  echo "==> 下载雾凇拼音 $RIME_ICE_TAG"
  git clone --depth 1 --branch "$RIME_ICE_TAG" https://github.com/iDvel/rime-ice.git "$WORK/rime-ice"
fi
if [ -d "$WORK/rime-wubi/.git" ]; then
  echo "==> 五笔 86 已下载，跳过"
else
  echo "==> 下载五笔 86"
  git clone --depth 1 https://github.com/rime/rime-wubi.git "$WORK/rime-wubi"
fi
if [ -s "$WORK/wanxiang-lts-zh-hans.gram" ]; then
  echo "==> 语言模型已下载，跳过"
else
  echo "==> 下载语言模型"
  curl -fL --proto '=https' -sS -o "$WORK/wanxiang-lts-zh-hans.gram" "$GRAM_URL"
fi
if [ -n "$PREDICT_DB_URL" ] && [ ! -s "$WORK/predict.db" ]; then
  curl -fL --proto '=https' -sS -o "$WORK/predict.db" "$PREDICT_DB_URL"
fi

{
  echo "rime-ice $RIME_ICE_TAG $(git -C "$WORK/rime-ice" rev-parse HEAD)"
  echo "rime-wubi $(git -C "$WORK/rime-wubi" rev-parse HEAD)"
  echo "gram $(shasum -a 256 "$WORK/wanxiang-lts-zh-hans.gram")"
  if [ -f "$WORK/predict.db" ]; then echo "predict.db $(shasum -a 256 "$WORK/predict.db")"; fi
  true
} | tee "$OUT/VERSIONS.txt"

echo "==> 复制需要的文件（不复制 lua 目录）"
ICE="$WORK/rime-ice"
cp "$ICE"/default.yaml "$ICE"/symbols_v.yaml "$ICE"/symbols_caps_v.yaml "$OUT/" 2>/dev/null || true
cp "$ICE"/rime_ice.schema.yaml "$ICE"/rime_ice.dict.yaml "$ICE"/melt_eng.schema.yaml "$ICE"/melt_eng.dict.yaml "$ICE"/radical_pinyin.schema.yaml "$ICE"/radical_pinyin.dict.yaml "$OUT/" 2>/dev/null || true
cp "$ICE"/double_pinyin.schema.yaml "$ICE"/double_pinyin_flypy.schema.yaml "$ICE"/double_pinyin_mspy.schema.yaml "$OUT/"
cp -R "$ICE/cn_dicts" "$ICE/en_dicts" "$OUT/"
if [ -d "$ICE/opencc" ]; then cp -R "$ICE/opencc" "$OUT/"; fi
cp "$WORK"/rime-wubi/wubi86.schema.yaml "$WORK"/rime-wubi/wubi86.dict.yaml "$OUT/"
cp "$WORK/wanxiang-lts-zh-hans.gram" "$OUT/"
if [ -f "$WORK/predict.db" ]; then cp "$WORK/predict.db" "$OUT/"; fi

echo "==> 去掉 lua 组件，加上语言模型和预测（scripts/patch_schemas.py）"
python3 -I scripts/patch_schemas.py "$OUT"

echo "==> 预先编译"
PREBUILD_USER="build/rime-prebuild-user"
rm -rf "$PREBUILD_USER" && mkdir -p "$PREBUILD_USER" "$OUT/build"
build/rime_prebuild "$OUT" "$PREBUILD_USER" "$OUT/build"
rm -rf "$PREBUILD_USER"
rm -f "$OUT"/user.yaml "$OUT"/installation.yaml "$OUT"/build/user.yaml
du -sh "$OUT"
echo "完成。重新运行 ./scripts/build.sh 即可编出完整打字版。"
