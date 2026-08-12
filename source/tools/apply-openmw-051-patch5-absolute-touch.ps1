param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6,
    [switch]$PatchOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for WSL: $WindowsPath"
    }
    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$WindowManager = Join-Path $SourceRoot 'apps\openmw\mwgui\windowmanagerimp.cpp'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($Marker, $RuntimePatcher, $SourceRoot, $BuildRoot, $WindowManager, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 5 requires the existing successful OpenMW 0.51 Patch-4 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $Marker) -ne $ExpectedMarker) {
    throw 'Patch 5 refused a non-0.51-Final runtime payload.'
}

$PatcherText = Read-Lf $RuntimePatcher
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_ABSOLUTE_TOUCH_CURSOR')) {
    throw 'Patch 5 package is incomplete: future-build absolute-touch marker is missing from apply-android-runtime-baseline.py.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch5-absolute-touch.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch5-absolute-touch.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
JOBS=__JOBS__
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
WM="$SOURCE/apps/openmw/mwgui/windowmanagerimp.cpp"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi
if [ ! -f "$SOURCE/CMakeLists.txt" ] || ! grep -Eq 'set\(OPENMW_VERSION_MINOR[[:space:]]+51\)' "$SOURCE/CMakeLists.txt"; then
    echo 'ERROR: extracted native source is not OpenMW 0.51.x.' >&2
    exit 21
fi
if [ ! -f "$WM" ]; then
    echo "ERROR: missing $WM" >&2
    exit 22
fi

# Re-run the idempotent runtime patcher. Existing Patch-2 changes are detected;
# Patch 5 adds only the Android getCursorVisible compatibility branch.
python3 "$PATCHER" "$SOURCE"

if ! grep -Fq 'OPENMW_ANDROID_051_ABSOLUTE_TOUCH_CURSOR' "$WM"; then
    echo 'ERROR: Patch 5 source marker is missing after patching.' >&2
    exit 23
fi
if ! grep -A14 -F 'bool WindowManager::getCursorVisible()' "$WM" | grep -Fq 'return mCursorVisible;'; then
    echo 'ERROR: Android cursor-visible return path was not installed.' >&2
    exit 24
fi
if ! grep -A18 -F 'bool WindowManager::getCursorVisible()' "$WM" | grep -Fq 'return mCursorVisible && mCursorActive;'; then
    echo 'ERROR: non-Android upstream cursor semantics were not preserved.' >&2
    exit 25
fi

echo
echo 'OpenMW 0.51 Patch 5 source fix: READY'
echo 'Android menus: SDL cursor visibility no longer depends on mCursorActive.'
echo 'Desktop/non-Android behavior remains upstream 0.51.'

if [ "__PATCH_ONLY__" = "1" ]; then
    echo 'PatchOnly selected: native library was not rebuilt.'
    exit 0
fi

if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 26
fi

echo
echo "Incrementally rebuilding only OpenMW with parallelism=$JOBS ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 27
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 28
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS" || ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo 'ERROR: rebuilt library does not identify as OpenMW 0.51.0.' >&2
    exit 29
fi

SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged library was not stripped (packaged=$JNI_SIZE symbols=$SYMBOL_SIZE)." >&2
    exit 30
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: packaged libopenmw.so still contains DWARF debug sections.' >&2
    exit 31
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch5-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 5 absolute-touch native rebuild: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: rebuild/reinstall the APK normally in Android Studio.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript.Replace('__PATCH_ONLY__', $(if ($PatchOnly) { '1' } else { '0' }))
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 5 - Absolute Touch / Controller Menu cursor compatibility' -ForegroundColor Cyan
Write-Host 'This restores the proven OpenMW 0.50 Android cursor behavior, scoped to ANDROID.' -ForegroundColor Cyan
if (-not $PatchOnly) {
    Write-Host "Only the existing OpenMW native target will be incrementally rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow
    Write-Host 'Third-party dependencies are NOT rebuilt.' -ForegroundColor DarkGray
}

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

$WindowText = Read-Lf $WindowManager
if (-not $WindowText.Contains('OPENMW_ANDROID_051_ABSOLUTE_TOUCH_CURSOR')) {
    throw 'Patch 5 Windows-side source verification failed.'
}

if (-not $PatchOnly) {
    foreach ($Required in @($JniLib, $SymbolLib)) {
        if (-not (Test-Path $Required)) { throw "Patch 5 output verification failed: missing $Required" }
    }
    $JniSize = (Get-Item $JniLib).Length
    $SymbolSize = (Get-Item $SymbolLib).Length
    if ($JniSize -ge $SymbolSize) {
        throw "Patch 5 strip verification failed: packaged=$JniSize symbol=$SymbolSize"
    }
    Write-Host ''
    Write-Host 'Patch 5 is ready for APK assembly.' -ForegroundColor Green
    Write-Host "Packaged libopenmw.so: $JniLib ($JniSize bytes)"
    Write-Host "Unstripped symbols:    $SymbolLib ($SymbolSize bytes)"
    Write-Host "Packaged SHA-256:      $((Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant())"
}
