# Copyright (C) 2026 Heracles-taixu-sandbox contributors
# SPDX-License-Identifier: GPL-3.0
#
# 把沙箱的 4 个库模块打成 AAR，并同步进 Heracles 的 `app/android/app/libs/`。
#
# ============================================================================
# 为什么需要这个脚本
# ============================================================================
# Heracles 用**预编译 AAR** 内联沙箱，不是 `include` 模块。原因是两套 AGP：
#   沙箱   AGP 8.13 / Kotlin 2.2.20
#   Heracles AGP 9.0.1 / Kotlin 2.3.20（built-in Kotlin）
# 直接 include 会让两套 AGP 在同一个构建里打架。
#
# 代价是：**改了沙箱必须重新出 AAR 并拷过去**，否则 Heracles 里跑的还是旧代码。
# 这个脚本就是防这个坑 —— 忘了同步时，Heracles 的表现会莫名其妙（旧 bug 还在）。
#
# ============================================================================
# 用法
# ============================================================================
#   # 默认：构建 + 同步 + 校验
#   pwsh -File tools/sync-aar-to-heracles.ps1
#
#   # 只校验（不构建、不拷贝），适合 CI 或提交前检查
#   pwsh -File tools/sync-aar-to-heracles.ps1 -VerifyOnly
#
#   # 自定义 Heracles 的 libs 目录
#   pwsh -File tools/sync-aar-to-heracles.ps1 -TargetLibsDir "D:\path\to\app\android\app\libs"
#
# ============================================================================
# 校验什么（不只是"拷过去了"）
# ============================================================================
# 1. 4 个 AAR 都存在且非空
# 2. `sandbox-runtime` 里必须有 `assets/rootfs-bundle.bin`（内置离线 rootfs，压缩态）
# 3. `sandbox-runtime` 里必须有 `jni/arm64-v8a/libproot.so`（PRoot 本体）
# 4. 目标目录里的 AAR 与本地产物的 **sha256 一致**（防"以为同步了其实没同步"）
#
# 少任何一条都 exit 1 —— 宁可报错，也不要让 Heracles 里跑旧沙箱。

param(
    [string]$SandboxRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$TargetLibsDir = "",
    [switch]$VerifyOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Modules = @('sandbox-api', 'sandbox-runtime', 'sandbox-channel', 'sandbox-file')

function Write-Step([string]$t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "    OK   $t" -ForegroundColor Green }
function Write-Info([string]$t) { Write-Host "    ·    $t" }
function Write-Bad([string]$t) { Write-Host "    FAIL $t" -ForegroundColor Red }

# 默认目标：<repo>/app/android/app/libs
if ([string]::IsNullOrWhiteSpace($TargetLibsDir)) {
    $TargetLibsDir = Join-Path $SandboxRoot '..\app\android\app\libs'
}
$TargetLibsDir = [System.IO.Path]::GetFullPath($TargetLibsDir)

$problems = New-Object System.Collections.Generic.List[string]

# ============================================================================
Write-Step "定位 AAR 产物"
# ============================================================================
$aars = @{}
foreach ($m in $Modules) {
    $outDir = Join-Path $SandboxRoot "$m\build\outputs\aar"
    $file = $null
    if (Test-Path $outDir) {
        $file = Get-ChildItem $outDir -Filter "*-release.aar" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($file) {
        $aars[$m] = $file
        Write-Info ("{0,-18} {1,-32} {2,8:N2} MB  {3}" -f $m, $file.Name, ($file.Length / 1MB), $file.LastWriteTime.ToString('HH:mm:ss'))
    } else {
        $problems.Add("缺少 $m 的 release AAR（先跑构建）")
        Write-Bad "$m 无产物"
    }
}

if ($aars.Count -lt $Modules.Count -and $VerifyOnly) {
    Write-Host ""
    Write-Host "缺少产物，无法仅校验。请先执行不带 -VerifyOnly 的一次。" -ForegroundColor Red
    exit 1
}

# ============================================================================
if (-not $VerifyOnly) {
    Write-Step "重新构建 release AAR"
    # ★ 用 Gradle 的绝对路径调用，避免依赖当前工作目录
    $gradlew = Join-Path $SandboxRoot 'gradlew.bat'
    if (-not (Test-Path $gradlew)) { throw "找不到 $gradlew" }

    $tasks = $Modules | ForEach-Object { ":$($_):assembleRelease" }
    $args = @($tasks) + @('--no-daemon', '--console=plain')
    Write-Info ("gradlew " + ($tasks -join ' '))

    $log = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-aar-" + [System.Guid]::NewGuid().ToString('N') + ".log")
    & cmd /c "`"$gradlew`" $($args -join ' ') > `"$log`" 2>&1"
    $exit = $LASTEXITCODE
    $raw = Get-Content $log -Raw -ErrorAction SilentlyContinue

    if ($raw -match "BUILD SUCCESSFUL") {
        Write-Ok "构建成功"
    } elseif ($raw -match "BindException|Could not start your build|Kotlin compile daemon") {
        # 本机 loopback 间歇性拒绝（errno 10013）—— 已知环境坑，重试一次
        Write-Info "构建被本机 loopback 问题打断，重试一次…"
        & cmd /c "`"$gradlew`" $($args -join ' ') > `"$log`" 2>&1"
        $raw = Get-Content $log -Raw -ErrorAction SilentlyContinue
        if ($raw -match "BUILD SUCCESSFUL") { Write-Ok "重试后构建成功" }
        else {
            $problems.Add("AAR 构建失败（见 $log）")
            Write-Bad "构建失败；日志：$log"
        }
    } else {
        $problems.Add("AAR 构建失败（见 $log）")
        Write-Bad "构建失败；日志：$log"
        ($raw -split "`n" | Where-Object { $_ -match "e: |error:|FAILED" } | Select-Object -First 8) | ForEach-Object { Write-Info $_.Trim() }
    }

    # 构建后重新定位
    $aars = @{}
    foreach ($m in $Modules) {
        $outDir = Join-Path $SandboxRoot "$m\build\outputs\aar"
        if (Test-Path $outDir) {
            $file = Get-ChildItem $outDir -Filter "*-release.aar" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($file) { $aars[$m] = $file }
        }
    }

    # ========================================================================
    Write-Step "拷进 Heracles"
    # ========================================================================
    if (-not (Test-Path $TargetLibsDir)) {
        New-Item -ItemType Directory -Force -Path $TargetLibsDir | Out-Null
        Write-Info "已创建 $TargetLibsDir"
    }
    foreach ($m in $Modules) {
        if (-not $aars.ContainsKey($m)) { continue }
        $src = $aars[$m]
        $dst = Join-Path $TargetLibsDir "$m-release.aar"
        Copy-Item $src.FullName $dst -Force
        Write-Ok ("{0,-18} → {1}" -f $src.Name, $dst)
    }
} else {
    Write-Info "（-VerifyOnly：不构建、不拷贝，只校验）"
}

# ============================================================================
Write-Step "校验 AAR 内容"
# ============================================================================
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-AarEntry([string]$aarPath, [string]$pattern) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($aarPath)
    try {
        return @($zip.Entries | Where-Object { $_.FullName -like $pattern }).Count -gt 0
    } finally { $zip.Dispose() }
}

$runtimeAar = Join-Path $TargetLibsDir 'sandbox-runtime-release.aar'
if (Test-Path $runtimeAar) {
    if (Test-AarEntry $runtimeAar 'assets/rootfs-bundle.*') {
        Write-Ok "runtime 含内置 rootfs（assets/rootfs-bundle.bin）"
    } else {
        $problems.Add("runtime AAR 里没有 assets/rootfs-bundle.* —— 内置离线 rootfs 丢了")
        Write-Bad "runtime 缺少内置 rootfs"
    }
    foreach ($so in @('libproot.so', 'libproot-loader.so', 'libpty_bridge.so')) {
        if (Test-AarEntry $runtimeAar "jni/arm64-v8a/$so") {
            Write-Ok "runtime 含 jni/arm64-v8a/$so"
        } else {
            $problems.Add("runtime AAR 里没有 jni/arm64-v8a/$so")
            Write-Bad "runtime 缺少 $so"
        }
    }
} else {
    $problems.Add("目标目录里没有 sandbox-runtime-release.aar")
    Write-Bad "目标缺 runtime AAR"
}

# ============================================================================
Write-Step "校验 sha256（本地产物 vs 目标目录）"
# ============================================================================
foreach ($m in $Modules) {
    if (-not $aars.ContainsKey($m)) { continue }
    $srcHash = (Get-FileHash $aars[$m].FullName -Algorithm SHA256).Hash
    $dstPath = Join-Path $TargetLibsDir "$m-release.aar"
    if (-not (Test-Path $dstPath)) {
        $problems.Add("目标目录缺 $m-release.aar")
        Write-Bad "$m 目标缺失"
        continue
    }
    $dstHash = (Get-FileHash $dstPath -Algorithm SHA256).Hash
    if ($srcHash -eq $dstHash) {
        Write-Ok ("{0,-18} {1}" -f $m, $srcHash.Substring(0, 16))
    } else {
        $problems.Add("$m 的 sha256 与本地不一致（拷贝没生效？）")
        Write-Bad ("{0} 不一致：src={1} dst={2}" -f $m, $srcHash.Substring(0, 12), $dstHash.Substring(0, 12))
    }
}

# ============================================================================
Write-Host ""
if ($problems.Count -eq 0) {
    Write-Ok "同步完成且校验通过"
    Write-Host ""
    Write-Info "下一步：cd app && flutter build apk --debug --target-platform android-arm64"
    Write-Info "        （或你想带 Dart 自检：追加 --dart-define=SANDBOX_SELFTEST=true）"
    exit 0
} else {
    Write-Host "同步/校验失败：" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
