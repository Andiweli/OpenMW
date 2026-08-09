param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = '47d78e004bc182def2904986f8bb54aea1f4b3ae'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required.'
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported Windows path: $WindowsPath"
    }

    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2]

    if ([string]::IsNullOrWhiteSpace($rest)) {
        return "/mnt/$drive"
    }

    return "/mnt/$drive/" + (($rest -replace '\\', '/').TrimStart('/'))
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

# IMPORTANT:
# openmw-prefix/src/openmw is created by the ExternalProject build under WSL.
# On /mnt/<drive> it may be a Unix symlink that is perfectly valid inside WSL
# but Windows PowerShell Test-Path can report as missing. Therefore v14.4.1
# intentionally validates the native source/build directories inside WSL.
$SourceWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$DiagPatcherWin = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final\apply-omwfx050-diagnostics.py'
$MarkerWin = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'

# These are ordinary project files and should be visible to Windows.
foreach ($Required in @($DiagPatcherWin, $MarkerWin)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Required OpenMW 0.50 diagnostic/payload file is missing: $Required"
    }
}

$MarkerText = [IO.File]::ReadAllText($MarkerWin).Replace("`r`n", "`n")
if (-not $MarkerText.Contains('OpenMW 0.50.0 Final') -or
    -not $MarkerText.Contains($FinalCommit)) {
    throw 'The Android payload marker is not OpenMW 0.50.0 Final. Refusing to package a diagnostic library into another engine baseline.'
}

$Project = Convert-WindowsPathToWsl $ProjectRoot
$Source = Convert-WindowsPathToWsl $SourceWin
$Build = Convert-WindowsPathToWsl $BuildWin
$DiagPatcher = Convert-WindowsPathToWsl $DiagPatcherWin

$TempWin = Join-Path $ProjectRoot 'tools\.openmw-050-omwfx-diagnostic-rebuild.sh'
$TempWsl = "$Project/tools/.openmw-050-omwfx-diagnostic-rebuild.sh"

$Script = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
SOURCE_DIR=__SOURCE__
BUILD_DIR=__BUILD__
DIAG_PATCHER=__DIAG_PATCHER__

STARTUP_MARKER='Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '
DIAG_MARKER='OMWFX050-DIAG: loadChain configuredCount='

echo 'OpenMW 0.50 OMWFX diagnostic rebuild v14.4.1'
echo "Source path: $SOURCE_DIR"
echo "Build path:  $BUILD_DIR"
echo

# The source directory can be a WSL-created Unix symlink on an NTFS-mounted
# drive. Validate it here, where the symlink is meaningful.
if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: existing OpenMW 0.50 source tree is missing inside WSL: $SOURCE_DIR" >&2
    echo 'This diagnostic requires the already-built 0.50 native tree.' >&2
    exit 2
fi

if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: existing OpenMW 0.50 CMake build tree is missing inside WSL: $BUILD_DIR" >&2
    exit 3
fi

if [ ! -f "$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp" ]; then
    echo "ERROR: postprocessor.cpp is missing from the WSL-visible source tree." >&2
    exit 4
fi

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: CMakeCache.txt is missing; refusing to reconfigure or start a clean native build." >&2
    exit 5
fi

if [ ! -f "$DIAG_PATCHER" ]; then
    echo "ERROR: diagnostic patcher is missing: $DIAG_PATCHER" >&2
    exit 6
fi

echo "WSL source resolves to: $(readlink -f "$SOURCE_DIR" 2>/dev/null || printf '%s' "$SOURCE_DIR")"
echo "WSL build resolves to:  $(readlink -f "$BUILD_DIR" 2>/dev/null || printf '%s' "$BUILD_DIR")"
echo

if ! grep -aFq "$STARTUP_MARKER" "$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"; then
    echo 'ERROR: established Android post-processing stabilization is missing from the existing source tree.' >&2
    exit 7
fi

# Reuse the existing successful No-LTO configuration. Do not configure CMake.
# The openmw target can have more than one generated link.txt location, so
# inspect every matching file and abort if any active link line still contains
# -flto.
mapfile -t LINK_FILES < <(find "$BUILD_DIR" -path '*/CMakeFiles/openmw.dir/link.txt' -type f -print 2>/dev/null)

if [ "${#LINK_FILES[@]}" -eq 0 ]; then
    echo 'WARNING: openmw link.txt was not found; continuing because CMakeCache.txt and the existing build tree are present.' >&2
else
    for link_file in "${LINK_FILES[@]}"; do
        if grep -q -- '-flto' "$link_file"; then
            echo "ERROR: existing OpenMW target is configured with LTO: $link_file" >&2
            echo 'Use the established No-LTO build tree before running this diagnostic.' >&2
            exit 8
        fi
    done
    echo "Verified existing OpenMW link configuration: No-LTO"
fi

echo
echo 'Applying OpenMW 0.50 OMWFX diagnostic logging...'
python3 "$DIAG_PATCHER" "$SOURCE_DIR"

if ! grep -aFq "$DIAG_MARKER" "$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"; then
    echo 'ERROR: OMWFX diagnostic source marker is missing after patching.' >&2
    exit 9
fi

echo
echo 'Rebuilding only the existing OpenMW target (no configure, no dependency clean)...'
cmake --build "$BUILD_DIR" --target openmw -- -j"$(nproc)"

LIB="$BUILD_DIR/libopenmw.so"
if [ ! -s "$LIB" ]; then
    echo "ERROR: rebuilt libopenmw.so not found: $LIB" >&2
    exit 10
fi

if ! grep -aFq "$STARTUP_MARKER" "$LIB"; then
    echo 'ERROR: rebuilt libopenmw.so lost the Android post-processing startup marker.' >&2
    exit 11
fi

if ! grep -aFq 'OMWFX050-DIAG' "$LIB"; then
    echo 'ERROR: rebuilt libopenmw.so does not contain the OMWFX diagnostic marker.' >&2
    exit 12
fi

ABI_DIR="$PROJECT/app/src/main/jniLibs/arm64-v8a"
SYMBOL_DIR="$PROJECT/buildscripts/symbols/arm64-v8a"

mkdir -p "$ABI_DIR" "$SYMBOL_DIR"
cp -f "$LIB" "$SYMBOL_DIR/libopenmw.so"
cp -f "$LIB" "$ABI_DIR/libopenmw.so"

STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
if [ -x "$STRIP" ]; then
    "$STRIP" "$ABI_DIR/libopenmw.so"
else
    echo 'WARNING: llvm-strip was not found; packaging the unstripped diagnostic library.' >&2
fi

if ! grep -aFq 'OMWFX050-DIAG' "$ABI_DIR/libopenmw.so"; then
    echo 'ERROR: packaged libopenmw.so lost the OMWFX diagnostic marker.' >&2
    exit 13
fi

if ! grep -aFq "$STARTUP_MARKER" "$ABI_DIR/libopenmw.so"; then
    echo 'ERROR: packaged libopenmw.so lost the Android startup stabilization marker.' >&2
    exit 14
fi

echo
echo "Unstripped lib SHA-256: $(sha256sum "$SYMBOL_DIR/libopenmw.so" | awk '{print $1}')"
echo "Packaged lib SHA-256:  $(sha256sum "$ABI_DIR/libopenmw.so" | awk '{print $1}')"
echo 'Verified: existing No-LTO build tree reused'
echo 'Verified: Android startup stabilization marker retained'
echo 'Verified: OMWFX050-DIAG marker retained'
echo 'OpenMW 0.50 OMWFX diagnostic incremental rebuild v14.4.1: SUCCESS'
'@

$Script = $Script.Replace('__PROJECT__', (Quote-Bash $Project))
$Script = $Script.Replace('__SOURCE__', (Quote-Bash $Source))
$Script = $Script.Replace('__BUILD__', (Quote-Bash $Build))
$Script = $Script.Replace('__DIAG_PATCHER__', (Quote-Bash $DiagPatcher))
$Script = $Script -replace "`r`n", "`n"

[IO.File]::WriteAllText($TempWin, $Script, [Text.UTF8Encoding]::new($false))

try {
    & wsl.exe --exec bash $TempWsl
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Remove-Item $TempWin -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'v14.4.1 rebuild hotfix completed.' -ForegroundColor Green
Write-Host 'No payload finalizer is required: only libopenmw.so was replaced.' -ForegroundColor Green
Write-Host 'Build the APK with: .\gradlew.bat :app:assembleMainlineDebug' -ForegroundColor Cyan
