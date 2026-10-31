# install-apk.ps1 -- install an APK and drive the MIUI full-screen confirmation dialog.
# ASCII only by design.
#
# Why: on MIUI-TV, `adb install` blocks while a system dialog waits for a remote press.
# The dialog also carries an "Apply to all" checkbox that is often pre-focused; a blind OK
# toggles it off and cancels the install. This script presses DOWN first.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\install-apk.ps1 -TvIp 192.168.2.28 -ApkPath .\app-release.apk
#   powershell -ExecutionPolicy Bypass -File .\install-apk.ps1 -TvIp 192.168.2.28 -ApkPath .\app-release.apk -UninstallFirst

param(
    [Parameter(Mandatory=$true)][string]$TvIp,
    [Parameter(Mandatory=$true)][string]$ApkPath,
    [string]$AdbPath,
    [string]$ExpectedPackage,
    [switch]$UninstallFirst,
    [switch]$NoDialogDrive
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\AdbCommon.ps1"

if (-not (Test-Path $ApkPath)) { throw "APK not found: $ApkPath" }
$apk = (Resolve-Path $ApkPath).Path
$serial = Connect-Tv -TvIp $TvIp -AdbPath $AdbPath
$adb = Resolve-Adb -Explicit $AdbPath
Write-Host "device: $serial"
Write-Host "apk   : $apk ($([math]::Round((Get-Item $apk).Length/1KB,1)) KB)"

if ($UninstallFirst) {
    $pkg = $ExpectedPackage
    if (-not $pkg) {
        if ($apk -match 'app-([A-Za-z0-9_.]+)\.apk') { $pkg = $Matches[1] }
    }
    if ($pkg) {
        Write-Host "uninstalling $pkg ..."
        & $adb -s $serial uninstall $pkg 2>&1 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "WARN -UninstallFirst without -ExpectedPackage: skipped"
    }
}

# Run the install in a job so the main thread can press keys while it blocks.
$job = Start-Job -ScriptBlock {
    param($adbExe, $ser, $path)
    & $adbExe -s $ser install -r $path 2>&1
} -ArgumentList $adb, $serial, $apk

if (-not $NoDialogDrive) {
    Start-Sleep -Seconds 6
    Write-Host "driving installer dialog: DOWN, OK"
    # 20 = KEYCODE_DPAD_DOWN (leave the 'apply to all' checkbox), 23 = KEYCODE_DPAD_CENTER
    for ($i = 0; $i -lt 3; $i++) {
        Send-Key -TvIp $TvIp -KeyCode @(20, 23) -AdbPath $AdbPath -GapMs 700
        Start-Sleep -Milliseconds 800
        if ($job.State -ne 'Running') { break }
    }
}

$deadline = (Get-Date).AddMinutes(2)
while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
$result = Receive-Job $job 2>&1
$state = $job.State
Remove-Job $job -Force

Write-Host "--- adb output ---"
$result | ForEach-Object { Write-Host $_ }

$ok = ($result | Out-String) -match 'Success'
if (-not $ok) {
    Write-Host ""
    Write-Host "INSTALL NOT CONFIRMED (job state: $state)."
    Write-Host "Manual recovery: watch the TV and run"
    Write-Host "  adb -s $serial shell input keyevent 20"
    Write-Host "  adb -s $serial shell input keyevent 23"
    exit 1
}

# Verify by path lookup rather than trusting the string match alone.
if ($ExpectedPackage) {
    $p = Invoke-TvShell -TvIp $TvIp -Command "pm path $ExpectedPackage" -AdbPath $AdbPath
    $line = (($p | Out-String).Trim())
    if ($line -match 'package:') {
        Write-Host "verified installed: $ExpectedPackage -> $line"
    } else {
        Write-Host "WARN install reported success but pm path returned nothing for $ExpectedPackage"
        Write-Host "     (package id may differ from the expected value)"
    }
}

Write-Host ""
Write-Host "Next: take over HOME via the chooser (references/03-home-takeover.md)"
Write-Host "  adb -s $serial shell input keyevent 3"
