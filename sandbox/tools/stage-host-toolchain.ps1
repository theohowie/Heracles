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
# Copyright (C) 2026 Heracles-taixu-sandbox contributors
# SPDX-License-Identifier: GPL-3.0
#
# 把 assets/toolchain/ 里的 aapt2 / zip 转成**宿主侧可执行**的形式，放进 jniLibs。
#
# ============================================================================
# 为什么需要这一步（Phase 7 的教训）
# ============================================================================
# aapt2 / zip 是 **bionic** 二进制（ELF 解释器 = /system/bin/linker64），
# 在 PRoot 的 guest 里**跑不了**（execve 返回 ENOENT）。真机实测：
#     sh: aapt2: not found     (exit 127)
# 而 rootfs 里的 busybox 是 musl（/lib/ld-musl-aarch64.so.1），所以能跑。
#
# ⇒ 正确做法：让它们**跑在宿主侧**，从 `nativeLibraryDir` 直接 exec。
#   原因：Android 10+ 的 W^X 只允许 `untrusted_app` 从 `nativeLibraryDir`
#   exec（这也是 `libproot.so` 必须放 jniLibs 的原因）。
#
# ============================================================================
# 为什么必须打 DT_NEEDED 补丁
# ============================================================================
# AGP 只把 **`lib*.so`** 形态的文件解压到 nativeLibraryDir。
# 而这三个依赖名带版本号，AGP 不接受（且 DT_NEEDED 是精确匹配）：
#     libz.so.1        → libz.so
#     libexpat.so.1    → libexpat.so
#     libbz2.so.1.0    → libbz2.so
# 三者都比原串短，所以可以**就地用 NUL 补齐**，不改变文件长度/偏移。
# （与 we 之前给 PRoot 打 libtalloc.so.2 → libtalloc.so 同一手法。）
#
# 用法：
#   powershell -File tools/stage-host-toolchain.ps1
#   powershell -File tools/stage-host-toolchain.ps1 -Verify   # 只校验不写

param(
    [string]$AssetsDir = (Join-Path $PSScriptRoot '..\sandbox-runtime\src\main\assets\toolchain'),
    [string]$JniLibsDir = (Join-Path $PSScriptRoot '..\sandbox-runtime\src\main\jniLibs\arm64-v8a'),
    [switch]$Verify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 带版本号 → 规范名。全部比原串短，可 NUL 补齐。
# 第一步：去掉版本号（AGP 只接受 lib*.so，且 DT_NEEDED 精确匹配）
$RenameMap = [ordered]@{
    'libz.so.1'       = 'libz.so'
    'libexpat.so.1'   = 'libexpat.so'
    'libbz2.so.1.0'   = 'libbz2.so'
}

# ============================================================================
# 第二步：**避开 Android 系统公共库的同名抢占**
# ============================================================================
# 真机实测：`libz.so` 改好名之后仍然报
#     CANNOT LINK EXECUTABLE: cannot find "libz.so" from verneed[0]
#     in DT_NEEDED list for ".../libpng16.so"
#
# 原因：Android 自己就带 `/system/lib64/libz.so`（zlib 是**公共 NDK 库**），
# 链接器会优先解析到系统那份；我们打进 jniLibs 的同名库**被忽略**，
# 于是 DT_NEEDED/verneed 的符号版本对不上。
#
# ⇒ 把我们的 zlib 改成**非系统名**。名字必须能塞进原字符串的字节数里
#   （原串 "libz.so.1" 占 10 字节含 NUL ⇒ 新名 ≤ 9 字符）。
$CollisionRename = [ordered]@{
    'libz.so' = 'libzh.so'   # h = heracles；8 字符 + NUL = 9 ≤ 10 ✓
}

# bin/ 下的可执行要改成 lib*.so 形态（AGP 要求）
$BinToLib = [ordered]@{
    'aapt2' = 'libaapt2.so'
    'zip'   = 'libzip.so'
}

function Get-DynInfo([string]$path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 64 -or $b[0] -ne 0x7F -or $b[4] -ne 2) { return $null }
    $e_shoff = [BitConverter]::ToUInt64($b, 0x28)
    $e_shentsize = [BitConverter]::ToUInt16($b, 0x3A)
    $e_shnum = [BitConverter]::ToUInt16($b, 0x3C)
    if ($e_shnum -eq 0) { return $null }
    $secs = @()
    for ($i = 0; $i -lt $e_shnum; $i++) {
        $o = $e_shoff + $i * $e_shentsize
        $secs += [pscustomobject]@{
            type = [BitConverter]::ToUInt32($b, $o + 4)
            off  = [BitConverter]::ToUInt64($b, $o + 0x18)
            size = [BitConverter]::ToUInt64($b, $o + 0x20)
            link = [BitConverter]::ToUInt32($b, $o + 0x28)
        }
    }
    $dyn = $secs | Where-Object { $_.type -eq 6 } | Select-Object -First 1
    if (-not $dyn) { return $null }
    $dynstr = $secs[$dyn.link]
    return [pscustomobject]@{ Bytes = $b; Dyn = $dyn; DynStr = $dynstr }
}

# 收集一个 ELF 里所有 DT_NEEDED 的（字符串, 在文件里的偏移）
function Get-NeededEntries([string]$path) {
    $info = Get-DynInfo $path
    if (-not $info) { return @() }
    $b = $info.Bytes
    $res = @()
    for ($k = 0; $k -lt [int]($info.Dyn.size / 16); $k++) {
        $o = $info.Dyn.off + $k * 16
        $tag = [BitConverter]::ToInt64($b, $o)
        $val = [BitConverter]::ToUInt64($b, $o + 8)
        if ($tag -eq 1) {
            $s = $info.DynStr.off + $val
            $e = $s
            while ($b[$e] -ne 0) { $e++ }
            $res += [pscustomobject]@{
                Name   = [System.Text.Encoding]::ASCII.GetString($b, $s, $e - $s)
                Offset = [int]$s
                Length = [int]($e - $s)
            }
        }
    }
    return $res
}

function Write-Step([string]$t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t)   { Write-Host "    OK   $t" -ForegroundColor Green }
function Write-Info([string]$t) { Write-Host "    ·    $t" }
function Write-Warn2([string]$t){ Write-Host "    WARN $t" -ForegroundColor Yellow }

if (-not (Test-Path $AssetsDir)) { throw "找不到 assets 工具链目录：$AssetsDir（先跑 tools/fetch-toolchain.ps1）" }
if (-not $Verify -and -not (Test-Path $JniLibsDir)) { New-Item -ItemType Directory -Force -Path $JniLibsDir | Out-Null }

# ============================================================================
Write-Step "扫描需要打补丁的 DT_NEEDED"
# ============================================================================
$toPatch = @()   # (源文件, 目标文件, 需要替换的名字列表)
foreach ($bin in $BinToLib.Keys) {
    $src = Join-Path $AssetsDir "bin\$bin"
    if (-not (Test-Path $src)) { throw "缺少 $src" }
    $needed = Get-NeededEntries $src
    $hits = @($needed | Where-Object { $RenameMap.Contains($_.Name) -or $CollisionRename.Contains($_.Name) } | ForEach-Object { $_.Name })
    Write-Info ("bin/{0,-10} 需要补丁：{1}" -f $bin, $(if ($hits.Count) { $hits -join ', ' } else { '（无）' }))
    $toPatch += [pscustomobject]@{ Src = $src; Dst = (Join-Path $JniLibsDir $BinToLib[$bin]); Patch = $hits }
}

$libFiles = Get-ChildItem (Join-Path $AssetsDir 'lib') -File -ErrorAction SilentlyContinue
foreach ($lf in $libFiles) {
    $needed = Get-NeededEntries $lf.FullName
    $hits = @($needed | Where-Object { $RenameMap.Contains($_.Name) -or $CollisionRename.Contains($_.Name) } | ForEach-Object { $_.Name })
    if ($hits.Count -eq 0) { continue }
    # 目标名：库文件本身如果带版本号也要改名
    $dstName = $lf.Name
    foreach ($k in $RenameMap.Keys) { if ($lf.Name -eq $k) { $dstName = $RenameMap[$k] } }
    Write-Info ("lib/{0,-34} 需要补丁：{1}" -f $lf.Name, ($hits -join ', '))
    $toPatch += [pscustomobject]@{ Src = $lf.FullName; Dst = (Join-Path $JniLibsDir $dstName); Patch = $hits }
}
Write-Ok ("共 {0} 个文件需要打补丁" -f $toPatch.Count)

# ============================================================================
Write-Step "就地补丁 DT_NEEDED（NUL 补齐，长度不变）"
# ============================================================================
foreach ($item in $toPatch) {
    $bytes = [System.IO.File]::ReadAllBytes($item.Src)
    $needed = Get-NeededEntries $item.Src
    foreach ($entry in $needed) {
        $newName = $null
        if ($RenameMap.Contains($entry.Name)) { $newName = $RenameMap[$entry.Name] }
        elseif ($CollisionRename.Contains($entry.Name)) { $newName = $CollisionRename[$entry.Name] }
        else { continue }
        if ($newName.Length -gt $entry.Length) {
            throw "新名字比原名长，无法 NUL 补齐：$($entry.Name) → $newName"
        }
        $newBytes = [System.Text.Encoding]::ASCII.GetBytes($newName)
        for ($i = 0; $i -lt $entry.Length; $i++) {
            $bytes[$entry.Offset + $i] = if ($i -lt $newBytes.Length) { $newBytes[$i] } else { 0 }
        }
        Write-Info ("{0}: {1} → {2} (NUL 补齐 {3} 字节)" -f (Split-Path $item.Src -Leaf), $entry.Name, $newName, ($entry.Length - $newBytes.Length))
    }
    if (-not $Verify) {
        [System.IO.File]::WriteAllBytes($item.Dst, $bytes)
    }
}

# ============================================================================
Write-Step "复制无需补丁的库 + 改名"
# ============================================================================
if (-not $Verify) {
    foreach ($lf in $libFiles) {
        $dstName = $lf.Name
        foreach ($k in $RenameMap.Keys) { if ($lf.Name -eq $k) { $dstName = $RenameMap[$k] } }
        $dst = Join-Path $JniLibsDir $dstName
        if (Test-Path $dst) { continue }   # 已由补丁路径写过
        Copy-Item $lf.FullName $dst -Force
    }
    Write-Ok ("jniLibs 目录现有 {0} 个文件" -f (Get-ChildItem $JniLibsDir -File).Count)
}


# ============================================================================
Write-Step "第二遍：把 libz.so 改成非系统名（避开 Android 公共库抢占）"
# ============================================================================
# 必须**单独一遍**：第一遍把 libz.so.1 改成了 libz.so，如果同轮再改 libz.so，
# 顺序会打架（替换后的字符串匹配不到原表）。所以这里对**已落盘**的 jniLibs
# 再做一次扫描改写。
if (-not $Verify) {
    $changed = 0
    foreach ($jf in (Get-ChildItem $JniLibsDir -File | Where-Object { $_.Name -ne $null })) {
        $bytes = [System.IO.File]::ReadAllBytes($jf.FullName)
        if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x7F) { continue }
        $entries = Get-NeededEntries $jf.FullName
        $hit = $false
        foreach ($entry in $entries) {
            if (-not $CollisionRename.Contains($entry.Name)) { continue }
            $newName = $CollisionRename[$entry.Name]
            # 容量说明：`$entry.Length` 是**当前**字符串长度（不含 NUL）。
            # 但这一遍改的名字是上一遍缩短过的（libz.so.1 10 字节 → libz.so 7 字节），
            # 所以还留有 ≥2 个空 NUL 可用。允许 +2 个字符。
            if ($newName.Length -gt ($entry.Length + 2)) {
                throw "新名字过长：$($entry.Name)（$($entry.Length) 字符）→ $newName（$($newName.Length) 字符）"
            }
            $nb = [System.Text.Encoding]::ASCII.GetBytes($newName)
            # ★ 必须写到 `新名长度`（而不是旧长度），否则新名比旧名长时会被**截断**。
            #   踩过的坑：libz.so(7) → libzh.so(8)，按旧长度 7 写只剩 "libzh.s"，
            #   链接器报「需要 libzh.s」。
            $capacity = $entry.Length + 2
            for ($i = 0; $i -lt $capacity; $i++) {
                $bytes[$entry.Offset + $i] = if ($i -lt $nb.Length) { $nb[$i] } else { 0 }
            }
            Write-Info ("{0}: {1} → {2}" -f $jf.Name, $entry.Name, $newName)
            $hit = $true
        }
        if ($hit) { [System.IO.File]::WriteAllBytes($jf.FullName, $bytes); $changed++ }
    }
    # 库文件自身改名
    foreach ($k in $CollisionRename.Keys) {
        $src = Join-Path $JniLibsDir $k
        if (Test-Path $src) {
            Move-Item $src (Join-Path $JniLibsDir $CollisionRename[$k]) -Force
            Write-Info ("库文件名：{0} → {1}" -f $k, $CollisionRename[$k])
            $changed++
        }
    }
    Write-Ok ("第二遍改动 {0} 处" -f $changed)
}
# ============================================================================
Write-Step "第三遍：修补 SONAME（必须在改名之后，因为要匹配最终文件名）"
# ============================================================================
# 真机报错：`cannot find "libzh.so" from verneed[0] in DT_NEEDED list for libpng16.so`
# 而 libpng16 的 DT_NEEDED 明明就是 libzh.so、文件也确实在。
#
# 根因：bionic 解析 **verneed（符号版本需求）** 时，是拿 **SONAME** 去匹配的。
# 我们只改了**文件名**和 DT_NEEDED 字符串，库内部的 `DT_SONAME` 还是旧值：
#     libzh.so     SONAME = libz.so.1        ← 对不上 verneed 里的 "libzh.so"
#     libexpat.so  SONAME = libexpat.so.1
#     libbz2.so    SONAME = libbz2.so.1.0
# ⇒ 必须把 DT_SONAME 一起改掉。
#
# RenameMap(去版本号) + CollisionRename(避系统库) 两轮的最终名都要正确。
if (-not $Verify) {
    $sonameFixed = 0
    foreach ($jf in (Get-ChildItem $JniLibsDir -File)) {
        if ($jf.Name -notmatch '^lib') { continue }
        $bytes = [System.IO.File]::ReadAllBytes($jf.FullName)
        if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x7F) { continue }

        # 本文件**应该**的 SONAME = 文件名去掉 .so 后缀再补回（即文件名本身）
        $expected = $jf.Name

        # 定位 DT_SONAME (tag 14)
        $e_shoff = [BitConverter]::ToUInt64($bytes, 0x28)
        $e_shentsize = [BitConverter]::ToUInt16($bytes, 0x3A)
        $e_shnum = [BitConverter]::ToUInt16($bytes, 0x3C)
        if ($e_shnum -eq 0) { continue }
        $secs = @()
        for ($i = 0; $i -lt $e_shnum; $i++) {
            $o = $e_shoff + $i * $e_shentsize
            $secs += [pscustomobject]@{
                type = [BitConverter]::ToUInt32($bytes, $o + 4)
                off  = [BitConverter]::ToUInt64($bytes, $o + 0x18)
                size = [BitConverter]::ToUInt64($bytes, $o + 0x20)
                link = [BitConverter]::ToUInt32($bytes, $o + 0x28)
            }
        }
        $dyn = $secs | Where-Object { $_.type -eq 6 } | Select-Object -First 1
        if (-not $dyn) { continue }
        $dynstr = $secs[$dyn.link]

        for ($k = 0; $k -lt [int]($dyn.size / 16); $k++) {
            $o = $dyn.off + $k * 16
            $tag = [BitConverter]::ToInt64($bytes, $o)
            if ($tag -ne 14) { continue }   # DT_SONAME
            $val = [BitConverter]::ToUInt64($bytes, $o + 8)
            $s = [int]($dynstr.off + $val)
            $e = $s
            while ($bytes[$e] -ne 0) { $e++ }
            $cur = [System.Text.Encoding]::ASCII.GetString($bytes, $s, $e - $s)
            if ($cur -eq $expected) { break }   # 已经对
            if ($expected.Length -gt $cur.Length) {
                Write-Warn2 ("{0}: SONAME '{1}' 短于文件名 '{2}'，无法就地改（跳过）" -f $jf.Name, $cur, $expected)
                break
            }
            $nb = [System.Text.Encoding]::ASCII.GetBytes($expected)
            for ($i = 0; $i -lt $cur.Length; $i++) {
                $bytes[$s + $i] = if ($i -lt $nb.Length) { $nb[$i] } else { 0 }
            }
            [System.IO.File]::WriteAllBytes($jf.FullName, $bytes)
            Write-Info ("{0}: SONAME '{1}' → '{2}'" -f $jf.Name, $cur, $expected)
            $sonameFixed++
            break
        }
    }
    Write-Ok ("SONAME 修补 {0} 处" -f $sonameFixed)
}
# ============================================================================
Write-Step "校验结果"
# ============================================================================
$bad = @()
foreach ($name in @('libaapt2.so', 'libzip.so')) {
    $p = Join-Path $JniLibsDir $name
    if (-not (Test-Path $p)) { $bad += "$name 不存在"; continue }
    $needed = Get-NeededEntries $p
    $versioned = @($needed | Where-Object { $_.Name -match '\.so\.\d' })
    if ($versioned.Count -gt 0) {
        $bad += ("{0} 仍有带版本号的 DT_NEEDED：{1}" -f $name, (($versioned | ForEach-Object { $_.Name }) -join ', '))
    } else {
        Write-Ok ("{0}：DT_NEEDED 全部无版本号（{1} 项）" -f $name, $needed.Count)
    }
    # 校验解释器还是 bionic（宿主侧运行需要）
    $b = [System.IO.File]::ReadAllBytes($p)
    $s = [System.Text.Encoding]::ASCII.GetString($b)
    if (-not $s.Contains('/system/bin/linker64')) { $bad += "$name 的解释器不是 /system/bin/linker64（宿主侧运行需要 bionic）" }
}

# 每个 DT_NEEDED 都要能在 jniLibs 里找到（排除系统库）
foreach ($name in @('libaapt2.so', 'libzip.so')) {
    $p = Join-Path $JniLibsDir $name
    if (-not (Test-Path $p)) { continue }
    foreach ($n in (Get-NeededEntries $p)) {
        if ($n.Name -match '^lib(c|m|dl|log|android)\.so$') { continue }   # 系统库
        if (-not (Test-Path (Join-Path $JniLibsDir $n.Name))) {
            $bad += ("{0} 需要 {1}，但 jniLibs 里没有" -f $name, $n.Name)
        }
    }
}

Write-Host ""
if ($bad.Count -eq 0) {
    Write-Ok "校验通过：宿主侧工具链已就绪"
    Write-Host ""
    Write-Info "下一步：运行期从 nativeLibraryDir exec 这些 lib*.so，"
    Write-Info "        并设 LD_LIBRARY_PATH=<nativeLibraryDir>"
    exit 0
} else {
    Write-Host "校验失败：" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
