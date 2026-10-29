# 兼容 Windows PowerShell 5.1（本机没有 pwsh）
# Copyright (C) 2026 Heracles-taixu-sandbox contributors
# SPDX-License-Identifier: GPL-3.0
#
# 能力宣称核对器 —— 防止文档说假话
# =====================================================================
# 为什么需要这个脚本（真实教训）：
#   本工程的 README 曾写「在 PRoot rootfs 里真跑 Linux 命令（gcc、aapt2、apt…）」，
#   security-boundary.md 曾写「apt、gcc、aapt2 都能跑」。
#   真机实测：这三样**全部不存在**（`command -v aapt2` → NONE）。
#
#   这不是打字错误，是**虚假宣传**：PRoot 只提供文件系统视图，不提供任何工具。
#   用户拿到手会发现"说的和做的不一样"。
#
#   光靠"以后注意"没用。这个脚本把「文档宣称的工具」与「内置 rootfs 里真实存在的工具」
#   做机械比对，说假话就报错。
#
# 用法：
#   pwsh tools/verify-claims.ps1              # 离线模式：只查内置 rootfs 资产里有什么
#   pwsh tools/verify-claims.ps1 -OnDevice    # 真机模式：直接问设备里的 rootfs
#
# 退出码：0 = 所有宣称都有依据；1 = 发现无依据的宣称

param(
    [switch]$OnDevice,
    [string]$DeviceSerial = "e35e48c6",
    [string]$AdbPath = "F:\Env\Android-SDK\Sdk\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RootfsAsset = Join-Path $RepoRoot "sandbox-runtime/src/main/assets/rootfs-bundle.bin"

# ---------------------------------------------------------------------------
# 1. 文档里被"宣称可用"的工具清单
# ---------------------------------------------------------------------------
# 这些是从 README / docs 里人工摘出来的**能力宣称**。
# 每一项都必须能在内置 rootfs 里找到对应命令，否则就是假话。
#
# 注意：这里只列「宣称内置可用」的。像「OCI 装了才有」的要在文档里显式写明前置条件，
# 不能算进这个表。
$ClaimsInDocs = @(
    # 来自 README「内置 rootfs 到底有什么」的"有"那一列
    @{ Tool = "sh";      Doc = "README: 内置 rootfs 有 sh";        Expect = $true  },
    @{ Tool = "ls";      Doc = "README: 内置 rootfs 有 ls";        Expect = $true  },
    @{ Tool = "cat";     Doc = "README: 内置 rootfs 有 cat";       Expect = $true  },
    @{ Tool = "cp";      Doc = "README: 内置 rootfs 有 cp";        Expect = $true  },
    @{ Tool = "rm";      Doc = "README: 内置 rootfs 有 rm";        Expect = $true  },
    @{ Tool = "grep";    Doc = "README: 内置 rootfs 有 grep";      Expect = $true  },
    @{ Tool = "sed";     Doc = "README: 内置 rootfs 有 sed";       Expect = $true  },
    @{ Tool = "tar";     Doc = "README: 内置 rootfs 有 tar";       Expect = $true  },
    @{ Tool = "gzip";    Doc = "README: 内置 rootfs 有 gzip";      Expect = $true  },
    @{ Tool = "unzip";   Doc = "README: 内置 rootfs 有 unzip";     Expect = $true  },
    @{ Tool = "wget";    Doc = "README: 内置 rootfs 有 wget";      Expect = $true  },
    @{ Tool = "apk";     Doc = "README: 内置 rootfs 有 apk";       Expect = $true  },

    # 来自 README「没有」那一列 —— 这些**反而不许出现**，否则文档又错了
    @{ Tool = "gcc";       Doc = "README: 内置 rootfs **没有** gcc";       Expect = $false },
    @{ Tool = "make";      Doc = "README: 内置 rootfs **没有** make";      Expect = $false },
    @{ Tool = "python3";   Doc = "README: 内置 rootfs **没有** python3";   Expect = $false },
    @{ Tool = "git";       Doc = "README: 内置 rootfs **没有** git";       Expect = $false },
    @{ Tool = "java";      Doc = "README: 内置 rootfs **没有** java";      Expect = $false },
    @{ Tool = "zip";       Doc = "README: 内置 rootfs **没有** zip";       Expect = $false },
    @{ Tool = "aapt2";     Doc = "README: 内置 rootfs **没有** aapt2";     Expect = $false },
    @{ Tool = "apksigner"; Doc = "README: 内置 rootfs **没有** apksigner"; Expect = $false },
    @{ Tool = "zipalign";  Doc = "README: 内置 rootfs **没有** zipalign";  Expect = $false },
    @{ Tool = "apt";       Doc = "README: 内置 rootfs **没有** apt";       Expect = $false }
)

# ---------------------------------------------------------------------------
# 2. 取得 rootfs 里的工具清单
# ---------------------------------------------------------------------------

function Get-ToolsFromAsset {
    param([string]$AssetPath)

    if (-not (Test-Path $AssetPath)) {
        throw "内置 rootfs 资产不存在：$AssetPath（构建会失败，先修这个）"
    }

    Write-Host "→ 从资产读取工具清单：$AssetPath" -ForegroundColor Cyan

    # 用系统 tar 列出条目（bsdtar 支持 gz）
    $entries = & tar -tzf $AssetPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "无法列出 rootfs 资产内容（tar 失败）"
    }

    # 工具所在的目录；收集所有"可执行文件名"（basename）
    $dirs = @("bin/", "sbin/", "usr/bin/", "usr/sbin/")
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($e in $entries) {
        $normalized = $e -replace '^\./', ''
        foreach ($d in $dirs) {
            if ($normalized.StartsWith($d) -and -not $normalized.EndsWith("/")) {
                $rest = $normalized.Substring($d.Length)
                if ($rest -notmatch "/") {
                    # 只有一层（bin/sh、bin/busybox），取文件名
                    [void]$names.Add($rest)
                }
            }
        }
    }
    Write-Host ("  找到 {0} 个命令条目" -f $names.Count)
    return $names
}

function Get-ToolsFromDevice {
    param([string]$Serial, [string]$Adb)

    if (-not (Test-Path $Adb)) { throw "adb 不存在：$Adb" }
    Write-Host "→ 真机查询 rootfs 里的命令（设备 $Serial）" -ForegroundColor Cyan

    $probe = "for t in sh ls cat cp mv rm grep sed awk tar gzip unzip wget " +
             "apk gcc cc clang make python3 git java zip aapt2 apksigner zipalign apt; " +
             "do command -v `$t >/dev/null 2>&1 && echo HAVE:`$t; done"

    $raw = & $Adb -s $Serial shell "run-as com.heracles.sandbox.demo sh -c '$probe'" 2>&1
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in $raw) {
        $s = ($line | Out-String).Trim()
        if ($s.StartsWith("HAVE:")) { [void]$names.Add($s.Substring(5)) }
    }
    Write-Host ("  设备上可用命令 {0} 个" -f $names.Count)
    return $names
}

# ---------------------------------------------------------------------------
# 3. 比对
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "==== 能力宣称核对 ====" -ForegroundColor Yellow
Write-Host ""

$available = if ($OnDevice) {
    Get-ToolsFromDevice -Serial $DeviceSerial -Adb $AdbPath
} else {
    Get-ToolsFromAsset -AssetPath $RootfsAsset
}

$failures = @()
foreach ($claim in $ClaimsInDocs) {
    $tool = $claim.Tool
    $present = $available.Contains($tool)
    $ok = ($present -eq $claim.Expect)

    if ($ok) {
        $mark = if ($claim.Expect) { "OK  有" } else { "OK  无" }
        Write-Host ("  [{0}] {1,-10} {2}" -f $mark, $tool, $claim.Doc) -ForegroundColor DarkGray
    } else {
        $actual = if ($present) { "存在" } else { "不存在" }
        $wanted = if ($claim.Expect) { "存在" } else { "不存在" }
        Write-Host ("  [FAIL] {0,-10} 文档说「{1}」，实际「{2}」" -f $tool, $wanted, $actual) -ForegroundColor Red
        $failures += "$tool —— $($claim.Doc)（实际：$actual）"
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "✓ 所有文档宣称都与 rootfs 实况一致（共 $($ClaimsInDocs.Count) 项）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "✗ 发现 $($failures.Count) 处**没有依据的宣称**（这就是假话）：" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "    - $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "修法：要么改文档（承认没有），要么真的把工具放进 rootfs（并在构建期校验）。" -ForegroundColor Yellow
    Write-Host "**不要**把文档改成「大概能用」这种模糊说法 —— 那样等于继续骗人。" -ForegroundColor Yellow
    exit 1
}
