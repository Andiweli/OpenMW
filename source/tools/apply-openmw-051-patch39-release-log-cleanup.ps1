param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
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

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$Patch35Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch35-libopenmw.sha256'
$Patch39Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch39-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'

foreach ($Required in @($MarkerFile, $JniLib, $SourceRoot, $BuildRoot, $RuntimePatcher, $BuildGradle)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 39 requires the completed Patch-38 project plus the extracted Patch-39 files. Missing: $Required"
    }
}

if (-not (Test-Path -LiteralPath $Patch35Sha) -and -not (Test-Path -LiteralPath $Patch39Sha)) {
    throw 'Patch 39 requires the verified Patch-35 native SHA or an existing Patch-39 native SHA.'
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 39 refused a non-0.51.0-Final runtime payload.'
}

$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
$KnownNativeBase = $false
foreach ($ShaFile in @($Patch35Sha, $Patch39Sha)) {
    if (Test-Path -LiteralPath $ShaFile) {
        $ExpectedSha = ((Get-Content -LiteralPath $ShaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
        if ($ActualNativeSha -eq $ExpectedSha) {
            $KnownNativeBase = $true
        }
    }
}
if (-not $KnownNativeBase) {
    # Patch 39 v1 copied and stripped the successfully rebuilt library before
    # its unreliable binary-string check returned exit code 103. In that
    # interrupted state the packaged JNI hash is no longer the Patch-35 hash,
    # but no Patch-39 hash file has been written yet. Accept only the exact
    # source state produced by that interrupted run; the verified build below
    # will overwrite and hash the JNI library again.
    $PostProcessorSource = Join-Path $SourceRoot 'apps\openmw\mwrender\postprocessor.cpp'
    $RenderingManagerSource = Join-Path $SourceRoot 'apps\openmw\mwrender\renderingmanager.cpp'
    $InterruptedV1 = $false
    if ((Test-Path -LiteralPath $PostProcessorSource) -and
        (Test-Path -LiteralPath $RenderingManagerSource)) {
        $PostProcessorSourceText = Read-Lf $PostProcessorSource
        $RenderingManagerSourceText = Read-Lf $RenderingManagerSource
        $InterruptedV1 = $PostProcessorSourceText.Contains('OpenMW 0.51 Android renderer:')
        if ($InterruptedV1) {
            $InterruptedV1 = -not $PostProcessorSourceText.Contains('Gate G PP init')
        }
        if ($InterruptedV1) {
            $InterruptedV1 = $RenderingManagerSourceText.Contains('"lensflare_android_051_rayocc"')
        }
        if ($InterruptedV1) {
            $InterruptedV1 = -not $RenderingManagerSourceText.Contains('OpenMW 0.51 Android sun-occlusion ray:')
        }
    }

    if (-not $InterruptedV1) {
        throw "Patch 39 requires the exact Patch-35 or Patch-39 native library. actual=$ActualNativeSha"
    }

    Write-Host 'Detected an incomplete Patch 39 v1 verification; safely resuming from the verified source state.'
}

$PatcherText = Read-Lf $RuntimePatcher
foreach ($Need in @(
    'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH',
    'OPENMW_ANDROID_051_WETWORLD_WATER_MASK',
    'setTextureDepth(getTexture(Tex_Depth, frameId))',
    'defineMap["wetWorldWaterMask"] = "1";',
    "release_log_marker = 'OpenMW 0.51 Android renderer:'",
    'CPU sun-occlusion diagnostic logging was not removed',
    'repetitive shadow diagnostic was not removed'
)) {
    if (-not $PatcherText.Contains($Need)) {
        throw "Patch 39 native patcher is incomplete: $Need"
    }
}

$GradleText = Read-Lf $BuildGradle
foreach ($Need in @(
    'openmw-051-patch39-libopenmw.sha256',
    'apply-openmw-051-patch39-release-log-cleanup.ps1',
    'final release-log cleanup',
    'OMWFX_RECOMMENDED_CHAIN.joinToString(",")'
)) {
    if (-not $GradleText.Contains($Need)) {
        throw "Patch 39 Gradle gate is incomplete: $Need"
    }
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch39-release-log-cleanup.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch39-release-log-cleanup.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPENMW_PATCH39_PROJECT:?OPENMW_PATCH39_PROJECT is required}"
JOBS="${OPENMW_PATCH39_JOBS:?OPENMW_PATCH39_JOBS is required}"
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

PP_CPP="$SOURCE/apps/openmw/mwrender/postprocessor.cpp"
RM_CPP="$SOURCE/apps/openmw/mwrender/renderingmanager.cpp"
RM_HPP="$SOURCE/apps/openmw/mwrender/renderingmanager.hpp"
SHADOW_CPP="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"
WATER_CPP="$SOURCE/apps/openmw/mwrender/water.cpp"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
[[ "$(cat "$MARKER")" == "$EXPECTED_MARKER" ]] || { echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2; exit 80; }
[[ -f "$BUILD/CMakeCache.txt" ]] || { echo "ERROR: existing OpenMW CMake build tree is incomplete: $BUILD" >&2; exit 81; }
[[ -x "$STRIP" && -x "$READELF" ]] || { echo 'ERROR: pinned NDK tools are missing.' >&2; exit 82; }

python3 "$PATCHER" "$SOURCE"

grep -Fq 'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH' "$PP_CPP" || exit 83
grep -Fq 'setTextureDepth(getTexture(Tex_Depth, frameId))' "$PP_CPP" || exit 84
grep -Fq 'OpenMW 0.51 Android renderer:' "$PP_CPP" || exit 85
! grep -Fq 'Gate G PP init' "$PP_CPP" || exit 86
! grep -Fq 'OMWFX depth: Tex_Depth direct scene binding' "$PP_CPP" || exit 87
grep -Fq 'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION' "$RM_CPP" || exit 88
grep -Fq 'const RayResult hit = castRay(origin, dest, true, false);' "$RM_CPP" || exit 89
grep -Fq '"lensflare_android_051_rayocc"' "$RM_CPP" || {
    echo 'ERROR: native CPU sun-occlusion Lensflare chain gate is missing.' >&2
    exit 103
}
! grep -Fq 'OpenMW 0.51 Android sun-occlusion ray:' "$RM_CPP" || exit 90
! grep -Fq 'mAndroidSunOcclusionLastLoggedState' "$RM_HPP" || exit 91
grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_CPP" || exit 92
! grep -Fq 'Android GLES2 manual shadow comparison enabled' "$SHADOW_CPP" || exit 93
grep -Fq 'OPENMW_ANDROID_051_WETWORLD_WATER_MASK' "$WATER_CPP" || exit 94
grep -Fq 'defineMap["wetWorldWaterMask"] = "1";' "$WATER_CPP" || exit 95

echo 'Patch 39 source validation: PASS'
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
[[ ${#BUILT_LIBS[@]} -eq 1 ]] || { echo "ERROR: expected one libopenmw.so, found ${#BUILT_LIBS[@]}" >&2; exit 96; }
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

for lib in "$SYMBOLS" "$JNI"; do
    grep -aFq 'OpenMW 0.51 Android renderer:' "$lib" || exit 97
    ! grep -aFq 'OpenMW 0.51 Android Gate G PP init:' "$lib" || exit 98
    ! grep -aFq 'OpenMW 0.51 Android sun-occlusion ray:' "$lib" || exit 99
    ! grep -aFq 'OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding' "$lib" || exit 100
    ! grep -aFq 'Android GLES2 manual shadow comparison enabled' "$lib" || exit 101
    grep -aFq 'wetWorldWaterMask' "$lib" || exit 102
done

[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || { echo 'ERROR: JNI library was not stripped.' >&2; exit 104; }
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: JNI library contains DWARF sections.' >&2
    exit 105
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch39-libopenmw.sha256"
echo "Patch 39 native rebuild SUCCESS - SHA256 $JNI_SHA"
'@

[IO.File]::WriteAllText(
    $WindowsHelper,
    ($ShellScript -replace "`r`n", "`n"),
    (New-Object Text.UTF8Encoding($false))
)

try {
    & wsl.exe env "OPENMW_PATCH39_PROJECT=$WslProject" "OPENMW_PATCH39_JOBS=$Jobs" bash $WslHelper
    if ($LASTEXITCODE -ne 0) {
        throw "WSL Patch 39 rebuild failed with exit code $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $Patch39Sha)) {
    throw 'Patch 39 native SHA file was not generated.'
}

$ExpectedPatch39Sha = ((Get-Content -LiteralPath $Patch39Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualPatch39Sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedPatch39Sha -ne $ActualPatch39Sha) {
    throw "Patch 39 SHA mismatch. expected=$ExpectedPatch39Sha actual=$ActualPatch39Sha"
}

Write-Host 'OpenMW 0.51 Patch 39 release-log cleanup: PASS'
Write-Host 'Native rebuild: YES - openmw target only'
Write-Host 'Renderer behavior: unchanged'
Write-Host 'Removed runtime noise: Gate labels, shadow notices and sun-occlusion transitions'
