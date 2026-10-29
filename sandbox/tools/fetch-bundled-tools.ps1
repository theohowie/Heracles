# Copyright (C) 2026 Heracles-taixu-sandbox contributors
# SPDX-License-Identifier: GPL-3.0
#
# 把 **T1 工具**（aapt2 / aidl / zipalign，linux-aarch64）内置进 APK 的 assets。
#
# ============================================================================
# 为什么内置 T1、不内置 T2
# ============================================================================
# 产品定调（2026-10-28 用户裁定）：
#   · T0 rootfs（3.77 MB）+ T1 工具（≈5 MB APK 增量）→ **内置**，装完就能用
#   · T2 JDK 17 + Gradle + android.jar（≈440 MB）→ **用户激活时下载**
#
# 判据是「用得多不多」：
#   · aapt2 解析 APK（dump badging / 改资源）是高频操作 → 值得内置
#   · 「从源码编译 APK」是低频重活 → 值得下载
#   · android.jar 只在 `aapt2 link`（生成资源）时需要，比 JDK 用得少 → 跟 T2 一起下
#
# ============================================================================
# 为什么要压缩态入库
# ============================================================================
# assets 在 APK 里本来就是 deflate 压缩的，首次初始化时解压到 rootfs/opt/as。
# ⚠️ 但 **不要**把资产命名成 `*.tar.gz`：AGP 见到该后缀会自动解压成 `.tar`
#    再打进 APK（rootfs 就吃过这个亏，8.69 MB vs 3.77 MB）。
#    ⇒ 本脚本产出的是**未压缩的目录树**（assets 里由 AGP 统一压缩），
#      或者单个 `.bin` 压缩包。这里用「目录树」—— 解压逻辑最简单，
#      AGP 会对每个文件独立压缩，效果与整包压缩接近。
#
# ============================================================================
# 用法
# ============================================================================
#   pwsh -File tools/fetch-bundled-tools.ps1
#   pwsh -File tools/fetch-bundled-tools.ps1 -VerifyOnly   # 只校验已有资产

param(
    [string]$SandboxRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch]$VerifyOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# android-sdk-tools-static-aarch64：aapt2 / aidl / zipalign 的 **linux-aarch64 静态**构建
# （不是 Termux 的 bionic 版 —— 那种在 PRoot 里跑不了，见 porting-log Phase 7）
$Url = 'https://github.com/lzhiyong/android-sdk-tools/releases/download/35.0.2/android-sdk-tools-static-aarch64.zip'
$Sha256 = 'db1cea2c4454d5f9c5a802646b2d1cf560b4ee7badbe23e51ab8e1881bb50fc2'

$AssetDir = Join-Path $SandboxRoot 'sandbox-runtime\src\main\assets\tooltools'
$WorkDir = Join-Path $SandboxRoot 'tools\.tooltools-work'

function Write-Step([string]$t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "    OK   $t" -ForegroundColor Green }
function Write-Info([string]$t) { Write-Host "    ·    $t" }
function Write-Bad([string]$t) { Write-Host "    FAIL $t" -ForegroundColor Red }

# ============================================================================
Write-Step "校验已有资产"
# ============================================================================
$expectBinaries = @('aapt2', 'aidl', 'zipalign')
$missing = @()
foreach ($b in $expectBinaries) {
    $p = Join-Path $AssetDir $b
    if (Test-Path $p) {
        $len = (Get-Item $p).Length
        if ($len -gt 10000) {
            Write-Info ("{0,-10} {1,10:N0} B" -f $b, $len)
        } else {
            $missing += "$b（体积异常：$len B）"
        }
    } else {
        $missing += $b
    }
}

if ($missing.Count -eq 0) {
    Write-Ok "T1 工具已就位（$AssetDir）"
    if ($VerifyOnly) { exit 0 }
} elseif ($VerifyOnly) {
    Write-Bad ("缺少：" + ($missing -join ', '))
    exit 1
} else {
    Write-Info ("需要抓取（缺：" + ($missing -join ', ') + "）")
}

# ============================================================================
Write-Step "下载 android-sdk-tools-static-aarch64"
# ============================================================================
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$zip = Join-Path $WorkDir 'android-sdk-tools-static-aarch64.zip'

if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 1MB) {
    Write-Info "已有下载缓存，跳过"
} else {
    Write-Info $Url
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    curl.exe -sSL --ssl-no-revoke --retry 3 --retry-delay 2 --max-time 1200 -o $zip $Url 2>&1 | Out-Null
    $sw.Stop()
    if (-not (Test-Path $zip)) { Write-Bad "下载失败"; exit 1 }
    Write-Ok ("{0:N2} MB / {1:N1}s" -f ((Get-Item $zip).Length / 1MB), $sw.Elapsed.TotalSeconds)
}

# ============================================================================
Write-Step "校验 sha256"
# ============================================================================
$actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $Sha256) {
    Write-Bad "sha256 不匹配"
    Write-Info ("  期望 " + $Sha256)
    Write-Info ("  实际 " + $actual)
    Remove-Item $zip -Force
    Write-Info "已删除坏包，请重跑"
    exit 1
}
Write-Ok ("sha256 " + $actual.Substring(0, 16) + "…")

# ============================================================================
Write-Step "解压到 assets/tooltools"
# ============================================================================
$extract = Join-Path $WorkDir 'extract'
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $extract | Out-Null
Expand-Archive -Path $zip -DestinationPath $extract -Force

# 该发布包的顶层是 `android-sdk-tools/`（或 build-tools/），递归找目标二进制
$found = @{}
foreach ($b in $expectBinaries) {
    $hit = Get-ChildItem $extract -Recurse -File -Filter $b -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $found[$b] = $hit.FullName } else { Write-Bad "压缩包里没有 $b" }
}
if ($found.Count -lt $expectBinaries.Count) { exit 1 }

Remove-Item $AssetDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $AssetDir | Out-Null
foreach ($b in $found.Keys) {
    Copy-Item $found[$b] (Join-Path $AssetDir $b) -Force
    Write-Info ("{0,-10} {1,10:N0} B" -f $b, (Get-Item $found[$b]).Length)
}

# ============================================================================
Write-Step "校验 ABI（必须是 linux-aarch64，不能是 bionic）"
# ============================================================================
# 与 porting-log Phase 7 同一条铁律：
#   bionic 二进制（解释器 /system/bin/linker64）在 PRoot 里 execve 会 ENOENT，
#   而且只能在宿主进程跑 —— 装进 rootfs 等于白装。
$bad = @()
foreach ($b in $expectBinaries) {
    $p = Join-Path $AssetDir $b
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(8192, $bytes.Length))
    if ($head.Contains('/system/bin/linker64') -or $head.Contains('/system/bin/linker')) {
        $bad += "$b 是 bionic（PRoot 里跑不了）"
    } elseif (-not ($bytes[0] -eq 0x7F -and $bytes[1] -eq 0x45)) {  # "ELF"
        $bad += "$b 不是 ELF"
    }
}
if ($bad.Count -gt 0) {
    Write-Bad ($bad -join '; ')
    exit 1
}
Write-Ok "三个二进制都是 linux ELF（非 bionic）"

# ============================================================================
Write-Host ""
$total = (Get-ChildItem $AssetDir -File | Measure-Object Length -Sum).Sum
Write-Ok ("T1 工具已入库：{0} 个文件 / {1:N2} MB（APK 里会再压缩）" -f (Get-ChildItem $AssetDir -File).Count, ($total / 1MB))
Write-Host ""
Write-Info "下一步：构建 APK 后，运行时会把这些资产解压到 rootfs/opt/as"
Write-Info "（见 BundledTooltools.kt / BuildSuiteInstaller 的 bundled 分支）"
exit 0
