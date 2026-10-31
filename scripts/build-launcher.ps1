# build-launcher.ps1 -- build a launcher APK with the vendor-whitelisted application id.
# ASCII only by design.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\build-launcher.ps1 -ProjectDir D:\src\app -LauncherId com.ts.launcher
#   powershell -ExecutionPolicy Bypass -File .\build-launcher.ps1 -ProjectDir D:\src\app -LauncherId com.ts.launcher -UseMirror

param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$LauncherId,
    [string]$Task = 'assembleRelease',
    [string]$GradleMirror = 'https://mirrors.cloud.tencent.com/gradle',
    [string]$GradleVersion = '8.9',
    [switch]$UseMirror,
    [switch]$NoDaemon
)

$ErrorActionPreference = 'Stop'
$ProjectDir = (Resolve-Path $ProjectDir).Path
Write-Host "[1/5] project: $ProjectDir"

# --- 1. local.properties / SDK ------------------------------------------------
$lp = Join-Path $ProjectDir 'local.properties'
if (-not (Test-Path $lp)) {
    $sdk = $env:ANDROID_HOME
    if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
    if (-not $sdk) {
        foreach ($c in @("$env:LOCALAPPDATA\Android\Sdk", 'D:\Android\sdk', 'C:\Android\sdk')) {
            if (Test-Path $c) { $sdk = $c; break }
        }
    }
    if (-not $sdk) { throw "Android SDK not found. Set ANDROID_HOME or create local.properties manually." }
    $esc = $sdk.Replace('\', '\\')
    [System.IO.File]::WriteAllText($lp, "sdk.dir=$esc`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "      wrote local.properties -> $sdk"
} else {
    Write-Host "      local.properties present"
}

# --- 2. gradle wrapper mirror -------------------------------------------------
if ($UseMirror) {
    $wp = Join-Path $ProjectDir 'gradle\wrapper\gradle-wrapper.properties'
    if (Test-Path $wp) {
        $content = Get-Content $wp -Raw
        $newUrl = "$GradleMirror/gradle-$GradleVersion-bin.zip"
        $content = [regex]::Replace($content, 'distributionUrl=.*', "distributionUrl=$($newUrl.Replace('\','\\'))")
        [System.IO.File]::WriteAllText($wp, $content, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[2/5] wrapper -> $newUrl"
    } else {
        Write-Host "[2/5] WARN no gradle-wrapper.properties, mirror skipped"
    }
} else {
    Write-Host "[2/5] mirror disabled (pass -UseMirror for throttled networks)"
}

# --- 3. build -----------------------------------------------------------------
Write-Host "[3/5] gradlew $Task -PlauncherApplicationId=$LauncherId"
$gw = Join-Path $ProjectDir 'gradlew.bat'
if (-not (Test-Path $gw)) { throw "gradlew.bat missing in $ProjectDir" }

$gradleArgs = @($Task, "-PlauncherApplicationId=$LauncherId")
if ($NoDaemon) { $gradleArgs += '--no-daemon' }

Push-Location $ProjectDir
try {
    & $gw @gradleArgs 2>&1 | Tee-Object -Variable buildLog | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -ne 0) {
    Write-Host ""
    Write-Host "BUILD FAILED (exit $code). Frequent causes:"
    Write-Host "  - INSTALL/compile error on an API gate -> run :app:lintRelease and fix NewApi items"
    Write-Host "  - dependency download timeout         -> retry with -UseMirror"
    Write-Host "  - missing SDK platform for minSdk      -> install it in SDK Manager"
    exit $code
}

# --- 4. locate artifact -------------------------------------------------------
$outRoot = Join-Path $ProjectDir "app\build\outputs\apk\release"
$apk = Get-ChildItem $outRoot -Filter *.apk -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apk) {
    $apk = Get-ChildItem (Join-Path $ProjectDir 'app\build\outputs') -Recurse -Filter *.apk -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if (-not $apk) { throw "Build succeeded but no APK found under app\build\outputs." }

$sizeKb = [math]::Round($apk.Length / 1KB, 1)
Write-Host "[4/5] artifact: $($apk.FullName) ($sizeKb KB)"

# --- 5. verify the application id actually got rewritten ----------------------
$aapt = $null
$sdkRoot = $env:ANDROID_HOME; if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
if ($sdkRoot) {
    $cand = Get-ChildItem (Join-Path $sdkRoot 'build-tools') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($cand) { $a = Join-Path $cand.FullName 'aapt.exe'; if (Test-Path $a) { $aapt = $a } }
}
$verified = $false
if ($aapt) {
    $pkgLine = & $aapt dump badging $apk.FullName 2>$null | Select-String -Pattern "^package:" | Select-Object -First 1
    if ($pkgLine) {
        Write-Host "[5/5] $($pkgLine.Line)"
        if ($pkgLine.Line -match [regex]::Escape("name='$LauncherId'")) { $verified = $true }
    }
}
if ($verified) {
    Write-Host "      applicationId verified: $LauncherId"
} else {
    Write-Host "      WARN could not verify applicationId (aapt missing?). Check app/build.gradle reads -PlauncherApplicationId."
}

Write-Host ""
Write-Host "Next: .\install-apk.ps1 -TvIp <ip> -ApkPath `"$($apk.FullName)`""
