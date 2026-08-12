param(
    [switch]$NoLto,
    [switch]$SkipPrepare
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

if (-not $SkipPrepare) {
    & (Join-Path $PSScriptRoot 'prepare-openmw-051-baseline.ps1')
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
$WindowsBuildScript = Join-Path $ProjectRoot 'tools\.openmw-051-baseline-build.sh'
$WslBuildScript = "$WslProject/tools/.openmw-051-baseline-build.sh"
$JniDir = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a'
$JniBackup = Join-Path $ProjectRoot 'tools\.openmw-051-baseline-jni-backup'

# Patch 1 is a native compile/link gate. Preserve the currently packaged 0.50
# JNI payload so nobody can accidentally assemble a mixed 0.50-assets/0.51-lib APK.
Remove-Item $JniBackup -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $JniDir) {
    Copy-Item $JniDir $JniBackup -Recurse
}

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

cd __BUILD_DIR__

CMAKE_VERSION="$(cmake --version | head -n1 | awk '{print $3}')"
if [ "$(printf '%s\n' 3.16 "$CMAKE_VERSION" | sort -V | head -n1)" != "3.16" ]; then
    echo "ERROR: OpenMW 0.51 Final requires CMake >= 3.16; found $CMAKE_VERSION" >&2
    exit 2
fi

echo "CMake $CMAKE_VERSION OK"
echo "OpenMW 0.51 Patch 1 baseline: native compile/link only"
echo "OpenMW 0.50 graphics/lifecycle/shadow/post-processing patches intentionally disabled"
echo "Dependency versions/prefixes intentionally kept unchanged for this gate"

# Always refresh only OpenMW so the 0.51 source and minimal patch chain are
# deterministic. Keep the known-working Android dependency prefixes unchanged.
rm -rf build/arm64/openmw-prefix

BUILD_LOG="$PWD/openmw-051-baseline-native-build.log"
rm -f "$BUILD_LOG"
echo "Native build log: $BUILD_LOG"

# A previous network failure can leave FreeType's generated download step in a
# partial state. Preserve completed dependency builds but remove stale temp data.
if [ -d build/arm64/freetype2-prefix/src/freetype2-stamp ]; then
    rm -f build/arm64/freetype2-prefix/src/freetype2-stamp/freetype2-download
fi
rm -f downloads/freetype-${FREETYPE2_VERSION:-2.13.2}.tar.gz.tmp 2>/dev/null || true

set +e
./build.sh --arch arm64 --no-resources __LTO_ARG__ 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "$BUILD_RC" -ne 0 ]; then
    echo
    echo "============================================================"
    echo "OpenMW 0.51 baseline native build FAILED (exit $BUILD_RC)"
    echo "Full log: $BUILD_LOG"
    echo "Likely root-cause lines:"
    echo "============================================================"
    grep -n -E -i \
        '(^|[^a-z])(fatal error:|error:|cmake error|undefined reference|cannot find|could not find|no rule to make target|FAILED:|ninja: build stopped|collect2: error|ld: error|make\[[0-9]+\]: \*\*\*)' \
        "$BUILD_LOG" | tail -n 180 || true
    exit "$BUILD_RC"
fi

SOURCE_CMAKE="build/arm64/openmw-prefix/src/openmw/CMakeLists.txt"
if [ ! -f "$SOURCE_CMAKE" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE_CMAKE"; then
    echo "ERROR: completed ExternalProject source is not OpenMW 0.51.x." >&2
    exit 21
fi

LIB=$(find build/arm64/openmw-prefix -iname libopenmw.so -print -quit 2>/dev/null || true)
if [ -z "$LIB" ] || [ ! -s "$LIB" ]; then
    echo "ERROR: OpenMW 0.51 baseline linked without a discoverable libopenmw.so." >&2
    exit 22
fi

OUT="$PWD/baseline-output/openmw-051"
mkdir -p "$OUT"
cp -f "$LIB" "$OUT/libopenmw.so"
printf '%s\n%s\n' \
    'OpenMW 0.51.0 Final baseline' \
    'commit=f4bec41444214a7903bebd178389ca22ca13f646' > "$OUT/openmw-engine-version.txt"
sha256sum "$OUT/libopenmw.so" > "$OUT/libopenmw.so.sha256"

echo
echo "OpenMW 0.51 baseline native build: SUCCESS"
echo "Staged library: $OUT/libopenmw.so"
cat "$OUT/libopenmw.so.sha256"
echo "No Android resources were deployed; this is intentionally NOT an APK-ready payload."
'@

$ShellScript = $ShellScript.Replace('__BUILD_DIR__', (Quote-Bash $BuildDir))
$ShellScript = $ShellScript.Replace('__LTO_ARG__', $LtoArg)
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsBuildScript, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'Building OpenMW 0.51.0 Final native baseline for arm64-v8a through WSL...' -ForegroundColor Cyan
Write-Host 'The currently packaged 0.50 JNI payload will be restored after the test build.' -ForegroundColor DarkGray

$NativeExitCode = 1
try {
    & wsl.exe --exec bash $WslBuildScript
    $NativeExitCode = $LASTEXITCODE
}
finally {
    Remove-Item $WindowsBuildScript -Force -ErrorAction SilentlyContinue

    # Restore the known 0.50 JNI payload even when the baseline build fails.
    if (Test-Path $JniBackup) {
        Remove-Item $JniDir -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item $JniBackup $JniDir -Recurse
        Remove-Item $JniBackup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($NativeExitCode -ne 0) { exit $NativeExitCode }

$OutputLib = Join-Path $ProjectRoot 'buildscripts\baseline-output\openmw-051\libopenmw.so'
if (-not (Test-Path $OutputLib)) {
    throw "OpenMW 0.51 baseline output library is missing: $OutputLib"
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 1 baseline passed the native compile/link gate.' -ForegroundColor Green
Write-Host "libopenmw.so SHA-256: $((Get-FileHash $OutputLib -Algorithm SHA256).Hash.ToLowerInvariant())"
Write-Host 'Current app JNI/resources were left on the 0.50 payload intentionally.'
Write-Host 'Next migration gate after this succeeds: Android lifecycle/basic rendering on 0.51.'
