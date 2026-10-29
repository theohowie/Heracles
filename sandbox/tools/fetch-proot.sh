#!/usr/bin/env bash
#
# Copyright (C) 2026 Heracles-taixu-sandbox contributors
# SPDX-License-Identifier: GPL-3.0
#
# 获取 / 更新 PRoot 运行时二进制到 sandbox-runtime/src/main/jniLibs/arm64-v8a/
#   libproot.so · libproot-loader.so · libtalloc.so · libandroid-shmem.so
#
# ★ 定位：**可选工具，不是构建前置**
#   本仓库**已经**带齐这 4 个二进制（共约 300 KB），`./gradlew build` 直接可用。
#   只有在你想要「换一个 Termux proot 版本」或「二进制损坏需要重取」时才跑它。
#
#   构建期有强校验（sandbox-runtime/build.gradle.kts 的 preBuild）：
#   这 4 个文件缺失 → 构建**直接失败**，不会产出一个跑不了的 APK。
#
# 用法：
#   bash tools/fetch-proot.sh                 # 默认从 Termux 的 proot 包取
#   bash tools/fetch-proot.sh /path/to/proot  # 用你自己已有的 proot
#
# ⚠️ 只支持 arm64-v8a。32 位（armeabi-v7a）不在支持范围。
#
# ⚠️ 协议义务：PRoot 是 GPL-2.0-or-later（STMicroelectronics / Termux PRoot）。
#    分发其二进制时**必须**同时提供对应源码或书面要约，见 NOTICE 第 5 节。
#    本仓库已包含二进制，因此这条义务适用 —— 不要删除 NOTICE 的相关章节。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$REPO_ROOT/sandbox-runtime/src/main/jniLibs/arm64-v8a"
ASSET_DIR="$REPO_ROOT/sandbox-runtime/src/main/assets/bin"

mkdir -p "$DEST_DIR" "$ASSET_DIR"

if [[ $# -ge 1 ]]; then
  SRC="$1"
  if [[ ! -f "$SRC" ]]; then
    echo "✗ 找不到 $SRC" >&2
    exit 1
  fi
  echo "→ 使用本地 proot: $SRC"
  cp -f "$SRC" "$DEST_DIR/libproot.so"
else
  echo "→ 从 Termux 的 proot 包取（需要网络 + dpkg-deb）"
  echo "  若你的环境没有这些工具，请手动准备 proot 后作为参数传入。"
  echo ""

  command -v curl >/dev/null || { echo "✗ 需要 curl" >&2; exit 1; }
  command -v dpkg-deb >/dev/null || { echo "✗ 需要 dpkg-deb（Debian/Ubuntu: apt install dpkg）" >&2; exit 1; }

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  BASE="https://packages.termux.dev/apt/termux-main"
  echo "  拉 Packages 索引…"
  curl -fsSL "$BASE/dists/stable/main/binary-aarch64/Packages" -o "$TMP/Packages"

  # 取 proot 包路径（最新版本的 Filename 字段）
  PKG_PATH="$(awk '
    /^Package: proot$/   { inpkg=1; next }
    /^Package: /         { inpkg=0 }
    inpkg && /^Filename: / { print $2 }
  ' "$TMP/Packages" | tail -1)"

  if [[ -z "${PKG_PATH:-}" ]]; then
    echo "✗ 索引里没找到 proot 包（Termux 源结构可能变了）" >&2
    exit 1
  fi

  echo "  下载 ${PKG_PATH}…"
  curl -fsSL "$BASE/$PKG_PATH" -o "$TMP/proot.deb"
  dpkg-deb -x "$TMP/proot.deb" "$TMP/root"

  if [[ -f "$TMP/root/data/data/com.termux/files/usr/bin/proot" ]]; then
    cp -f "$TMP/root/data/data/com.termux/files/usr/bin/proot" "$DEST_DIR/libproot.so"
  else
    echo "✗ 解包里没找到 proot 可执行文件" >&2
    find "$TMP/root" -name 'proot*' -type f -exec ls -l {} \;
    exit 1
  fi
  # loader 通常在同一个包里（有的版本叫 proot-loader）
  for cand in proot-loader proot-loader.so; do
    if [[ -f "$TMP/root/data/data/com.termux/files/usr/libexec/$cand" ]]; then
      cp -f "$TMP/root/data/data/com.termux/files/usr/libexec/$cand" "$DEST_DIR/libproot-loader.so"
      break
    fi
  done
fi

# 校验 ELF 形态（AArch64）
if [[ -f "$DEST_DIR/libproot.so" ]]; then
  MAGIC="$(xxd -p -l 4 "$DEST_DIR/libproot.so" 2>/dev/null || od -An -tx1 -N4 "$DEST_DIR/libproot.so" | tr -d ' \n')"
  MACHINE="$(xxd -p -s 18 -l 2 "$DEST_DIR/libproot.so" 2>/dev/null || od -An -tx1 -j18 -N2 "$DEST_DIR/libproot.so" | tr -d ' \n')"
  SIZE="$(stat -c%s "$DEST_DIR/libproot.so" 2>/dev/null || stat -f%z "$DEST_DIR/libproot.so")"

  if [[ "$MAGIC" != "7f454c46" ]]; then
    echo "✗ libproot.so 不是 ELF（magic=$MAGIC）" >&2
    exit 1
  fi
  if [[ "$MACHINE" != "b700" ]]; then
    echo "✗ libproot.so 不是 AArch64（e_machine=$MACHINE，期望 b700）" >&2
    exit 1
  fi
  if [[ "$SIZE" -lt 100000 ]]; then
    echo "✗ libproot.so 太小（$SIZE B），可能下载不完整" >&2
    exit 1
  fi
  echo ""
  echo "✓ libproot.so: $SIZE B, AArch64 ELF"
fi

if [[ -f "$DEST_DIR/libproot-loader.so" ]]; then
  echo "✓ libproot-loader.so: $(stat -c%s "$DEST_DIR/libproot-loader.so" 2>/dev/null || stat -f%z "$DEST_DIR/libproot-loader.so") B"
else
  echo "⚠ 没有 proot-loader.so —— 大多数 Termux proot 版本自带内置 loader，"
  echo "  可先不提供；若真机上报 'PROOT_LOADER not found' 再补。"
fi

echo ""
echo "下一步："
echo "  cd $(basename "$REPO_ROOT") && ./gradlew :sandbox-app:assembleDebug"
echo ""
echo "⚠️ 只支持 arm64-v8a。"
