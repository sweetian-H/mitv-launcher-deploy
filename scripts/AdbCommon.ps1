# AdbCommon.ps1 -- shared helpers. ASCII only by design.
# Dot-source from sibling scripts:  . "$PSScriptRoot\AdbCommon.ps1"

$script:DefaultPort = 5555

function Resolve-Adb {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
        throw "adb not found at: $Explicit"
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @()
    if ($env:ANDROID_HOME)      { $candidates += (Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe') }
    if ($env:ANDROID_SDK_ROOT)  { $candidates += (Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe') }
    $candidates += "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    $candidates += "D:\Android\sdk\platform-tools\adb.exe"
    $candidates += "C:\Android\sdk\platform-tools\adb.exe"
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    throw "adb not found. Install platform-tools or pass -AdbPath."
}

function Connect-Tv {
    param(
        [Parameter(Mandatory=$true)][string]$TvIp,
        [string]$AdbPath,
        [int]$TimeoutSec = 15
    )
    $adb = Resolve-Adb -Explicit $AdbPath
    $serial = "$TvIp`:$script:DefaultPort"
    & $adb connect $serial | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $out = & $adb devices 2>$null
        foreach ($line in $out) {
            if ($line -match [regex]::Escape($serial) + '\s+device') { return $serial }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Device $serial did not reach state 'device'. Enable ADB debugging on the TV and retry."
}

function Invoke-TvShell {
    param(
        [Parameter(Mandatory=$true)][string]$TvIp,
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$AdbPath
    )
    $serial = Connect-Tv -TvIp $TvIp -AdbPath $AdbPath
    $adb = Resolve-Adb -Explicit $AdbPath
    # adb shell joins remaining args, so pass the command as one token
    return (& $adb -s $serial shell $Command 2>&1)
}

function Send-Key {
    param(
        [Parameter(Mandatory=$true)][string]$TvIp,
        [Parameter(Mandatory=$true)][int[]]$KeyCode,
        [string]$AdbPath,
        [int]$GapMs = 400
    )
    foreach ($k in $KeyCode) {
        Invoke-TvShell -TvIp $TvIp -Command "input keyevent $k" -AdbPath $AdbPath | Out-Null
        if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
    }
}

function Get-Prop {
    param([string]$TvIp, [string]$Name, [string]$AdbPath)
    $v = Invoke-TvShell -TvIp $TvIp -Command "getprop $Name" -AdbPath $AdbPath
    return (($v | Out-String).Trim())
}

function Write-Report {
    param(
        [string]$Text,
        [string]$OutFile
    )
    if ($OutFile) {
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($OutFile, $Text, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output "Report written to $OutFile"
    } else {
        Write-Output $Text
    }
}
