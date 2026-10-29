# ============================================================================
# !!! 供 Heracles 控制面参考，**不属于沙箱** !!!
# ============================================================================
# 沙箱（sandbox/）**不打包任何 Android 构建工具**。原因：
#   Termux 的 aapt2/zip 是 **bionic** 二进制（解释器 /system/bin/linker64），
#   只能在**宿主进程**里 exec；打进 APK 就等于绕过沙箱
#   （隔离/快照/回滚全都不生效）。真机实测过，已全部回退（见 porting-log Phase 7/8）。
#
# 沙箱内的工具必须装在 **rootfs** 里、用 **linux-aarch64** 版：
#   JDK17 / aapt2 / aidl / zipalign / android.jar / Gradle
#   （taixu 的 assets/plugins/android-suite-offline 就是这么做的）
#
# 本脚本保留的价值：它固化了「怎么从 Termux 源取包、校验 sha256、解 ar 归档、
# 算 DT_NEEDED 闭包、改 SONAME」这套知识。将来若真的需要做宿主侧工具，
# 可以直接复用；**但不要把它接回 sandbox/ 的构建路径**。
# ============================================================================
# SPDX-License-Identifier: GPL-3.0
#
# Copyright (C) 2026 Heracles-taixu-sandbox contributors
#
# ============================================================================
# 取「离线重打包 APK」工具链（Windows / PowerShell 5.1 / 无 bash / 无 dpkg-deb）
# ============================================================================
# 产出（默认落 sandbox-runtime/src/main/assets/toolchain/，随仓库交付）：
#
#   toolchain/
#     ├── manifest.json         每个文件的来源 / 版本 / sha256 / 字节数
#     ├── NOTICE-toolchain.txt  上游协议与来源声明
#     ├── bin/aapt2             Termux aapt2（AArch64，bionic）
#     ├── bin/zip               Termux zip（AArch64，bionic）
#     ├── bin/apksigner         启动脚本（**需要 JDK**，本仓库不内置 JDK）
#     ├── lib/*.so              aapt2 / zip 的 DT_NEEDED 闭包
#     └── share/java/apksigner.jar
#
# ============================================================================
# 为什么不用 android-sdk 的 build-tools（重要，别改回 glibc 版）
# ============================================================================
# Heracles 的 ADR-025：设备侧工具链**必须**用 Termux 的 bionic 包。
# Android SDK 自带的 aapt2 / zipalign 是 glibc + linux-x86-64 的，
# 在 Android 上（bionic / AArch64）跑不起来。
#
# **zipalign 在 Termux 源里不存在**（本脚本会实测并打印结论）——
# 这不是缺陷，见 docs 里 ADR-027：对齐由宿主的进程内 ZipAligner 负责，
# 沙箱侧不需要 zipalign。所以本脚本**不产出** zipalign。
#
# ============================================================================
# 本机环境约束（踩过的坑，别"优化"掉）
# ============================================================================
# 1. 本机只有 PowerShell 5.1，**没有 bash / pwsh / dpkg-deb**。
# 2. .deb 是 ar 归档。Windows 自带的 `tar` 是 bsdtar 3.8.8，**认得 ar 归档**：
#      tar -xf pkg.deb      -> data.tar.xz / control.tar.xz / debian-binary
#      tar -xf data.tar.xz  -> 真实文件树
#    ⇒ 两段式解包，不依赖 dpkg-deb。
# 3. 含中文的 .ps1 必须 UTF-8 带 BOM（PS 5.1 会按 ANSI 解码，中文注释变语法错误）。
#    本文件已按 BOM 保存。
# 4. 不设 $ErrorActionPreference = "Stop" 之外的花活；下载失败要显式失败，
#    不许"跳过后照样写出一个空目录"（那正是本工程被批过的"假成功"）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\fetch-toolchain.ps1
#   powershell -ExecutionPolicy Bypass -File tools\fetch-toolchain.ps1 -Force   # 重下
#   powershell -ExecutionPolicy Bypass -File tools\fetch-toolchain.ps1 -DryRun  # 只查源
# ============================================================================

[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\sandbox-runtime\src\main\assets\toolchain'),
    [string]$WorkDir = (Join-Path $PSScriptRoot '.toolchain-work'),
    [string]$Repo = 'https://packages.termux.dev/apt/termux-main/',
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# 想内置的顶层包。apksigner 记为「只取 jar」：它依赖 openjdk-21（106 MB），
# 本次**不内置 JDK**，所以 jar 在、但跑不起来 —— 这是**刻意的降级**，
# 由 BundledToolchain 如实报告「apksigner 不可用（缺 java）」。
# ----------------------------------------------------------------------------
$WantedPackages = @(
    @{ Name = 'aapt2';     Role = 'binary' },
    @{ Name = 'zip';       Role = 'binary' },
    @{ Name = 'apksigner'; Role = 'jar-only' }
)

# 不要 zipalign：Termux 源里没有（脚本会实测确认并打印）。
$ForbiddenNames = @('zipalign')

$IndexRelPath = 'dists/stable/main/binary-aarch64/Packages.gz'

# ============================================================================
# 小工具
# ============================================================================

function Write-Step([string]$text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host "    OK   $text" -ForegroundColor Green }
function Write-Warn2([string]$text) { Write-Host "    WARN $text" -ForegroundColor Yellow }
function Write-Info([string]$text) { Write-Host "    ·    $text" }

function Assert-TarAvailable {
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw "本机没有 tar。Windows 10 1803+ 自带 bsdtar；请确认 PATH 里有 C:\Windows\System32\tar.exe"
    }
    $ver = (& tar --version 2>&1 | Out-String)
    Write-Info ("tar = " + ($ver -split "`n")[0].Trim())
    if ($ver -notmatch 'bsdtar') {
        Write-Warn2 "本机的 tar 不是 bsdtar；GNU tar 不认 ar 归档，解 .deb 会失败"
    }
}

# ----------------------------------------------------------------------------
# Termux 源索引：下载 Packages.gz 并解析成 stanza 表
# ----------------------------------------------------------------------------
function Get-TermuxIndex {
    Write-Step "下载并解析 Termux 源索引"
    $cache = Join-Path $WorkDir 'Packages.gz'
    if ($Force -or -not (Test-Path $cache) -or (Get-Item $cache).Length -lt 10000) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
        $url = $Repo + $IndexRelPath
        Write-Info "GET $url"
        Invoke-WebRequest -Uri $url -OutFile $cache -UseBasicParsing -TimeoutSec 180
    }
    Write-Ok ("索引 " + (Get-Item $cache).Length + " B")

    $in = [System.IO.File]::OpenRead($cache)
    try {
        $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $sr = New-Object System.IO.StreamReader($gz)
            try { $text = $sr.ReadToEnd() } finally { $sr.Close() }
        } finally { $gz.Close() }
    } finally { $in.Close() }

    $stanzas = [regex]::Split($text, "(?:\r?\n){2,}") | Where-Object { $_ -match '^Package:' }
    $map = @{}
    foreach ($s in $stanzas) {
        $m = [regex]::Match($s, '(?m)^Package: (.+)$')
        if ($m.Success) { $map[$m.Groups[1].Value.Trim()] = $s }
    }
    Write-Ok ("解析出 " + $map.Count + " 个包")

    # ---- zipalign 尽调：不猜，直接在索引里数 ----
    Write-Step "zipalign 尽调（本循环就是证据）"
    $hits = @()
    foreach ($name in $ForbiddenNames) {
        if ($map.ContainsKey($name)) { $hits += $name }
    }
    $textHits = ([regex]::Matches($text, 'zipalign')).Count
    Write-Info ("索引里 Package: zipalign 的 stanza 数 = " + $hits.Count)
    Write-Info ("索引全文出现字符串 'zipalign' 的次数 = " + $textHits)
    if ($hits.Count -eq 0 -and $textHits -eq 0) {
        Write-Ok "确认：Termux 源里没有任何 zipalign 包（连字符串都没有）"
    } else {
        Write-Warn2 "索引里出现了 zipalign 相关条目，请人工复核：$($hits -join ', ')"
    }
    # 顺带确认它确实有 aapt2/zip/apksigner（否则后面的步骤会空跑）
    foreach ($w in $WantedPackages) {
        if (-not $map.ContainsKey($w.Name)) { throw "Termux 索引里没有包 $($w.Name)" }
    }
    Write-Ok "aapt2 / zip / apksigner 三个包都在索引里"

    return $map
}

function Get-StanzaField($stanza, [string]$field) {
    $m = [regex]::Match($stanza, "(?m)^$([regex]::Escape($field)): (.+)$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# ----------------------------------------------------------------------------
# 下载 .deb 并**校验 sha256**（sha256 不从别处抄，直接来自索引）
# ----------------------------------------------------------------------------
function Get-Deb([string]$name, $map) {
    if (-not $map.ContainsKey($name)) { throw "索引里没有包 $name" }
    $stanza = $map[$name]
    $file = Get-StanzaField $stanza 'Filename'
    $sha = Get-StanzaField $stanza 'SHA256'
    $size = [int64](Get-StanzaField $stanza 'Size')
    if (-not $file -or -not $sha) { throw "包 $name 的索引条目缺 Filename/SHA256" }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

    # ========================================================================
    # ★ 落盘文件名必须净化：Debian 版本号里的 epoch 冒号在 Windows 上非法
    # ========================================================================
    # 真实踩坑（本脚本第一次跑就炸）：
    #   libprotobuf 的包文件名是 `libprotobuf_2:36.2-1_aarch64.deb`
    #   —— `2:` 是 Debian 的 epoch 前缀，在 deb 世界里是合法的。
    #   但 Windows 文件名不允许 `:`，于是 Invoke-WebRequest 报：
    #       "不支持给定路径的格式。"
    #
    # 关键区分：
    #   · URL 里的 `:` 是**合法的**（HTTP path 允许），要保持原样；
    #   · 坏的只是**落盘文件名**。
    # 所以只净化本地文件名，URL 不动。sha256 校验的是内容，与文件名无关。
    $leaf = Split-Path $file -Leaf
    $safeLeaf = $leaf -replace ':', '_'
    $dest = Join-Path $WorkDir $safeLeaf
    if ($Force -or -not (Test-Path $dest) -or (Get-Item $dest).Length -ne $size) {
        $url = $Repo + $file
        Write-Info "GET $url"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 300
    }
    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $sha.ToLowerInvariant()) {
        throw "包 $name sha256 不匹配：期望 $sha，实际 $actual（下载被污染/截断）"
    }
    $len = (Get-Item $dest).Length
    if ($len -ne $size) { throw "包 $name 体积不匹配：索引 $size B，实际 $len B" }
    Write-Ok ("$name  " + $len.ToString('N0') + " B  sha256=" + $actual.Substring(0, 16) + "…")
    return $dest
}

# ----------------------------------------------------------------------------
# 解 .deb：bsdtar 认得 ar 归档 ⇒ 两段式（不依赖 dpkg-deb）
# ----------------------------------------------------------------------------
function Expand-Deb([string]$debPath, [string]$destDir) {
    if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    Push-Location $destDir
    try {
        $null = & tar -xf $debPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "bsdtar 解 ar 归档失败：$debPath" }
        $payload = $null
        foreach ($candidate in @('data.tar.xz', 'data.tar.gz', 'data.tar.zst', 'data.tar')) {
            if (Test-Path (Join-Path $destDir $candidate)) { $payload = $candidate; break }
        }
        if (-not $payload) {
            $found = (Get-ChildItem $destDir | ForEach-Object { $_.Name }) -join ', '
            throw "解 .deb 后没找到 data.tar.*（实际成员：$found）"
        }
        if ($payload -eq 'data.tar.zst') {
            throw "data.tar.zst 需要 zstd 解压，本机没有。请换一个 xz/gz 的包。"
        }
        Write-Info ("ar 成员已解出，payload = " + $payload)
        $null = & tar -xf $payload 2>&1
        if ($LASTEXITCODE -ne 0) { throw "bsdtar 解 $payload 失败" }
        Remove-Item -Force (Join-Path $destDir $payload) -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $destDir 'debian-binary') -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $destDir 'control.tar.xz') -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }
    # ========================================================================
    # ★ 返回 Termux 的 **prefix 根**（.../files/usr），不是 .../files
    # ========================================================================
    # Termux 的目录约定是：
    #   /data/data/com.termux/files/usr/bin/aapt2     ← 可执行
    #   /data/data/com.termux/files/usr/lib/*.so      ← 库
    # 注意中间那层 `usr` —— titled "prefix" 就是 files/usr。
    #
    # 踩坑记录：第一版返回 .../files，调用方再拼 bin/lib，得到 .../files/bin
    # （**不存在**），于是清点出 0 个 ELF，报「解包结果里没有 aapt2」。
    # 排查时容易误以为是源包结构变了，其实是我们自己少拼了一层。
    return (Join-Path $destDir 'data\data\com.termux\files\usr')
}

# ----------------------------------------------------------------------------
# 最小 ELF 解析器（.NET，不用 readelf —— 本机没有）
#   只读三样：e_machine（要 AArch64）、DT_NEEDED、DT_SONAME
# ----------------------------------------------------------------------------
function Get-ElfInfo([string]$path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 64) { return $null }
    if (-not ($b[0] -eq 0x7F -and $b[1] -eq 0x45 -and $b[2] -eq 0x4C -and $b[3] -eq 0x46)) {
        return $null
    }
    if ($b[4] -ne 2) { return $null }  # 只处理 ELF64
    $machine = [BitConverter]::ToUInt16($b, 0x12)

    $e_shoff = [BitConverter]::ToInt64($b, 0x28)
    $e_shentsize = [BitConverter]::ToUInt16($b, 0x3A)
    $e_shnum = [BitConverter]::ToUInt16($b, 0x3C)
    $e_shstrndx = [BitConverter]::ToUInt16($b, 0x3E)

    $sections = @()
    for ($i = 0; $i -lt $e_shnum; $i++) {
        $o = $e_shoff + $i * $e_shentsize
        $sections += [pscustomobject]@{
            NameOff = [BitConverter]::ToUInt32($b, $o)
            Type    = [BitConverter]::ToUInt32($b, $o + 4)
            Off     = [BitConverter]::ToInt64($b, $o + 0x18)
            Size    = [BitConverter]::ToInt64($b, $o + 0x20)
            Link    = [BitConverter]::ToUInt32($b, $o + 0x28)
        }
    }
    if ($sections.Count -le $e_shstrndx) { return $null }
    $shstr = $sections[$e_shstrndx]

    return [pscustomobject]@{
        Bytes    = $b
        Machine  = $machine
        Sections = $sections
        ShStrTab = $shstr
        Needed   = (Read-ElfStrings -b $b -sections $sections -shstr $shstr -tag 1)
        Soname   = ((Read-ElfStrings -b $b -sections $sections -shstr $shstr -tag 14) | Select-Object -First 1)
    }
}

function Read-CStr([byte[]]$b, [int64]$off) {
    $e = $off
    while ($e -lt $b.Length -and $b[$e] -ne 0) { $e++ }
    return [System.Text.Encoding]::ASCII.GetString($b, [int]$off, [int]($e - $off))
}

function Read-ElfStrings([byte[]]$b, $sections, $shstr, [int64]$tag) {
    $result = @()
    $dyn = $null
    foreach ($s in $sections) { if ($s.Type -eq 6) { $dyn = $s; break } }   # SHT_DYNAMIC
    if (-not $dyn) { return $result }
    $dynstr = $sections[$dyn.Link]
    $p = $dyn.Off
    $end = $dyn.Off + $dyn.Size
    while ($p -lt $end) {
        $dTag = [BitConverter]::ToInt64($b, $p)
        $dVal = [BitConverter]::ToInt64($b, $p + 8)
        if ($dTag -eq 0) { break }
        if ($dTag -eq $tag) { $result += (Read-CStr $b ($dynstr.Off + $dVal)) }
        $p += 16
    }
    return $result
}

function Test-Aarch64([string]$path) {
    $info = Get-ElfInfo $path
    if (-not $info) { return $false }
    return ($info.Machine -eq 0xB7)
}

# ============================================================================
# 主流程
# ============================================================================

Write-Host "Heracles-taixu-sandbox —— 离线重打包工具链取包脚本" -ForegroundColor White
Write-Host "  仓库  : $Repo"
Write-Host "  产出  : $OutDir"
Write-Host "  工作区: $WorkDir"

Assert-TarAvailable
$index = Get-TermuxIndex

if ($DryRun) {
    Write-Step "DryRun：只查源，不下载/不写产物"
    foreach ($w in $WantedPackages) {
        $s = $index[$w.Name]
        Write-Info ("{0,-12} {1,-14} {2,9:N0} KB  {3}" -f $w.Name,
            (Get-StanzaField $s 'Version'), ([int64](Get-StanzaField $s 'Size') / 1KB),
            (Get-StanzaField $s 'Filename'))
    }
    Write-Host ""
    Write-Host "DryRun 结束（未写入任何文件）" -ForegroundColor Yellow
    return
}

# ---- 1. 解析依赖闭包（只跟 Depends，不含 openjdk：JDK 不内置） ----
Write-Step "解析 .deb 依赖闭包"
$closure = New-Object System.Collections.Specialized.OrderedDictionary
$queue = New-Object System.Collections.Queue
foreach ($w in $WantedPackages) { $queue.Enqueue($w.Name) }
$skipDepsFor = @('apksigner')   # jar-only：不跟 openjdk-21
while ($queue.Count -gt 0) {
    $name = [string]$queue.Dequeue()
    if ($closure.Contains($name)) { continue }
    if (-not $index.ContainsKey($name)) {
        throw "依赖 $name 不在 Termux 索引里（源可能改名了，别静默跳过）"
    }
    $closure[$name] = $true
    if ($skipDepsFor -contains $name) { continue }
    $depLine = Get-StanzaField $index[$name] 'Depends'
    if (-not $depLine) { continue }
    foreach ($d in ($depLine -split ',')) {
        $dep = ($d -split '\(')[0].Trim()
        if (-not $dep) { continue }
        if ($dep -like 'openjdk*') {
            Write-Warn2 "$name 依赖 $dep —— 本次**不内置 JDK**（体积原因）"
            continue
        }
        if (-not $closure.Contains($dep)) { $queue.Enqueue($dep) }
    }
}
Write-Ok ("闭包 " + $closure.Count + " 个包: " + (($closure.Keys) -join ', '))

# ---- 2. 下载 + 解包 ----
Write-Step "下载并校验 .deb"
$extracted = @{}   # pkg -> termux usr 目录
foreach ($name in $closure.Keys) {
    $deb = Get-Deb $name $index
    $dest = Join-Path (Join-Path $WorkDir 'x') $name
    $usr = Expand-Deb $deb $dest
    if (-not (Test-Path $usr)) { throw "解包后没有 Termux usr 目录：$usr" }
    $extracted[$name] = $usr
}
Write-Ok ("已解包 " + $extracted.Count + " 个包")

# ---- 3. 收集候选 ELF（bin + lib）----
Write-Step "清点 ELF 并把 e_machine 校验成 AArch64"
$binFiles = @{}    # 文件名 -> 源路径（只收 usr/bin）
$libFiles = @{}    # 文件名 -> 源路径（usr/lib 下的 .so*）
$sonameToFile = @{}
$rejected = @()

foreach ($pkg in $extracted.Keys) {
    $usr = $extracted[$pkg]
    foreach ($sub in @('bin', 'lib')) {
        $dir = Join-Path $usr $sub
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in (Get-ChildItem $dir -File -ErrorAction SilentlyContinue)) {
            $info = Get-ElfInfo $f.FullName
            if (-not $info) { continue }
            if ($info.Machine -ne 0xB7) {
                $rejected += ("{0} (e_machine=0x{1:X})" -f $f.Name, $info.Machine)
                continue
            }
            if ($sub -eq 'bin') {
                $binFiles[$f.Name] = $f.FullName
            } else {
                $libFiles[$f.Name] = $f.FullName
                if ($info.Soname) { $sonameToFile[$info.Soname] = $f.FullName }
            }
        }
    }
}
Write-Info ("AArch64 可执行: " + (($binFiles.Keys | Sort-Object) -join ', '))
Write-Info ("AArch64 库    : " + (($libFiles.Keys | Sort-Object) -join ', '))
if ($rejected.Count -gt 0) { Write-Warn2 ("跳过非 AArch64: " + ($rejected -join ', ')) }

foreach ($need in @('aapt2', 'zip')) {
    if (-not $binFiles.ContainsKey($need)) { throw "解包结果里没有 $need（源包结构变了？）" }
    if (-not (Test-Aarch64 $binFiles[$need])) { throw "$need 不是 AArch64 ELF —— 绝对不能打进包里" }
}

# ---- 4. DT_NEEDED 闭包：只带真正需要的 .so ----
Write-Step "计算 DT_NEEDED 闭包（只带真正需要的 .so，别把整个 abseil 搬进来）"
$neededLibs = New-Object System.Collections.Specialized.OrderedDictionary
$resolvedBy = @{}
$unresolved = @()
$queue = New-Object System.Collections.Queue
foreach ($need in @('aapt2', 'zip')) {
    $info = Get-ElfInfo $binFiles[$need]
    foreach ($n in $info.Needed) { $queue.Enqueue(@{ Lib = $n; From = $need }) }
}
while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    $lib = [string]$item.Lib
    $from = [string]$item.From
    if ($lib -match '^lib(c|dl|m|log|android|z\.so$|stdc\+\+)') {
        # bionic 提供的系统库 —— 由设备 linker 解决，**不要**打进 assets
        if ($lib -in @('libc.so', 'libdl.so', 'libm.so', 'liblog.so', 'libandroid.so')) { continue }
    }
    if ($neededLibs.Contains($lib)) { continue }
    if ($sonameToFile.ContainsKey($lib)) {
        $neededLibs[$lib] = $sonameToFile[$lib]
    } elseif ($libFiles.ContainsKey($lib)) {
        $neededLibs[$lib] = $libFiles[$lib]
    } else {
        $unresolved += "$lib (被 $from 需要)"
        continue
    }
    $info = Get-ElfInfo $neededLibs[$lib]
    foreach ($n in $info.Needed) { $queue.Enqueue(@{ Lib = $n; From = $lib }) }
}
if ($unresolved.Count -gt 0) {
    # 唯一允许的未解析是 bionic 系统库（libc/libdl/libm/liblog/libandroid）
    $realUnresolved = $unresolved | Where-Object { $_ -notmatch '^lib(c|dl|m|log|android)\.so' }
    if ($realUnresolved.Count -gt 0) {
        throw ("以下 DT_NEEDED 找不到对应的 .so，打出来的包一跑就会 CANNOT LINK：`n  " +
            ($realUnresolved -join "`n  "))
    }
}
Write-Ok ("需要打入的库 " + $neededLibs.Count + " 个: " + (($neededLibs.Keys | Sort-Object) -join ', '))

# ---- 5. 写产物 ----
Write-Step "写产物到 $OutDir"
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
$binOut = Join-Path $OutDir 'bin'
$libOut = Join-Path $OutDir 'lib'
$javaOut = Join-Path $OutDir 'share\java'
New-Item -ItemType Directory -Force -Path $binOut | Out-Null
New-Item -ItemType Directory -Force -Path $libOut | Out-Null
New-Item -ItemType Directory -Force -Path $javaOut | Out-Null

$manifest = @()
function Add-ManifestEntry([string]$relPath, [string]$fullPath, [string]$origin, [string]$version, [string]$license) {
    $sha = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:manifest += [pscustomobject]@{
        path    = $relPath
        bytes   = (Get-Item $fullPath).Length
        sha256  = $sha
        origin  = $origin
        version = $version
        license = $license
    }
}

# 5.1 两个可执行
foreach ($tool in @('aapt2', 'zip')) {
    $src = $binFiles[$tool]
    $dst = Join-Path $binOut $tool
    Copy-Item -Force $src $dst
    $pkgName = $tool
    Add-ManifestEntry "bin/$tool" $dst "termux:packages.termux.dev/$pkgName" (Get-StanzaField $index[$pkgName] 'Version') 'GPL-3.0-or-later (termux packaging)'
    Write-Info ("bin/{0,-10} {1,10:N0} B" -f $tool, (Get-Item $dst).Length)
}

# 5.2 依赖库
foreach ($lib in $neededLibs.Keys) {
    $src = $neededLibs[$lib]
    $dst = Join-Path $libOut $lib
    Copy-Item -Force $src $dst
    Add-ManifestEntry "lib/$lib" $dst "termux:dep of aapt2/zip" '' 'see NOTICE-toolchain.txt'
}

# 5.3 apksigner 的 jar + 启动脚本
$apkUsr = $extracted['apksigner']
$jar = Join-Path $apkUsr 'share\java\apksigner.jar'
if (-not (Test-Path $jar)) { throw "apksigner 包里没有 share/java/apksigner.jar" }
Copy-Item -Force $jar (Join-Path $javaOut 'apksigner.jar')
Add-ManifestEntry 'share/java/apksigner.jar' (Join-Path $javaOut 'apksigner.jar') 'termux:apksigner' (Get-StanzaField $index['apksigner'] 'Version') 'Apache-2.0'

# 启动脚本：**必须**指向沙箱内路径（Termux 的原脚本写死
# /data/data/com.termux/files/usr/share/java/apksigner.jar，到我们的 guest 里无效）
$wrapper = @'
#!/bin/sh
# SPDX-License-Identifier: GPL-3.0
#
# apksigner 启动脚本（Heracles-taixu-sandbox 版）
#
# ★ 与 Termux 原脚本的差异（必须保留这段说明，否则下一个人会改回去）：
#   Termux 的原脚本是：
#       exec java -jar /data/data/com.termux/files/usr/share/java/apksigner.jar "$@"
#   那个绝对路径只在 Termux 自己的 prefix 下成立；在沙箱 guest 里对应的是
#   /opt/toolchain/share/java/apksigner.jar。
#
# ★ 本仓库**不内置 JDK**（openjdk-21 的 .deb 是 106 MB），所以本脚本在
#   没有 java 的 guest 里会失败并打印明确提示 —— 这是**如实降级**，不是坏了。
#   想让 apksigner 真的能用，宿主需要：
#     (a) 内置一个 JDK（体积另议），或
#     (b) 在 rootfs 里 apk add openjdk21，或
#     (c) 用 apksig 库在宿主进程内签名（Heracles 主工程的做法）。
set -e
SELF_DIR=$(dirname "$0")
TOOLCHAIN_ROOT=$(cd "$SELF_DIR/.." && pwd)
JAR="$TOOLCHAIN_ROOT/share/java/apksigner.jar"

if ! command -v java >/dev/null 2>&1; then
    echo "apksigner: 找不到 java（本沙箱不内置 JDK）" >&2
    echo "apksigner: jar 在 $JAR，但执行需要 JRE 21" >&2
    echo "apksigner: 见 /opt/toolchain/NOTICE-toolchain.txt" >&2
    exit 127
fi

# Android 上没有 /tmp：java 的 tmpdir 必须显式指到可写目录（本项目硬约束）
exec java -Djava.io.tmpdir="${TMPDIR:-/tmp}" -Duser.home="${HOME:-/root}" \
    -jar "$JAR" "$@"
'@
$wrapperPath = Join-Path $binOut 'apksigner'
# 用 LF 换行写（CRLF 会让 guest 里的 sh 报 "not found"）
$wrapperLf = $wrapper -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($wrapperPath, $wrapperLf, (New-Object System.Text.UTF8Encoding($false)))
Add-ManifestEntry 'bin/apksigner' $wrapperPath 'heracles (wrapper) + termux:apksigner (jar)' (Get-StanzaField $index['apksigner'] 'Version') 'GPL-3.0 (wrapper) / Apache-2.0 (jar)'

# 5.4 协议声明（分发二进制必须带）
$notice = @"
SPDX-License-Identifier: GPL-3.0

Heracles-taixu-sandbox —— 内置离线工具链的第三方来源与协议
================================================================

本目录下的二进制**不是**本工程编译的，来自 Termux 的 aarch64 包（bionic）。
取包脚本：tools/fetch-toolchain.ps1（含 sha256 校验，来源可复现）

来源仓库：https://packages.termux.dev/apt/termux-main/
索引     ：dists/stable/main/binary-aarch64/Packages.gz

----------------------------------------------------------------
bin/aapt2               —— Android Asset Packaging Tool
  Termux 包 : aapt2 $(Get-StanzaField $index['aapt2'] 'Version')
  上游协议  : Apache-2.0（AOSP build-tools）
  上游地址  : https://github.com/termux/android-build-tools

bin/zip                 —— Info-ZIP zip
  Termux 包 : zip $(Get-StanzaField $index['zip'] 'Version')
  上游协议  : Info-ZIP license（BSD 风格）
  上游地址  : https://sourceforge.net/projects/infozip/

lib/*.so                —— aapt2 / zip 的 DT_NEEDED 依赖
  来自 abseil-cpp / libprotobuf / fmt / libc++ / libexpat / libpng /
  libzopfli / zlib / libandroid-support / libbz2 的 Termux aarch64 包。
  各自适用其上游协议（Apache-2.0 with LLVM exception / BSD / Zlib 等）。

share/java/apksigner.jar + bin/apksigner
  Termux 包 : apksigner $(Get-StanzaField $index['apksigner'] 'Version')
  上游协议  : Apache-2.0（AOSP apksig）
  ★ 需要 JRE 21 才能执行；本仓库**不内置 JDK**。

----------------------------------------------------------------
★ 关于 zipalign：本目录**没有** zipalign，而且是**故意**没有的
----------------------------------------------------------------
1. Termux 源里不存在 zipalign 包（tools/fetch-toolchain.ps1 每次运行都会
   在 Packages 索引里实测并打印「Package: zipalign 的 stanza 数 = 0」）。
2. Android SDK 的 build-tools 里的 zipalign 是 glibc / linux-x86-64 的，
   在 Android（bionic / AArch64）上跑不起来 —— Heracles ADR-025。
3. Heracles ADR-027：APK 对齐由**宿主进程内的 ZipAligner** 负责，
   沙箱只负责「解包 → 改文件 → 重新打包」。所以沙箱侧不需要 zipalign。

如果你的集成确实需要一个独立可执行的 zipalign，请自行编译 AArch64 版：
zipalign 的上游源码在 AOSP build-tools（Apache-2.0），
依赖 libandroidfw / libutils / libcutils 等，本工程未做这件事。
"@
$noticePath = Join-Path $OutDir 'NOTICE-toolchain.txt'
[System.IO.File]::WriteAllText($noticePath, ($notice -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "NOTICE-toolchain.txt"

# 5.5 manifest.json（BundledToolchain 读它来决定「有哪些工具、版本是什么」）
$manifestObj = [pscustomobject]@{
    generator = 'tools/fetch-toolchain.ps1'
    repo      = $Repo
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    abi       = 'arm64-v8a'
    zipalign  = 'absent-by-design'
    files     = $script:manifest
}
$manifestPath = Join-Path $OutDir 'manifest.json'
$json = $manifestObj | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($manifestPath, ($json -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "manifest.json（$($script:manifest.Count) 条）"

# ---- 6. 汇总 ----
Write-Step "产物汇总"
$total = 0
# ★ 必须规范化 $OutDir：它的默认值里带 `..`（tools\..\sandbox-runtime\...），
#   而 Get-ChildItem 返回的 FullName 是**已规范化**的绝对路径。
#   不规范化就会算错前缀长度 → Substring 抛「startIndex 不能大于字符串长度」。
#   （这是本脚本的第二个落盘 bug，与冒号那个不同：那个是文件名非法，这个是路径比对错。）
$outDirFull = [System.IO.Path]::GetFullPath($OutDir)
Get-ChildItem $outDirFull -Recurse -File | Sort-Object FullName | ForEach-Object {
    $total += $_.Length
    $rel = if ($_.FullName.Length -gt $outDirFull.Length + 1) {
        $_.FullName.Substring($outDirFull.Length + 1)
    } else {
        $_.Name
    }
    Write-Host ("    {0,-46} {1,10:N0} B" -f $rel, $_.Length)
}
Write-Host ("    ---- 合计 {0:N0} B = {1:N2} MB" -f $total, ($total / 1MB)) -ForegroundColor Green
if ($total -gt 10MB) {
    Write-Warn2 "超过 10 MB 目标，请检查是否带进了不需要的 .so"
} else {
    Write-Ok "在 10 MB 目标之内"
}

Write-Host ""
Write-Host "完成。产物已入库（见 sandbox/.gitignore 的豁免说明）。" -ForegroundColor Green
