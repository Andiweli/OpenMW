param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

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

$SourceWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$FinalPatcherWin = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final\apply-postprocessing-final.py'
$CleanupWin = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final\remove-omwfx050-diagnostics.py'
$RuntimeShaderSyncWin = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final\apply-runtime-water-shader-sync.py'

foreach ($Required in @($FinalPatcherWin, $CleanupWin, $RuntimeShaderSyncWin)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Missing v14.5.1 finalization file: $Required"
    }
}

$Project = Convert-WindowsPathToWsl $ProjectRoot
$Source = Convert-WindowsPathToWsl $SourceWin
$Build = Convert-WindowsPathToWsl $BuildWin
$FinalPatcher = Convert-WindowsPathToWsl $FinalPatcherWin
$Cleanup = Convert-WindowsPathToWsl $CleanupWin
$RuntimeShaderSync = Convert-WindowsPathToWsl $RuntimeShaderSyncWin

$TempWin = Join-Path $ProjectRoot 'tools\.openmw-050-omwfx-depth-finalize.sh'
$TempWsl = "$Project/tools/.openmw-050-omwfx-depth-finalize.sh"

$Bash = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
SOURCE_DIR=__SOURCE__
BUILD_DIR=__BUILD__
FINAL_PATCHER=__FINAL_PATCHER__
CLEANUP=__CLEANUP__
RUNTIME_SHADER_SYNC=__RUNTIME_SHADER_SYNC__

STARTUP_MARKER='Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '
DEPTH_MARKER='Android GLES post-processing depth fallback: sampling Tex_Depth directly'

echo 'OpenMW 0.50 OMWFX depth + exact WetWorld water mask finalization v14.5.6'
echo "Source path: $SOURCE_DIR"
echo "Build path:  $BUILD_DIR"
echo

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: existing OpenMW source tree is missing inside WSL: $SOURCE_DIR" >&2
    exit 2
fi
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: existing OpenMW CMake build tree is missing/incomplete: $BUILD_DIR" >&2
    exit 3
fi

CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
WATER_CPP="$SOURCE_DIR/apps/openmw/mwrender/water.cpp"
WATER_SHADER="$SOURCE_DIR/files/shaders/compatibility/water.frag"
if [ ! -f "$CPP" ]; then
    echo "ERROR: postprocessor.cpp is missing: $CPP" >&2
    exit 4
fi
if [ ! -f "$WATER_CPP" ]; then
    echo "ERROR: water.cpp is missing: $WATER_CPP" >&2
    exit 17
fi
if [ ! -f "$WATER_SHADER" ]; then
    echo "ERROR: water.frag is missing: $WATER_SHADER" >&2
    exit 18
fi

mapfile -t LINK_FILES < <(find "$BUILD_DIR" -path '*/CMakeFiles/openmw.dir/link.txt' -type f -print 2>/dev/null)
for link_file in "${LINK_FILES[@]}"; do
    if grep -q -- '-flto' "$link_file"; then
        echo "ERROR: LTO detected in existing OpenMW target: $link_file" >&2
        exit 5
    fi
done
echo 'Verified existing build tree: No-LTO'

echo
echo 'Patching Android runtime core-shader synchronization...'
MAIN_ACTIVITY="$PROJECT/app/src/main/java/ui/activity/MainActivity.kt"
python3 "$RUNTIME_SHADER_SYNC" "$MAIN_ACTIVITY"
if ! grep -Fq 'Synced runtime water.frag for WetWorld mask' "$MAIN_ACTIVITY"; then
    echo 'ERROR: runtime water.frag sync marker is missing in MainActivity.kt.' >&2
    exit 24
fi
if ! grep -Fq '"shaders/compatibility/water.frag"' "$MAIN_ACTIVITY"; then
    echo 'ERROR: water.frag is missing from runtime core shader sync list.' >&2
    exit 25
fi

echo
echo 'Removing temporary OMWFX050-DIAG instrumentation...'
python3 "$CLEANUP" "$SOURCE_DIR"

echo
echo 'Applying consolidated permanent Android post-processing patch...'
python3 "$FINAL_PATCHER" "$SOURCE_DIR"

if grep -Fq 'OMWFX050-DIAG' "$CPP"; then
    echo 'ERROR: OMWFX050-DIAG remains in source after cleanup.' >&2
    exit 6
fi
if ! grep -Fq "$STARTUP_MARKER" "$CPP"; then
    echo 'ERROR: established 4-draw startup stabilization is missing.' >&2
    exit 7
fi
if ! grep -Fq 'setTextureDepth(getTexture(Tex_Depth, frameId))' "$CPP"; then
    echo 'ERROR: permanent Android Tex_Depth binding is missing.' >&2
    exit 8
fi
if ! grep -Fq "$DEPTH_MARKER" "$CPP"; then
    echo 'ERROR: permanent Android depth marker is missing.' >&2
    exit 9
fi
if ! grep -Fq 'Android WetWorld water alpha mask' "$WATER_CPP"; then
    echo 'ERROR: exact WetWorld water alpha marker is missing in water.cpp.' >&2
    exit 19
fi
if ! grep -Fq '@wetWorldWaterMask' "$WATER_SHADER"; then
    echo 'ERROR: exact WetWorld water alpha marker is missing in water.frag.' >&2
    exit 20
fi
if ! grep -Fq 'rainCombined(position.xy/1000.0, waterTimer)' "$WATER_SHADER"; then
    echo 'ERROR: native OpenMW rain ripple code is missing; refusing to continue.' >&2
    exit 21
fi

echo
echo 'Incrementally rebuilding only the existing OpenMW target...'
cmake --build "$BUILD_DIR" --target openmw -- -j"$(nproc)"

LIB="$BUILD_DIR/libopenmw.so"
if [ ! -s "$LIB" ]; then
    echo "ERROR: rebuilt libopenmw.so not found: $LIB" >&2
    exit 10
fi
if grep -aFq 'OMWFX050-DIAG' "$LIB"; then
    echo 'ERROR: diagnostic marker still exists in rebuilt libopenmw.so.' >&2
    exit 11
fi
if ! grep -aFq "$STARTUP_MARKER" "$LIB"; then
    echo 'ERROR: rebuilt libopenmw.so lost the startup stabilization marker.' >&2
    exit 12
fi
if ! grep -aFq "$DEPTH_MARKER" "$LIB"; then
    echo 'ERROR: rebuilt libopenmw.so lost the Android depth marker.' >&2
    exit 13
fi

ABI_DIR="$PROJECT/app/src/main/jniLibs/arm64-v8a"
SYMBOL_DIR="$PROJECT/buildscripts/symbols/arm64-v8a"
mkdir -p "$ABI_DIR" "$SYMBOL_DIR"
cp -f "$LIB" "$SYMBOL_DIR/libopenmw.so"
cp -f "$LIB" "$ABI_DIR/libopenmw.so"

# The native patcher also changes the OpenMW water fragment shader. The
# incremental native build does not redeploy resources, so copy the exact
# patched source shader into the APK asset tree explicitly.
WATER_ASSET="$PROJECT/app/src/main/assets/libopenmw/resources/shaders/compatibility/water.frag"
mkdir -p "$(dirname "$WATER_ASSET")"
cp -f "$WATER_SHADER" "$WATER_ASSET"
if ! grep -Fq '@wetWorldWaterMask' "$WATER_ASSET"; then
    echo 'ERROR: patched water.frag was not deployed into app assets.' >&2
    exit 22
fi
if ! grep -Fq 'rainCombined(position.xy/1000.0, waterTimer)' "$WATER_ASSET"; then
    echo 'ERROR: deployed water.frag lost native OpenMW rain ripples.' >&2
    exit 23
fi

STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
if [ -x "$STRIP" ]; then
    "$STRIP" "$ABI_DIR/libopenmw.so"
else
    echo 'WARNING: llvm-strip not found; packaging unstripped library.' >&2
fi

if grep -aFq 'OMWFX050-DIAG' "$ABI_DIR/libopenmw.so"; then
    echo 'ERROR: packaged libopenmw.so still contains OMWFX050-DIAG.' >&2
    exit 14
fi
if ! grep -aFq "$STARTUP_MARKER" "$ABI_DIR/libopenmw.so"; then
    echo 'ERROR: packaged libopenmw.so lost startup stabilization.' >&2
    exit 15
fi
if ! grep -aFq "$DEPTH_MARKER" "$ABI_DIR/libopenmw.so"; then
    echo 'ERROR: packaged libopenmw.so lost permanent depth fix.' >&2
    exit 16
fi

echo
echo "Unstripped lib SHA-256: $(sha256sum "$SYMBOL_DIR/libopenmw.so" | awk '{print $1}')"
echo "Packaged lib SHA-256:  $(sha256sum "$ABI_DIR/libopenmw.so" | awk '{print $1}')"
echo 'Verified: OMWFX050-DIAG removed from source and binary'
echo 'Verified: 4-draw startup stabilization retained'
echo 'Verified: Android GLES post-processing uses Tex_Depth directly'
echo 'Verified: exact water alpha marker deployed for WetWorld'
echo 'Verified: native OpenMW rain rings retained'
echo 'Verified: runtime water.frag is refreshed directly from APK assets on every launch'
echo 'OpenMW 0.50 OMWFX depth + WetWorld water mask finalization v14.5.6: SUCCESS'
'@

$Bash = $Bash.Replace('__PROJECT__', (Quote-Bash $Project))
$Bash = $Bash.Replace('__SOURCE__', (Quote-Bash $Source))
$Bash = $Bash.Replace('__BUILD__', (Quote-Bash $Build))
$Bash = $Bash.Replace('__FINAL_PATCHER__', (Quote-Bash $FinalPatcher))
$Bash = $Bash.Replace('__CLEANUP__', (Quote-Bash $Cleanup))
$Bash = $Bash.Replace('__RUNTIME_SHADER_SYNC__', (Quote-Bash $RuntimeShaderSync))
$Bash = $Bash -replace "`r`n", "`n"

[IO.File]::WriteAllText($TempWin, $Bash, [Text.UTF8Encoding]::new($false))
try {
    & wsl.exe --exec bash $TempWsl
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $TempWin -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'v14.5.6 native library + exact WetWorld water mask + runtime shader sync ready.' -ForegroundColor Green
Write-Host 'No payload finalizer is required.' -ForegroundColor Green
Write-Host 'Build APK: .\gradlew.bat :app:assembleMainlineDebug' -ForegroundColor Cyan
