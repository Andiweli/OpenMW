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

    if ([string]::IsNullOrWhiteSpace($rest)) {
        return "/mnt/$drive"
    }

    return "/mnt/$drive/" + (($rest -replace '\\', '/').TrimStart('/'))
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

$SourceWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$PatcherWin = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final\apply-android-gles-depth-fallback.py'

if (-not (Test-Path -LiteralPath $PatcherWin)) {
    throw "Missing depth fallback patcher: $PatcherWin"
}

$Project = Convert-WindowsPathToWsl $ProjectRoot
$Source = Convert-WindowsPathToWsl $SourceWin
$Build = Convert-WindowsPathToWsl $BuildWin
$Patcher = Convert-WindowsPathToWsl $PatcherWin

$TempWin = Join-Path $ProjectRoot 'tools\.openmw-050-depth-fallback-test.sh'
$TempWsl = "$Project/tools/.openmw-050-depth-fallback-test.sh"

$Bash = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
SOURCE_DIR=__SOURCE__
BUILD_DIR=__BUILD__
PATCHER=__PATCHER__

echo 'OpenMW 0.50 Android GLES depth fallback test v14.5'
echo "Source path: $SOURCE_DIR"
echo "Build path:  $BUILD_DIR"
echo

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: existing OpenMW 0.50 source tree is missing inside WSL: $SOURCE_DIR" >&2
    exit 2
fi

if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "ERROR: existing OpenMW 0.50 CMake build tree is missing/incomplete: $BUILD_DIR" >&2
    exit 3
fi

CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
if [ ! -f "$CPP" ]; then
    echo "ERROR: postprocessor.cpp is missing: $CPP" >&2
    exit 4
fi

mapfile -t LINK_FILES < <(find "$BUILD_DIR" -path '*/CMakeFiles/openmw.dir/link.txt' -type f -print 2>/dev/null)
if [ "${#LINK_FILES[@]}" -gt 0 ]; then
    for link_file in "${LINK_FILES[@]}"; do
        if grep -q -- '-flto' "$link_file"; then
            echo "ERROR: existing OpenMW target is configured with LTO: $link_file" >&2
            exit 5
        fi
    done
    echo 'Verified existing OpenMW link configuration: No-LTO'
fi

echo
echo 'Applying Android GLES direct-depth fallback...'
python3 "$PATCHER" "$SOURCE_DIR"

if ! grep -Fq 'setTextureDepth(getTexture(Tex_Depth, frameId))' "$CPP"; then
    echo 'ERROR: Android Tex_Depth fallback is missing after patching.' >&2
    exit 6
fi

if ! grep -Fq 'Android GLES post-processing depth fallback: sampling Tex_Depth directly' "$CPP"; then
    echo 'ERROR: Android depth-fallback runtime marker is missing after patching.' >&2
    exit 7
fi

echo
echo 'Rebuilding only the existing OpenMW target (no configure, no dependency clean)...'
cmake --build "$BUILD_DIR" --target openmw -- -j"$(nproc)"

LIB="$BUILD_DIR/libopenmw.so"
if [ ! -s "$LIB" ]; then
    echo "ERROR: rebuilt libopenmw.so not found: $LIB" >&2
    exit 8
fi

if ! grep -aFq 'Android GLES post-processing depth fallback: sampling Tex_Depth directly' "$LIB"; then
    echo 'ERROR: rebuilt libopenmw.so does not contain the depth-fallback marker.' >&2
    exit 9
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
    echo 'WARNING: llvm-strip was not found; packaging the unstripped test library.' >&2
fi

if ! grep -aFq 'Android GLES post-processing depth fallback: sampling Tex_Depth directly' "$ABI_DIR/libopenmw.so"; then
    echo 'ERROR: packaged libopenmw.so lost the depth-fallback marker.' >&2
    exit 10
fi

echo
echo "Unstripped lib SHA-256: $(sha256sum "$SYMBOL_DIR/libopenmw.so" | awk '{print $1}')"
echo "Packaged lib SHA-256:  $(sha256sum "$ABI_DIR/libopenmw.so" | awk '{print $1}')"
echo 'Verified: existing No-LTO build tree reused'
echo 'Verified: Android post-processing samples Tex_Depth directly'
echo 'OpenMW 0.50 Android GLES depth fallback incremental rebuild v14.5: SUCCESS'
'@

$Bash = $Bash.Replace('__PROJECT__', (Quote-Bash $Project))
$Bash = $Bash.Replace('__SOURCE__', (Quote-Bash $Source))
$Bash = $Bash.Replace('__BUILD__', (Quote-Bash $Build))
$Bash = $Bash.Replace('__PATCHER__', (Quote-Bash $Patcher))
$Bash = $Bash -replace "`r`n", "`n"

[IO.File]::WriteAllText($TempWin, $Bash, [Text.UTF8Encoding]::new($false))

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
Write-Host 'v14.5 depth fallback test library ready.' -ForegroundColor Green
Write-Host 'No payload finalizer is required.' -ForegroundColor Green
Write-Host 'Build the APK with: .\gradlew.bat :app:assembleMainlineDebug' -ForegroundColor Cyan
