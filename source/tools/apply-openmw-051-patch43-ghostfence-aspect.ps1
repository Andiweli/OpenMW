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
$Patcher = Join-Path $PatchDir 'apply-android-graphics-followup2.py'
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
        throw "Patch 43 requires the completed Patch-42-v3 project and extracted Patch-43 files. Missing: $Required"
    }
}

$Prepare = Read-Lf $PrepareScript
$PatcherVarLine = "`$GraphicsFollowup2Patcher = Join-Path `$PatchDir 'apply-android-graphics-followup2.py'"
if (-not $Prepare.Contains($PatcherVarLine)) {
    $Anchor = "`$GraphicsFollowupPatcher = Join-Path `$PatchDir 'apply-android-graphics-followup.py'"
    if (-not $Prepare.Contains($Anchor)) {
        throw 'Patch 43: Patch-42 graphics follow-up variable anchor missing in prepare script.'
    }
    $Prepare = $Prepare.Replace($Anchor, $Anchor + "`n" + $PatcherVarLine)
}

$RequiredAnchor = "    `$GraphicsFollowupPatcher"
if (-not $Prepare.Contains("    `$GraphicsFollowup2Patcher")) {
    if (-not $Prepare.Contains($RequiredAnchor)) {
        throw 'Patch 43: prepare required-file anchor missing.'
    }
    $Prepare = $Prepare.Replace($RequiredAnchor, $RequiredAnchor + ",`n    `$GraphicsFollowup2Patcher")
}

$OldChainTail = '        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup.py <SOURCE_DIR>'
$NewChainTail = $OldChainTail + " &&`n        python3 `${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-graphics-followup2.py <SOURCE_DIR>"
if (-not $Prepare.Contains('apply-android-graphics-followup2.py <SOURCE_DIR>')) {
    if (-not $Prepare.Contains($OldChainTail)) {
        throw 'Patch 43: prepare OPENMW_PATCH chain anchor missing.'
    }
    $Prepare = $Prepare.Replace($OldChainTail, $NewChainTail)
}

$VerifyAnchor = "    'patches/openmw051-final/apply-android-graphics-followup.py'"
$VerifyNew = "    'patches/openmw051-final/apply-android-graphics-followup2.py'"
if (-not $Prepare.Contains($VerifyNew)) {
    if (-not $Prepare.Contains($VerifyAnchor)) {
        throw 'Patch 43: prepare verification-list anchor missing.'
    }
    $Prepare = $Prepare.Replace($VerifyAnchor, $VerifyAnchor + ",`n" + $VerifyNew)
}

Write-Utf8Lf $PrepareScript $Prepare

$CMake = Read-Lf $CMakeFile
if (-not $CMake.Contains('apply-android-graphics-followup2.py <SOURCE_DIR>')) {
    if (-not $CMake.Contains($OldChainTail)) {
        throw 'Patch 43: CMake OPENMW_PATCH chain anchor missing.'
    }
    $CMake = $CMake.Replace($OldChainTail, $NewChainTail)
    Write-Utf8Lf $CMakeFile $CMake
}

$HasBuildTree = (Test-Path -LiteralPath $SourceRoot) -and
                (Test-Path -LiteralPath (Join-Path $BuildRoot 'CMakeCache.txt'))

if (-not $HasBuildTree) {
    Write-Host 'Patch 43: native OpenMW build tree is absent; recreating through the normal 0.51 pipeline...' -ForegroundColor Yellow
    & $BuildRuntimeScript -Jobs $Jobs
    if ($LASTEXITCODE -ne 0) {
        throw "Patch 43: OpenMW runtime recreation failed with exit code $LASTEXITCODE"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'Patch 43 requires WSL for the Android native build.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch43.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch43.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPENMW_PATCH43_PROJECT:?OPENMW_PATCH43_PROJECT is required}"
JOBS="${OPENMW_PATCH43_JOBS:?OPENMW_PATCH43_JOBS is required}"

SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-graphics-followup2.py"
NIF="$SOURCE/components/nifosg/nifloader.cpp"
DISPLAY="$SOURCE/components/misc/display.cpp"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

[[ -f "$SOURCE/CMakeLists.txt" && -f "$BUILD/CMakeCache.txt" ]] || exit 71
[[ -x "$STRIP" && -x "$READELF" ]] || exit 72

python3 "$PATCHER" "$SOURCE"

grep -Fq 'OPENMW_ANDROID_051_GHOSTFENCE_PARTICLE_STABLE_ORDER' "$NIF" || exit 73
grep -Fq 'osgParticle::ParticleSystem::NO_SORT' "$NIF" || exit 74
grep -Fq 'OPENMW_ANDROID_051_COMMON_ASPECT_RATIO' "$DISPLAY" || exit 75
if grep -Fq 'OPENMW_ANDROID_051_GHOSTFENCE_STABLE_ORDER' "$NIF"; then
    echo "ERROR: obsolete Patch-42 Ghostfence render-bin override is still present." >&2
    exit 76
fi

touch "$NIF" "$DISPLAY"

echo "Patch 43 source verification: PASS"
echo "Rebuilding Ghostfence particle + resolution-label code..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

find "$BUILD" -type f -path '*nifosg*nifloader.cpp.o' -print -quit | grep -q . || exit 77
find "$BUILD" -type f -path '*misc*display.cpp.o' -print -quit | grep -q . || exit 78

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
[[ ${#BUILT_LIBS[@]} -eq 1 ]] || {
    echo "ERROR: expected one built libopenmw.so, found ${#BUILT_LIBS[@]}" >&2
    exit 79
}
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || exit 80
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    exit 81
fi

echo "Patch 43 native rebuild: PASS"
'@

[IO.File]::WriteAllText(
    $WindowsHelper,
    ($ShellScript -replace "`r`n", "`n"),
    [Text.UTF8Encoding]::new($false)
)

try {
    & wsl.exe env "OPENMW_PATCH43_PROJECT=$WslProject" "OPENMW_PATCH43_JOBS=$Jobs" bash $WslHelper
    if ($LASTEXITCODE -ne 0) {
        throw "Patch 43 native rebuild failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue
}

foreach ($Required in @($JniLib, $SymbolLib)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 43 post-build verification failed: missing $Required"
    }
}

$ActualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
$ShaLine = "$ActualSha  $JniLib`n"
[IO.File]::WriteAllText($Patch39Sha, $ShaLine, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($RuntimeSha, $ShaLine, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 43 Ghostfence/aspect follow-up: PASS' -ForegroundColor Green
Write-Host 'Gamma: unchanged from working Patch 42'
Write-Host 'Resolution label: common aspect approximation installed (854x480 -> 16:9)'
Write-Host 'Ghostfence: old render-bin hypothesis removed'
Write-Host 'Ghostfence: camera-dependent internal particle sorting disabled only for Ghostfence effects'
Write-Host "JNI SHA-256: $ActualSha"
Write-Host ''
Write-Host 'Now build the APK normally.'
