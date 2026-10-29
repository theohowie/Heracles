#!/usr/bin/env bash
#
# Copyright (C) 2026 Heracles-taixu-sandbox contributors
# SPDX-License-Identifier: GPL-3.0
#
# 获取/更新**内置 rootfs**（sandbox-runtime/src/main/assets/rootfs-bundle.bin）
#
# 说明：仓库里**已经**带了一份 Alpine 3.20 minirootfs（3.8 MB）。
# 这个脚本只在你想要：
#   - 换一个发行版（Debian / Ubuntu / Void…）
#   - 升级 Alpine 版本
#   - 加装额外工具后再打包
# 时才需要跑。正常构建**不需要**它。
#
# 用法：
#   bash tools/fetch-bundled-rootfs.sh                    # 默认 Alpine 3.20（与仓库一致）
#   bash tools/fetch-bundled-rootfs.sh 3.21              # 指定 Alpine 版本
#   bash tools/fetch-bundled-rootfs.sh --from /path/x.tar # 用本地 tar
#   bash tools/fetch-bundled-rootfs.sh --verify           # 只校验现有 asset
#
# ⚠️ 打包约束（BundledRootfs 的解析器要求）：
#   - 格式只能是 **裸 tar 或 tar.gz**（gzip）
#   - **不能** zstd / xz / zip（沙箱不内置这些解码器，会返回 UNSUPPORTED）
#   - tar 里**直接**以 /etc、/bin 开头（不要套一层顶层目录；虽然解析器
#     有 findEffectiveRoot 兼容，但直接以 / 开头最稳）
#
# ⚠️ 关于 AGP 的一个行为（重要）：
#   AGP 的 compressDebugAssets 会把 assets 里的 **.gz 自动解压**，
#   所以运行期读到的往往是 `rootfs-bundle.tar`（纯 tar）。
#   BundledRootfs 的 BUNDLE_ASSET_NAMES 已同时覆盖这两种名字，无需干预。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$REPO_ROOT/sandbox-runtime/src/main/assets"
ASSET="$ASSET_DIR/rootfs-bundle.bin"

ALPINE_VERSION="3.20.3"
MIRROR="https://mirrors.aliyun.com/alpine"
FROM_LOCAL=""
VERIFY_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)   FROM_LOCAL="$2"; shift 2 ;;
    --verify) VERIFY_ONLY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *)        ALPINE_VERSION="$1"; shift ;;
  esac
done

mkdir -p "$ASSET_DIR"

# ---------------------------------------------------------------------------
verify() {
  local f="$1"
  [[ -f "$f" ]] || { echo "✗ 文件不存在：$f" >&2; return 1; }

  local size magic
  size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
  magic="$(od -An -tx1 -N2 "$f" | tr -d ' \n')"

  echo "  文件: $f"
  echo "  大小: $size B ($(( size / 1024 / 1024 )) MB)"
  echo "  magic: $magic"

  if [[ "$size" -lt 500000 ]]; then
    echo "  ✗ 过小（<500 KB），不像一个可用 rootfs" >&2
    return 1
  fi

  if [[ "$f" == *.gz && "$magic" != "1f8b" ]]; then
    echo "  ✗ 扩展名是 .gz 但 magic 不是 gzip（1f 8b）" >&2
    return 1
  fi

  # 必须能列出内容，且含 /bin 或 /etc
  local listing
  if [[ "$f" == *.gz ]]; then
    listing="$(tar -tzf "$f" 2>/dev/null | head -200 || true)"
  else
    listing="$(tar -tf "$f" 2>/dev/null | head -200 || true)"
  fi

  if [[ -z "$listing" ]]; then
    echo "  ✗ 无法用 tar 列出内容（可能损坏或不是 tar）" >&2
    return 1
  fi

  if ! grep -qE '(^\./|^)(bin|etc)/' <<< "$listing"; then
    echo "  ⚠ 前 200 条里没看到 bin/ 或 etc/ —— 检查是否套了顶层目录"
  fi

  echo "  ✓ 校验通过"
  echo "  sha256: $(sha256sum "$f" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$f" | cut -d' ' -f1)"
}

# ---------------------------------------------------------------------------

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  echo "→ 校验现有内置 rootfs"
  verify "$ASSET"
  exit 0
fi

if [[ -n "$FROM_LOCAL" ]]; then
  echo "→ 使用本地 tar：$FROM_LOCAL"
  verify "$FROM_LOCAL"
  cp -f "$FROM_LOCAL" "$ASSET"
else
  URL="$MIRROR/v${ALPINE_VERSION%.*}/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
  echo "→ 下载 Alpine $ALPINE_VERSION"
  echo "  $URL"
  command -v curl >/dev/null || { echo "✗ 需要 curl" >&2; exit 1; }
  curl -fsSL --retry 3 --max-time 300 -o "$ASSET" "$URL"
  verify "$ASSET"
fi

echo ""
echo "✓ 内置 rootfs 已就位：$ASSET"
echo ""
echo "下一步："
echo "  ./gradlew :sandbox-app:assembleDebug"
echo ""
echo "⚠️ 只支持 arm64-v8a；rootfs 必须是 aarch64 构建。"
