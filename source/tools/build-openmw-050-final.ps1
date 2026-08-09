param(
    [switch]$NoLto,
    [switch]$SkipPrepare
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = '47d78e004bc182def2904986f8bb54aea1f4b3ae'

if (-not $SkipPrepare) {
    & (Join-Path $PSScriptRoot 'prepare-openmw-050-final.ps1')
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required by the CaveBros native build scripts.'
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for this WSL build wrapper: $WindowsPath"
    }
    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$BuildDir = "$WslProject/buildscripts"
$LtoArg = if ($NoLto) { '' } else { '--lto' }
$WindowsBuildScript = Join-Path $ProjectRoot 'tools\.openmw-050-final-build.sh'
$WslBuildScript = "$WslProject/tools/.openmw-050-final-build.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

cd __BUILD_DIR__

CMAKE_VERSION="$(cmake --version | head -n1 | awk '{print $3}')"
if [ "$(printf '%s\n' 3.16 "$CMAKE_VERSION" | sort -V | head -n1)" != "3.16" ]; then
    echo "ERROR: OpenMW 0.50 Final requires CMake >= 3.16; found $CMAKE_VERSION" >&2
    exit 2
fi

echo "CMake $CMAKE_VERSION OK"

# OpenMW is always refreshed so the Android patch chain is deterministic.
# OSG is more expensive, so refresh it only when the installed source tree does
# not contain the GLES2 manual-shadow marker introduced by v14.6.2.
OSG_TEXTURE_CPP="build/arm64/osg-prefix/src/osg/src/osg/Texture.cpp"
if [ -d build/arm64/osg-prefix ] && { [ ! -f "$OSG_TEXTURE_CPP" ] || ! grep -Fq 'OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE' "$OSG_TEXTURE_CPP"; }; then
    echo "Refreshing OSG once for the Android GLES2 shadow-texture compatibility patch..."
    rm -rf build/arm64/osg-prefix
fi

rm -rf build/arm64/openmw-prefix

BUILD_LOG="$PWD/openmw-050-final-native-build.log"
rm -f "$BUILD_LOG"
echo "Native build log: $BUILD_LOG"

# A previous network failure can leave the ExternalProject download step in a
# partially generated state. Remove only FreeType's generated download stamp/
# temporary files; already completed dependency prefixes (Boost, etc.) remain.
if [ -d build/arm64/freetype2-prefix/src/freetype2-stamp ]; then
    rm -f build/arm64/freetype2-prefix/src/freetype2-stamp/freetype2-download
fi
rm -f downloads/freetype-${FREETYPE2_VERSION:-2.13.2}.tar.gz.tmp 2>/dev/null || true

set +e
./build.sh --arch arm64 __LTO_ARG__ 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "$BUILD_RC" -ne 0 ]; then
    echo
    echo "============================================================"
    echo "OpenMW 0.50 native build FAILED (exit $BUILD_RC)"
    echo "Full log: $BUILD_LOG"
    echo "Likely root-cause lines:"
    echo "============================================================"
    grep -n -E -i \
        '(^|[^a-z])(fatal error:|error:|cmake error|undefined reference|cannot find|could not find|no rule to make target|FAILED:|ninja: build stopped|collect2: error|ld: error|make\[[0-9]+\]: \*\*\*)' \
        "$BUILD_LOG" | tail -n 140 || true
    exit "$BUILD_RC"
fi
'@

$ShellScript = $ShellScript.Replace('__BUILD_DIR__', (Quote-Bash $BuildDir))
$ShellScript = $ShellScript.Replace('__LTO_ARG__', $LtoArg)
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsBuildScript, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'Building OpenMW 0.50.0 Final for arm64-v8a through WSL...' -ForegroundColor Cyan

$NativeExitCode = 1
try {
    & wsl.exe --exec bash $WslBuildScript
    $NativeExitCode = $LASTEXITCODE
}
finally {
    Remove-Item $WindowsBuildScript -Force -ErrorAction SilentlyContinue
}

if ($NativeExitCode -ne 0) { exit $NativeExitCode }

$FinalizeScript = Join-Path $PSScriptRoot 'finalize-openmw-050-payload.ps1'
if (-not (Test-Path $FinalizeScript)) {
    throw "OpenMW 0.50 payload finalizer is missing: $FinalizeScript"
}

& $FinalizeScript
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Lib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
Write-Host ''
Write-Host 'OpenMW 0.50.0 Final native payload built and finalized successfully.' -ForegroundColor Green
Write-Host "libopenmw.so SHA-256: $((Get-FileHash $Lib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Next: gradlew.bat :app:assembleMainlineDebug'
