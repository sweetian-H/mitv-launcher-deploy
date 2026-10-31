# inspect-device.ps1 -- one-shot recon for a Mi TV before any launcher change.
# ASCII only by design (PowerShell 5.1 misparses BOM-less non-ASCII .ps1).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\inspect-device.ps1 -TvIp 192.168.2.28
#   powershell -ExecutionPolicy Bypass -File .\inspect-device.ps1 -TvIp 192.168.2.28 -OutFile .\recon.md

param(
    [Parameter(Mandatory=$true)][string]$TvIp,
    [string]$AdbPath,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\AdbCommon.ps1"

$L = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$s) $L.Add($s); Write-Host $s }

Add-Line "# Mi TV recon - $TvIp"
Add-Line ""
Add-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line ""

Add-Line "## 1. Device"
$model = Get-Prop -TvIp $TvIp -Name 'ro.product.model' -AdbPath $AdbPath
$build = Get-Prop -TvIp $TvIp -Name 'ro.build.type' -AdbPath $AdbPath
$sdk   = Get-Prop -TvIp $TvIp -Name 'ro.build.version.sdk' -AdbPath $AdbPath
$rel   = Get-Prop -TvIp $TvIp -Name 'ro.build.version.release' -AdbPath $AdbPath
Add-Line "- model: $model"
Add-Line "- android: $rel (API $sdk)"
Add-Line "- build.type: $build"

if ($build -eq 'user') {
    Add-Line ""
    Add-Line "  VERDICT: user build -> pm disable-user / pm enable / pm hide WILL FAIL."
    Add-Line "           Use settings put / am force-stop / pm clear / pm uninstall (3rd-party only)."
} else {
    Add-Line ""
    Add-Line "  VERDICT: non-user build -> pm state changes may be permitted. Verify before use."
}

Add-Line ""
Add-Line "## 2. Root"
$su = Invoke-TvShell -TvIp $TvIp -Command 'ls /system/xbin/su /system/bin/su 2>/dev/null; which su 2>/dev/null' -AdbPath $AdbPath
if (($su | Out-String).Trim().Length -eq 0) {
    Add-Line "- su: NOT FOUND (no escalation path; every 'su -c' guide is inapplicable)"
} else {
    Add-Line "- su: $(($su | Out-String).Trim())"
}

Add-Line ""
Add-Line "## 3. Platform"
$aml = Invoke-TvShell -TvIp $TvIp -Command 'getprop | grep -i amlogic; getprop | grep -i droidlogic' -AdbPath $AdbPath
$pkglist = Invoke-TvShell -TvIp $TvIp -Command 'pm list packages' -AdbPath $AdbPath
$hasDroid = ($pkglist | Select-String -SimpleMatch 'com.droidlogic.tvinput').Count -gt 0
$hasMtk   = ($pkglist | Select-String -SimpleMatch 'com.mediatek.wwtv.tvcenter').Count -gt 0
if ($hasMtk) {
    Add-Line "- platform: MediaTek (com.mediatek.wwtv.tvcenter present)"
} elseif ($hasDroid -or (($aml | Out-String).Trim().Length -gt 0)) {
    Add-Line "- platform: Amlogic (com.droidlogic.tvinput / android.amlogic.*)"
} else {
    Add-Line "- platform: undetermined; use only dumpsys tv_input ids"
}

Add-Line ""
Add-Line "## 4. Home + launcher candidates"
$home = Invoke-TvShell -TvIp $TvIp -Command 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' -AdbPath $AdbPath
Add-Line "- current home:"
Add-Line ((($home | Out-String).Trim() -split "`r?`n" | Where-Object { $_ -match '\S' }) -join "`n")
$cands = Invoke-TvShell -TvIp $TvIp -Command 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME' -AdbPath $AdbPath
Add-Line "- candidates:"
Add-Line ((($cands | Out-String).Trim() -split "`r?`n" | Where-Object { $_ -match '\S' }) -join "`n")

Add-Line ""
Add-Line "## 5. TV inputs (TvInputManager registered tuners)"
$ti = Invoke-TvShell -TvIp $TvIp -Command 'dumpsys tv_input' -AdbPath $AdbPath
$hw = ($ti | Select-String -Pattern 'HW\d+|Hdmi\d+InputService|TvInputInfo\{' | ForEach-Object { $_.Line.Trim() })
if ($hw.Count -eq 0) {
    Add-Line "- no tuner lines parsed; run 'adb shell dumpsys tv_input' manually"
} else {
    foreach ($h in ($hw | Select-Object -Unique -First 30)) { Add-Line "- $h" }
}

Add-Line ""
Add-Line "## 6. Third-party packages"
$third = $pkglist | Select-String -SimpleMatch 'package:' | ForEach-Object { $_.Line.Trim().Replace('package:','') }
$sysPrefix = @('com.android.','android','com.google.','com.miui.','com.xiaomi.','com.mitv.','com.droidlogic.')
$nonSys = $third | Where-Object { $p = $_; -not ($sysPrefix | Where-Object { $p.StartsWith($_) }) }
Add-Line "- third-party candidates: $($nonSys.Count)"
foreach ($p in $nonSys) { Add-Line "  - $p" }

Add-Line ""
Add-Line "## 7. Storage"
$df = Invoke-TvShell -TvIp $TvIp -Command 'df /data' -AdbPath $AdbPath
Add-Line '```'
Add-Line ((($df | Out-String).Trim()) )
Add-Line '```'

Add-Line ""
Add-Line "## Next step"
Add-Line "Apply only the sections that match the verdicts above:"
Add-Line "- user build -> references/03-home-takeover.md (whitelist route, no pm)"
Add-Line "- API 23     -> references/02-api23-compat.md"
Add-Line "- HDMI gaps  -> references/04-input-sources.md"

Write-Report -Text ($L -join "`n") -OutFile $OutFile
