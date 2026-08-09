param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Keep the future clean-build patch chain in sync as well. This migration is
# idempotent and does not delete the existing OpenMW build tree.
& (Join-Path $PSScriptRoot 'prepare-openmw-049-final.ps1')
$Patch7Win = Join-Path $ProjectRoot 'buildscripts\patches\openmw049-final\0007-android-postprocessing-init.patch'
$Patch8Win = Join-Path $ProjectRoot 'buildscripts\patches\openmw049-final\0008-android-deferred-postprocessing-enable.patch'
$Patch9Win = Join-Path $ProjectRoot 'buildscripts\patches\openmw049-final\0009-android-postprocessing-gl-warmup.patch'
$Patch10Win = Join-Path $ProjectRoot 'buildscripts\patches\openmw049-final\0010-android-postprocessing-stabilize-after-live-draws.patch'
$MigratorWin = Join-Path $ProjectRoot 'tools\apply-openmw-049-omwfx-gl-warmup.py'
$Migrator10Win = Join-Path $ProjectRoot 'tools\apply-openmw-049-postprocessing-stabilize.py' 
$SourceWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildWin = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'

foreach ($Required in @($Patch7Win, $Patch8Win, $Patch9Win, $Patch10Win, $MigratorWin, $Migrator10Win, $SourceWin, $BuildWin)) {
    if (-not (Test-Path $Required)) {
        throw "Required existing v13.17-compatible build path is missing: $Required`nRun tools\build-openmw-049-final.ps1 instead if the native build tree was cleaned."
    }
}

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
$Patch7 = Convert-WindowsPathToWsl $Patch7Win
$Patch8 = Convert-WindowsPathToWsl $Patch8Win
$Patch9 = Convert-WindowsPathToWsl $Patch9Win
$Patch10 = Convert-WindowsPathToWsl $Patch10Win
$Migrator = Convert-WindowsPathToWsl $MigratorWin
$Migrator10 = Convert-WindowsPathToWsl $Migrator10Win
$Source = Convert-WindowsPathToWsl $SourceWin
$Build = Convert-WindowsPathToWsl $BuildWin
$TempWin = Join-Path $ProjectRoot 'tools\.openmw-049-final-omwfx-rebuild.sh'
$TempWsl = "$Project/tools/.openmw-049-final-omwfx-rebuild.sh"

$Script = @'
#!/usr/bin/env bash
set -euo pipefail
PROJECT=__PROJECT__
PATCH7_FILE=__PATCH7__
PATCH8_FILE=__PATCH8__
PATCH9_FILE=__PATCH9__
PATCH10_FILE=__PATCH10__
MIGRATOR=__MIGRATOR__
MIGRATOR10=__MIGRATOR10__
SOURCE_DIR=__SOURCE__
BUILD_DIR=__BUILD__

apply_patch_once() {
    local patch_file="$1"
    local patch_name="$2"

    if patch -d "$SOURCE_DIR" -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "Applying $patch_name..."
        patch -d "$SOURCE_DIR" -p1 --forward < "$patch_file"
    elif patch -d "$SOURCE_DIR" -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "$patch_name is already applied."
    else
        echo "ERROR: $patch_name does not match the existing OpenMW 0.49 Final source tree." >&2
        echo "Forward dry-run diagnostics:" >&2
        patch -d "$SOURCE_DIR" -p1 --forward --dry-run < "$patch_file" >&2 || true
        exit 3
    fi
}

apply_patch9_robust() {
    if patch -d "$SOURCE_DIR" -p1 --forward --dry-run < "$PATCH9_FILE" >/dev/null 2>&1; then
        echo "Applying 0009 Android post-processing GL-draw warm-up..."
        patch -d "$SOURCE_DIR" -p1 --forward < "$PATCH9_FILE"
        return
    fi

    if patch -d "$SOURCE_DIR" -p1 --reverse --dry-run < "$PATCH9_FILE" >/dev/null 2>&1; then
        echo "0009 Android post-processing GL-draw warm-up is already applied."
        return
    fi

    # Existing v13.17 trees may contain harmless local/context changes around
    # the patched areas. 0008 can still be present while a monolithic 0009
    # unified diff no longer matches. Migrate by unique v13.17 semantic markers
    # rather than increasing patch fuzz and risking the wrong location.
    echo "0009 unified diff does not match this existing v13.17 tree."
    echo "Using guarded semantic migration for the two postprocessor source files..."
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is required in WSL for the guarded v13.17 -> v13.18.1 migration." >&2
        exit 3
    fi
    python3 "$MIGRATOR" "$SOURCE_DIR"
}

apply_patch_once "$PATCH7_FILE" "0007 Android post-processing size initialization"

apply_patch8_robust() {
    if patch -d "$SOURCE_DIR" -p1 --forward --dry-run < "$PATCH8_FILE" >/dev/null 2>&1; then
        echo "Applying 0008 Android deferred first post-processing enable..."
        patch -d "$SOURCE_DIR" -p1 --forward < "$PATCH8_FILE"
        return
    fi

    if patch -d "$SOURCE_DIR" -p1 --reverse --dry-run < "$PATCH8_FILE" >/dev/null 2>&1; then
        echo "0008 Android deferred first post-processing enable is already applied."
        return
    fi

    # 0009 deliberately replaces the constructor/disable/cull state that 0008
    # introduced. Once those newer semantic markers exist, the old 0008 diff
    # can no longer reverse-apply even though its required functionality has
    # already been migrated forward. Treat that as a valid superseded state.
    CPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"
    HPP="$SOURCE_DIR/apps/openmw/mwrender/postprocessor.hpp"
    if grep -Fq 'class AndroidPostProcessingStartupDrawCallback' "$CPP" \
        && grep -Fq 'mAndroidPostProcessingWarmupDrawComplete' "$HPP"; then
        echo "0008 Android deferred first post-processing enable is superseded by the existing 0009+ startup state."
        return
    fi

    if grep -Fq 'Android post-processing startup stabilization v13.23 armed' "$CPP" \
        && grep -Fq 'mAndroidPostProcessingCompletedDraws' "$HPP"; then
        echo "0008 Android deferred first post-processing enable is superseded by the existing 0010 stabilization state."
        return
    fi

    echo "ERROR: 0008 Android deferred first post-processing enable does not match the existing OpenMW 0.49 Final source tree, and no newer semantic startup state was found." >&2
    echo "Forward dry-run diagnostics:" >&2
    patch -d "$SOURCE_DIR" -p1 --forward --dry-run < "$PATCH8_FILE" >&2 || true
    exit 3
}

apply_patch8_robust
apply_patch9_robust

apply_patch10_robust() {
    if patch -d "$SOURCE_DIR" -p1 --forward --dry-run < "$PATCH10_FILE" >/dev/null 2>&1; then
        echo "Applying 0010 Android post-processing late stabilization..."
        patch -d "$SOURCE_DIR" -p1 --forward < "$PATCH10_FILE"
        return
    fi

    if patch -d "$SOURCE_DIR" -p1 --reverse --dry-run < "$PATCH10_FILE" >/dev/null 2>&1; then
        echo "0010 Android post-processing late stabilization is already applied."
        return
    fi

    echo "0010 unified diff does not exactly match this existing native tree."
    echo "Using guarded semantic migration after the confirmed 0009 state..."
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is required in WSL for the guarded 0010 migration." >&2
        exit 3
    fi
    python3 "$MIGRATOR10" "$SOURCE_DIR"
}

apply_patch10_robust

EXPECTED_MARKER='Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '
if ! grep -aFq "$EXPECTED_MARKER" "$SOURCE_DIR/apps/openmw/mwrender/postprocessor.cpp"; then
    echo "ERROR: v13.23 stabilization marker is missing from patched postprocessor.cpp." >&2
    exit 3
fi

echo "Rebuilding only the changed OpenMW engine target..."
cmake --build "$BUILD_DIR" --target openmw -- -j"$(nproc)"

LIB="$BUILD_DIR/libopenmw.so"
if [ ! -s "$LIB" ]; then
    echo "ERROR: rebuilt libopenmw.so not found: $LIB" >&2
    exit 4
fi
if ! grep -aFq "$EXPECTED_MARKER" "$LIB"; then
    echo "ERROR: rebuilt libopenmw.so does not contain the v13.23 stabilization marker." >&2
    echo "The native target was not rebuilt from the patched source; refusing to package it." >&2
    exit 5
fi
BUILD_SHA256=$(sha256sum "$LIB" | awk '{print $1}')

ABI_DIR="$PROJECT/app/src/main/jniLibs/arm64-v8a"
SYMBOL_DIR="$PROJECT/buildscripts/symbols/arm64-v8a"
mkdir -p "$ABI_DIR" "$SYMBOL_DIR"
cp -f "$LIB" "$SYMBOL_DIR/libopenmw.so"
cp -f "$LIB" "$ABI_DIR/libopenmw.so"

STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
if [ -x "$STRIP" ]; then
    "$STRIP" "$ABI_DIR/libopenmw.so"
else
    echo "WARNING: llvm-strip not found; packaging the rebuilt unstripped library." >&2
fi

if ! grep -aFq "$EXPECTED_MARKER" "$ABI_DIR/libopenmw.so"; then
    echo "ERROR: packaged app/src/main/jniLibs/arm64-v8a/libopenmw.so lost the v13.23 marker." >&2
    exit 6
fi
PACKAGED_SHA256=$(sha256sum "$ABI_DIR/libopenmw.so" | awk '{print $1}')

MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
mkdir -p "$(dirname "$MARKER")"
printf '%s\n%s\n' \
    'OpenMW 0.49.0 Final' \
    'commit=675146bd8bce6245d78889f543b5c02a1e3936fe' > "$MARKER"

echo
ls -lh "$ABI_DIR/libopenmw.so"
echo "Native build SHA-256:    $BUILD_SHA256"
echo "Packaged lib SHA-256:   $PACKAGED_SHA256"
echo "Verified binary marker: $EXPECTED_MARKER"
echo "v13.23.1 incremental native rebuild: SUCCESS"
'@

$Script = $Script.Replace('__PROJECT__', (Quote-Bash $Project))
$Script = $Script.Replace('__PATCH7__', (Quote-Bash $Patch7))
$Script = $Script.Replace('__PATCH8__', (Quote-Bash $Patch8))
$Script = $Script.Replace('__PATCH9__', (Quote-Bash $Patch9))
$Script = $Script.Replace('__PATCH10__', (Quote-Bash $Patch10))
$Script = $Script.Replace('__MIGRATOR__', (Quote-Bash $Migrator))
$Script = $Script.Replace('__MIGRATOR10__', (Quote-Bash $Migrator10))
$Script = $Script.Replace('__SOURCE__', (Quote-Bash $Source))
$Script = $Script.Replace('__BUILD__', (Quote-Bash $Build))
$Script = $Script -replace "`r`n", "`n"
[IO.File]::WriteAllText($TempWin, $Script, [Text.UTF8Encoding]::new($false))

try {
    & wsl.exe --exec bash $TempWsl
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $TempWin -Force -ErrorAction SilentlyContinue
}
