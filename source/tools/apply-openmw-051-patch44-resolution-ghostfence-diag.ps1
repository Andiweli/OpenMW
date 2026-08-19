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
$Patcher = Join-Path $PatchDir 'apply-android-graphics-followup3.py'
$PrepareScript = Join-Path $ProjectRoot 'tools\prepare-openmw-051-runtime.ps1'
$BuildRuntimeScript = Join-Path $ProjectRoot 'tools\build-openmw-051-runtime.ps1'
$CMakeFile = Join-Path $ProjectRoot 'buildscripts\CMakeLists.txt'

$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'
$Patch39Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch39-libopenmw.sha256'
$RuntimeSha = Join-Path $ProjectRoot 'buildscripts\openmw-051-runtime-libopenmw.sha256'

foreach ($Required in @($Patcher, $PrepareScript, $BuildRuntimeScript, $CMakeFile)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 44 requires the completed Patch-43 project and extracted Patch-44 files. Missing: $Required"
    }
}

$Prepare = Read-Lf $PrepareScript
$VarLine = "`$GraphicsFollowup3Patcher = Join-Path `$PatchDir 'apply-android-graphics-followup3.py'"
if (-not $Prepare.Contains($VarLine)) {
    $Anchor = "`$GraphicsFollowup2Patcher = Join-Path `$PatchDir 'apply-android-graphics-followup2.py'"
    if (-not $Prepare.Contains($Anchor)) {
        throw 'Patch 44: Patch-43 patcher variable anchor missing in prepare script.'
    }
    $Prepare = $Prepare.Replace($Anchor, $Anchor + "`n" + $VarLine)
}

if (-not $Prepare.Contains("    `$GraphicsFollowup3Patcher")) {
    $Anchor = "    `$GraphicsFollowup2Patcher"
    if (-not $Prepare.Contains($Anchor)) {
        throw 'Patch 44: prepare required-file anchor missing.'
    }
    $Prepare = $Prepare.Replace($Anchor, $Anchor + ",`n    `$GraphicsFollowup3Patcher")
}

$OldTail = '        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup2.py <SOURCE_DIR>'
$NewTail = $OldTail + " &&`n        python3 `${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup3.py <SOURCE_DIR>"
if (-not $Prepare.Contains('apply-android-graphics-followup3.py <SOURCE_DIR>')) {
    if (-not $Prepare.Contains($OldTail)) {
        throw 'Patch 44: prepare OPENMW_PATCH chain anchor missing.'
    }
    $Prepare = $Prepare.Replace($OldTail, $NewTail)
}

$VerifyAnchor = "    'patches/openmw051-final/apply-android-graphics-followup2.py'"
$VerifyNew = "    'patches/openmw051-final/apply-android-graphics-followup3.py'"
if (-not $Prepare.Contains($VerifyNew)) {
    if (-not $Prepare.Contains($VerifyAnchor)) {
        throw 'Patch 44: prepare verification-list anchor missing.'
    }
    $Prepare = $Prepare.Replace($VerifyAnchor, $VerifyAnchor + ",`n" + $VerifyNew)
}

Write-Utf8Lf $PrepareScript $Prepare

$CMake = Read-Lf $CMakeFile
if (-not $CMake.Contains('apply-android-graphics-followup3.py <SOURCE_DIR>')) {
    if (-not $CMake.Contains($OldTail)) {
        throw 'Patch 44: CMake OPENMW_PATCH chain anchor missing.'
    }
    $CMake = $CMake.Replace($OldTail, $NewTail)
    Write-Utf8Lf $CMakeFile $CMake
}

$HasBuildTree = (Test-Path -LiteralPath $SourceRoot) -and
                (Test-Path -LiteralPath (Join-Path $BuildRoot 'CMakeCache.txt'))

if (-not $HasBuildTree) {
    Write-Host 'Patch 44: native OpenMW build tree is absent; recreating it through the normal 0.51 pipeline...' -ForegroundColor Yellow
    & $BuildRuntimeScript -Jobs $Jobs
    if ($LASTEXITCODE -ne 0) {
        throw "Patch 44: OpenMW runtime recreation failed with exit code $LASTEXITCODE"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'Patch 44 requires WSL for the Android native build.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch44.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch44.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPENMW_PATCH44_PROJECT:?OPENMW_PATCH44_PROJECT is required}"
JOBS="${OPENMW_PATCH44_JOBS:?OPENMW_PATCH44_JOBS is required}"

SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-graphics-followup3.py"
SETTINGS="$SOURCE/apps/openmw/mwgui/settingswindow.cpp"
NIF="$SOURCE/components/nifosg/nifloader.cpp"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

[[ -f "$SOURCE/CMakeLists.txt" && -f "$BUILD/CMakeCache.txt" ]] || exit 71
[[ -x "$STRIP" && -x "$READELF" ]] || exit 72

python3 "$PATCHER" "$SOURCE"

grep -Fq 'OPENMW_ANDROID_051_ACTIVE_RENDER_RESOLUTION_ONLY' "$SETTINGS" || exit 73
grep -Fq 'OPENMW_ANDROID_051_GHOSTFENCE_DEPTH_DIAG' "$NIF" || exit 74
if grep -Fq 'OPENMW_ANDROID_051_GHOSTFENCE_PARTICLE_STABLE_ORDER' "$NIF"; then
    echo "ERROR: obsolete Patch-43 Ghostfence particle override remains." >&2
    exit 75
fi

touch "$SETTINGS" "$NIF"

echo "Patch 44 source verification: PASS"
echo "Rebuilding resolution-menu + Ghostfence diagnostic code..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

find "$BUILD" -type f -path '*mwgui*settingswindow.cpp.o' -print -quit | grep -q . || exit 76
find "$BUILD" -type f -path '*nifosg*nifloader.cpp.o' -print -quit | grep -q . || exit 77

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
[[ ${#BUILT_LIBS[@]} -eq 1 ]] || {
    echo "ERROR: expected one built libopenmw.so, found ${#BUILT_LIBS[@]}" >&2
    exit 78
}
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || exit 79
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    exit 80
fi

grep -aFq 'OpenMW 0.51 Ghostfence diag:' "$JNI" || exit 81

echo "Patch 44 native rebuild: PASS"
'@

[IO.File]::WriteAllText(
    $WindowsHelper,
    ($ShellScript -replace "`r`n", "`n"),
    [Text.UTF8Encoding]::new($false)
)

try {
    & wsl.exe env "OPENMW_PATCH44_PROJECT=$WslProject" "OPENMW_PATCH44_JOBS=$Jobs" bash $WslHelper
    if ($LASTEXITCODE -ne 0) {
        throw "Patch 44 native rebuild failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue
}

foreach ($Required in @($JniLib, $SymbolLib)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 44 post-build verification failed: missing $Required"
    }
}

$ActualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
$ShaLine = "$ActualSha  $JniLib`n"
[IO.File]::WriteAllText($Patch39Sha, $ShaLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($RuntimeSha, $ShaLine, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 44 resolution/Ghostfence diagnostic: PASS' -ForegroundColor Green
Write-Host 'In-game Android resolution list: active render resolution only'
Write-Host 'Physical device modes: hidden from Android in-game resolution list'
Write-Host 'Ghostfence Patch-43 NO_SORT experiment: rolled back'
Write-Host 'Ghostfence Z-buffer/alpha/UV diagnostics: enabled'
Write-Host "JNI SHA-256: $ActualSha"
Write-Host ''
Write-Host 'Build the APK normally. For the Ghostfence test, capture lines containing "Ghostfence diag".'
