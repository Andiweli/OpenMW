param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for WSL: $WindowsPath"
    }

    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) {
        return "/mnt/$DriveLetter"
    }

    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$PatchDir = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final'
$GraphicsPatcher = Join-Path $PatchDir 'apply-android-graphics-followup.py'
$Gl4esPatcher = Join-Path $PatchDir 'apply-android-gl4es-core-inline.py'
$PrepareScript = Join-Path $ProjectRoot 'tools\prepare-openmw-051-runtime.ps1'
$BuildRuntimeScript = Join-Path $ProjectRoot 'tools\build-openmw-051-runtime.ps1'
$CMakeFile = Join-Path $ProjectRoot 'buildscripts\CMakeLists.txt'

$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'
$Patch39Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch39-libopenmw.sha256'
$RuntimeSha = Join-Path $ProjectRoot 'buildscripts\openmw-051-runtime-libopenmw.sha256'

foreach ($Required in @(
    $GraphicsPatcher,
    $Gl4esPatcher,
    $PrepareScript,
    $BuildRuntimeScript,
    $CMakeFile
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 42 v3 requires the completed OpenMW 0.51 project and extracted Patch-42-v3 files. Missing: $Required"
    }
}

# Ensure the dedicated graphics patcher remains part of all future clean builds.
$Prepare = Read-Lf $PrepareScript

if (-not $Prepare.Contains("`$GraphicsFollowupPatcher = Join-Path `$PatchDir 'apply-android-graphics-followup.py'")) {
    $Old = "`$Gl4esCorePatcher = Join-Path `$PatchDir 'apply-android-gl4es-core-inline.py'"
    if (-not $Prepare.Contains($Old)) {
        throw 'Patch 42 v3: prepare script GL4ES patcher anchor missing.'
    }
    $Prepare = $Prepare.Replace(
        $Old,
        $Old + "`n`$GraphicsFollowupPatcher = Join-Path `$PatchDir 'apply-android-graphics-followup.py'"
    )
}

$OldRequired = @'
    $RuntimePatcher,
    $Gl4esCorePatcher
'@
$NewRequired = @'
    $RuntimePatcher,
    $Gl4esCorePatcher,
    $GraphicsFollowupPatcher
'@
if ($Prepare.Contains($OldRequired) -and -not $Prepare.Contains($NewRequired)) {
    $Prepare = $Prepare.Replace($OldRequired, $NewRequired)
}

$OldChain = @'
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-runtime-baseline.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-gl4es-core-inline.py <SOURCE_DIR>
'@
$NewChain = @'
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-runtime-baseline.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-gl4es-core-inline.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup.py <SOURCE_DIR>
'@

if ($Prepare.Contains($OldChain) -and -not $Prepare.Contains('apply-android-graphics-followup.py <SOURCE_DIR>')) {
    $Prepare = $Prepare.Replace($OldChain, $NewChain)
}

$VerifyToken = "    'patches/openmw051-final/apply-android-gl4es-core-inline.py'"
$GraphicsVerifyToken = "    'patches/openmw051-final/apply-android-graphics-followup.py'"
if (-not $Prepare.Contains($GraphicsVerifyToken)) {
    if (-not $Prepare.Contains($VerifyToken)) {
        throw 'Patch 42 v3: prepare verification-list anchor missing.'
    }
    $Prepare = $Prepare.Replace(
        $VerifyToken,
        $VerifyToken + ",`n" + $GraphicsVerifyToken
    )
}

Write-Utf8Lf $PrepareScript $Prepare

$CMake = Read-Lf $CMakeFile
if (-not $CMake.Contains('apply-android-graphics-followup.py <SOURCE_DIR>')) {
    if (-not $CMake.Contains($OldChain)) {
        throw 'Patch 42 v3: CMake OPENMW_PATCH anchor missing.'
    }
    $CMake = $CMake.Replace($OldChain, $NewChain)
    Write-Utf8Lf $CMakeFile $CMake
}

# If a build tree is absent, recreate it once through the pinned 0.51 pipeline.
$HasBuildTree = (Test-Path -LiteralPath $SourceRoot) -and
                (Test-Path -LiteralPath (Join-Path $BuildRoot 'CMakeCache.txt'))

if (-not $HasBuildTree) {
    Write-Host ''
    Write-Host 'Patch 42 v3: OpenMW build tree is absent; recreating it once...' -ForegroundColor Yellow
    & $BuildRuntimeScript -Jobs $Jobs
    if ($LASTEXITCODE -ne 0) {
        throw "Patch 42 v3: OpenMW 0.51 runtime rebuild failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $SourceRoot) -or
    -not (Test-Path -LiteralPath (Join-Path $BuildRoot 'CMakeCache.txt'))) {
    throw 'Patch 42 v3: OpenMW source/build tree is unavailable after preparation.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch42-v3.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch42-v3.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPENMW_PATCH42_PROJECT:?OPENMW_PATCH42_PROJECT is required}"
JOBS="${OPENMW_PATCH42_JOBS:?OPENMW_PATCH42_JOBS is required}"

SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-graphics-followup.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

WM="$SOURCE/apps/openmw/mwgui/windowmanagerimp.cpp"
SW="$SOURCE/apps/openmw/mwgui/settingswindow.cpp"
NIF="$SOURCE/components/nifosg/nifloader.cpp"
PPH="$SOURCE/apps/openmw/mwrender/pingpongcanvas.hpp"
PPC="$SOURCE/apps/openmw/mwrender/pingpongcanvas.cpp"
COMP_CMAKE="$SOURCE/components/CMakeLists.txt"
APP_CMAKE="$SOURCE/apps/openmw/CMakeLists.txt"

[[ -f "$SOURCE/CMakeLists.txt" && -f "$BUILD/CMakeCache.txt" ]] || exit 71
[[ -x "$STRIP" && -x "$READELF" ]] || exit 72

python3 "$PATCHER" "$SOURCE"

# Exact source verification.
grep -Fq 'OPENMW_ANDROID_051_LOGICAL_RENDER_RESOLUTION' "$WM" || exit 73
grep -Fq 'OPENMW_ANDROID_051_LOGICAL_RENDER_RESOLUTION' "$SW" || exit 74
grep -Fq 'OPENMW_ANDROID_051_GHOSTFENCE_STABLE_ORDER' "$NIF" || exit 75
grep -Fq 'androidNifFilename.starts_with("ex_gg_fence_")' "$NIF" || exit 76
grep -Fq 'OPENMW_ANDROID_051_FINAL_GAMMA' "$PPH" || exit 77
grep -Fq 'OPENMW_ANDROID_051_FINAL_GAMMA' "$PPC" || exit 78
grep -Fq 'std::getenv("OPENMW_GAMMA")' "$PPC" || exit 79

# Verify that the patched files are genuinely in OpenMW's target graph.
grep -Fq 'add_component_dir (nifosg' "$COMP_CMAKE" || exit 80
grep -Eq '^[[:space:]]*nifloader[[:space:]]+controller' "$COMP_CMAKE" || exit 81
grep -Fq 'windowmanagerimp' "$APP_CMAKE" || exit 82
grep -Fq 'settingswindow' "$APP_CMAKE" || exit 83
grep -Fq 'pingpongcanvas' "$APP_CMAKE" || exit 84
grep -Fq 'target_link_libraries(openmw-lib' "$APP_CMAKE" || exit 85
grep -Fq 'components' "$APP_CMAKE" || exit 86

# Force the four changed translation units to be reconsidered. This makes v3 a
# reliable resume step after the v2 verification failure without rebuilding all
# dependencies again.
touch "$WM" "$SW" "$NIF" "$PPC"

echo "Patch 42 v3 source/target verification: PASS"
echo "Rebuilding affected OpenMW translation units..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

# Prove that CMake produced object files for all patched .cpp files.
find "$BUILD" -type f -path '*mwgui*windowmanagerimp.cpp.o' -print -quit | grep -q . || exit 87
find "$BUILD" -type f -path '*mwgui*settingswindow.cpp.o' -print -quit | grep -q . || exit 88
find "$BUILD" -type f -path '*nifosg*nifloader.cpp.o' -print -quit | grep -q . || exit 89
find "$BUILD" -type f -path '*mwrender*pingpongcanvas.cpp.o' -print -quit | grep -q . || exit 90

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
[[ ${#BUILT_LIBS[@]} -eq 1 ]] || {
    echo "ERROR: expected one built libopenmw.so, found ${#BUILT_LIBS[@]}" >&2
    exit 91
}
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || exit 92
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    exit 93
fi

# OPENMW_GAMMA is a getenv key and must remain a runtime string. In contrast,
# ex_gg_fence_ is intentionally NOT searched in the final LTO binary: Clang/LTO
# may legally lower starts_with() into constant byte comparisons.
grep -aFq 'OPENMW_GAMMA' "$JNI" || exit 94

echo "Patch 42 v3 native verification: PASS"
'@

[IO.File]::WriteAllText(
    $WindowsHelper,
    ($ShellScript -replace "`r`n", "`n"),
    [Text.UTF8Encoding]::new($false)
)

try {
    & wsl.exe env "OPENMW_PATCH42_PROJECT=$WslProject" "OPENMW_PATCH42_JOBS=$Jobs" bash $WslHelper
    if ($LASTEXITCODE -ne 0) {
        throw "Patch 42 v3 native rebuild/verification failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue
}

foreach ($Required in @($JniLib, $SymbolLib)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 42 v3 post-build verification failed: missing $Required"
    }
}

$ActualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
$ShaLine = "$ActualSha  $JniLib`n"
[IO.File]::WriteAllText($Patch39Sha, $ShaLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($RuntimeSha, $ShaLine, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 42 v3 graphics follow-up: PASS' -ForegroundColor Green
Write-Host 'Resolution source + object: VERIFIED'
Write-Host 'Gamma source + object + runtime getenv key: VERIFIED'
Write-Host 'Ghostfence source + CMake target + object: VERIFIED'
Write-Host 'LTO-safe verification: YES'
Write-Host "JNI SHA-256: $ActualSha"
Write-Host ''
Write-Host 'Now build the APK normally. Do not run either Python patcher manually.'
