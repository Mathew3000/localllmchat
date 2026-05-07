#Requires -Version 5.1
<#
.SYNOPSIS
    Build the LoomChat Android APK and deploy it to a connected device.

.DESCRIPTION
    Runs 'flutter build apk --release' then 'flutter install --release'.
    Must be executed from the project root (where pubspec.yaml lives), or
    pass -ProjectRoot to point at it explicitly.

.PARAMETER ProjectRoot
    Path to the Flutter project root.  Defaults to the directory containing
    this script.

.PARAMETER BuildOnly
    Build the APK but skip the install step.

.PARAMETER InstallOnly
    Skip the build step and install the most recently built APK.

.EXAMPLE
    .\build-and-deploy-android.ps1
    .\build-and-deploy-android.ps1 -BuildOnly
    .\build-and-deploy-android.ps1 -InstallOnly
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot,
    [switch]$BuildOnly,
    [switch]$InstallOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Ensure ANDROID_HOME is visible in this process ────────────────────────────
# User-level env vars set after the terminal opened won't be inherited yet.
# Read them directly from the registry as a fallback.
if (-not $env:ANDROID_HOME) {
    $userEnv = [Environment]::GetEnvironmentVariable("ANDROID_HOME", "User")
    if ($userEnv) {
        $env:ANDROID_HOME     = $userEnv
        $env:ANDROID_SDK_ROOT = $userEnv
        $platformTools = Join-Path $userEnv 'platform-tools'
        if ((Test-Path $platformTools) -and $env:PATH -notlike "*platform-tools*") {
            $env:PATH += ";$platformTools"
        }
    }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "  >> $msg" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success([string]$msg) {
    Write-Host "  OK  $msg" -ForegroundColor Green
}

function Write-Fail([string]$msg) {
    Write-Host ""
    Write-Host "  FAIL  $msg" -ForegroundColor Red
    Write-Host ""
}

# ── Validate project root ─────────────────────────────────────────────────────

if (-not (Test-Path (Join-Path $ProjectRoot 'pubspec.yaml'))) {
    Write-Fail "pubspec.yaml not found in '$ProjectRoot'. Run the script from the project root or use -ProjectRoot."
    exit 1
}

Push-Location $ProjectRoot

try {
    $apk = Join-Path $ProjectRoot 'build\app\outputs\flutter-apk\app-release.apk'

    # ── Build ─────────────────────────────────────────────────────────────────

    if (-not $InstallOnly) {
        Write-Step "Building release APK..."
        flutter build apk --release
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "flutter build apk --release failed (exit $LASTEXITCODE)."
            exit $LASTEXITCODE
        }
        $size = [math]::Round((Get-Item $apk).Length / 1MB, 1)
        Write-Success "APK built  ->  build\app\outputs\flutter-apk\app-release.apk  ($size MB)"
    }

    # ── Install ───────────────────────────────────────────────────────────────

    if (-not $BuildOnly) {
        if (-not (Test-Path $apk)) {
            Write-Fail "APK not found at '$apk'. Build it first (remove -InstallOnly)."
            exit 1
        }

        Write-Step "Installing APK on connected device..."
        flutter install --release
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "flutter install --release failed (exit $LASTEXITCODE)."
            exit $LASTEXITCODE
        }
        Write-Success "APK installed."
    }

    Write-Host ""
    Write-Host "  Done." -ForegroundColor Green
    Write-Host ""

} finally {
    Pop-Location
}
