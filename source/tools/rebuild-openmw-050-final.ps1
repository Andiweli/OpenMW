param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = '47d78e004bc182def2904986f8bb54aea1f4b3ae'

& (Join-Path $PSScriptRoot 'prepare-openmw-050-final.ps1')

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required.'
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported Windows path: $WindowsPath"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($rest)) { return "/mnt/$drive" }
    return "/mnt/$drive/" + (($rest -replace '\\', '/').TrimStart('/'))
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

$Project = Convert-WindowsPathToWsl $ProjectRoot
$SourceWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$PatcherWin = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final\apply-postprocessing-final.py'
$LogWin = Join-Path $ProjectRoot 'buildscripts\openmw-050-final-link.log'

foreach ($Required in @($SourceWin, $BuildWin, $PatcherWin)) {
    if (-not (Test-Path $Required)) {
        throw "Incremental OpenMW 0.50 build tree is missing: $Required`nRun tools\build-openmw-050-final.ps1 first."
    }
}

$Source = Convert-WindowsPathToWsl $SourceWin
$Build = Convert-WindowsPathToWsl $BuildWin
$Patcher = Convert-WindowsPathToWsl $PatcherWin
$Log = Convert-WindowsPathToWsl $LogWin
$TempWin = Join-Path $ProjectRoot 'tools\.openmw-050-final-rebuild.sh'
$TempWsl = "$Project/tools/.openmw-050-final-rebuild.sh"

$Script = @'
#!/usr/bin/env bash
set -uo pipefail
PROJECT=__PROJECT__
SOURCE_DIR=__SOURCE__
BUILD_DIR=__BUILD__
PATCHER=__PATCHER__
LOG=__LOG__

python3 "$PATCHER" "$SOURCE_DIR" || exit $?

EXPECTED_MARKER='Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '
if ! grep -aFq "$EXPECTED_MARKER" "$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"; then
    echo "ERROR: OpenMW 0.50 Android stabilization marker missing from source." >&2
    exit 3
fi

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

echo "Rebuilding OpenMW 0.50 engine target (verbose, parallel=1)..."
echo "Full link log: $LOG"
echo

# Use one build job for the diagnostic/final-link pass. Most compilation is already
# complete, and this avoids unrelated memory pressure while ld.lld performs the large
# final shared-library link.
set +e
cmake --build "$BUILD_DIR" --target openmw --parallel 1 --verbose 2>&1 | tee "$LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

echo
echo "OpenMW build command exit code: $BUILD_RC"

if [ "$BUILD_RC" -ne 0 ]; then
    echo >&2
    echo "============================================================" >&2
    echo "OpenMW 0.50 FINAL LINK FAILED (exit $BUILD_RC)" >&2
    echo "Full log: $LOG" >&2
    echo "Last 120 log lines:" >&2
    echo "============================================================" >&2
    tail -n 120 "$LOG" >&2 || true
    echo >&2
    echo "Likely root-cause lines:" >&2
    grep -nEi '(^|: )(error:|fatal error:|undefined symbol|undefined reference|ld\.lld:|clang\+\+: error|killed|out of memory|cannot allocate|terminated|signal|collect2:|ninja: error|make\[[0-9]+\]: \*\*\*)' "$LOG" | tail -n 80 >&2 || true
    if [ "$BUILD_RC" -eq 137 ] || [ "$BUILD_RC" -eq 9 ]; then
        echo >&2
        echo "NOTE: exit $BUILD_RC is consistent with a process being killed; WSL/Linux OOM is a strong possibility." >&2
    fi
    exit "$BUILD_RC"
fi

# OpenMW 0.50 places the shared library at the top of the OpenMW binary dir.
# Verify exact path first, then locate it defensively in case the generator differs.
LIB="$BUILD_DIR/libopenmw.so"
if [ ! -s "$LIB" ]; then
    FOUND="$(find "$BUILD_DIR" -type f -name 'libopenmw.so' -size +0c -print -quit 2>/dev/null || true)"
    if [ -n "$FOUND" ]; then
        LIB="$FOUND"
    fi
fi

if [ ! -s "$LIB" ]; then
    echo "ERROR: linker returned success but libopenmw.so was not found under $BUILD_DIR" >&2
    find "$BUILD_DIR" -maxdepth 4 -type f \( -name 'libopenmw.so' -o -name '*openmw*.so' \) -ls >&2 || true
    exit 4
fi

if ! grep -aFq "$EXPECTED_MARKER" "$LIB"; then
    echo "ERROR: rebuilt libopenmw.so does not contain the Android startup marker: $LIB" >&2
    exit 5
fi

ABI_DIR="$PROJECT/app/src/main/jniLibs/arm64-v8a"
SYMBOL_DIR="$PROJECT/buildscripts/symbols/arm64-v8a"
mkdir -p "$ABI_DIR" "$SYMBOL_DIR"
cp -f "$LIB" "$SYMBOL_DIR/libopenmw.so"
cp -f "$LIB" "$ABI_DIR/libopenmw.so"

STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
if [ -x "$STRIP" ]; then
    "$STRIP" "$ABI_DIR/libopenmw.so"
fi

MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
mkdir -p "$(dirname "$MARKER")"
cat > "$MARKER" <<'EOF'
OpenMW 0.50.0 Final
commit=__COMMIT__
EOF

echo
echo "Linked library: $LIB"
echo "Unstripped lib SHA-256: $(sha256sum "$SYMBOL_DIR/libopenmw.so" | awk '{print $1}')"
echo "Packaged lib SHA-256: $(sha256sum "$ABI_DIR/libopenmw.so" | awk '{print $1}')"
echo "Verified binary marker: $EXPECTED_MARKER"
echo "OpenMW 0.50 incremental native rebuild: SUCCESS"
'@

$Script = $Script.Replace('__PROJECT__', (Quote-Bash $Project))
$Script = $Script.Replace('__SOURCE__', (Quote-Bash $Source))
$Script = $Script.Replace('__BUILD__', (Quote-Bash $Build))
$Script = $Script.Replace('__PATCHER__', (Quote-Bash $Patcher))
$Script = $Script.Replace('__LOG__', (Quote-Bash $Log))
$Script = $Script.Replace('__COMMIT__', $FinalCommit)
$Script = $Script -replace "`r`n", "`n"
[IO.File]::WriteAllText($TempWin, $Script, [Text.UTF8Encoding]::new($false))

try {
    & wsl.exe --exec bash $TempWsl
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Host ""
        Write-Host "OpenMW 0.50 rebuild wrapper FAILED (WSL exit $rc)" -ForegroundColor Red
        Write-Host "Full link log: $LogWin" -ForegroundColor Yellow
        exit $rc
    }
}
finally {
    Remove-Item $TempWin -Force -ErrorAction SilentlyContinue
}
