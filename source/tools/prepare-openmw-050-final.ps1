param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = '47d78e004bc182def2904986f8bb54aea1f4b3ae'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$CMakeFile = Join-Path $ProjectRoot 'buildscripts\CMakeLists.txt'
$BuildSh = Join-Path $ProjectRoot 'buildscripts\build.sh'
$GradleFile = Join-Path $ProjectRoot 'app\build.gradle'
$PatchDir = Join-Path $ProjectRoot 'buildscripts\patches\openmw050-final'
$PostFxPatcher = Join-Path $PatchDir 'apply-postprocessing-final.py'
$FormatPatcher = Join-Path $PatchDir 'apply-ndk-r26-format.py'
$ShadowPatcher = Join-Path $PatchDir 'apply-android-shadow-gles2-manual-compare.py'
$OsgShadowPatch = Join-Path $ProjectRoot 'buildscripts\patches\osg\android-shadow-texture-compat.patch'

foreach ($Required in @($CMakeFile, $BuildSh, $GradleFile, $PostFxPatcher, $FormatPatcher, $ShadowPatcher, $OsgShadowPatch)) {
    if (-not (Test-Path $Required)) {
        throw "Missing OpenMW 0.50 migration file: $Required"
    }
}

foreach ($Patch in @(
    '0001-gl4es-shaders.patch',
    '0002-android-lifecycle.patch',
    '0003-android-ui.patch',
    '0004-static-osg-link.patch',
    '0005-gl4es-save-psa.patch',
    '0006-ndk-r26-stringstream-compat.patch',
    '0007-android-shadow-depth-clamp-fallback.patch'
)) {
    $Path = Join-Path $PatchDir $Patch
    if (-not (Test-Path $Path)) {
        throw "Missing OpenMW 0.50 Android patch: $Path"
    }
}

$CMake = Read-Lf $CMakeFile

# Pin exactly the official OpenMW 0.50.0 Final release commit.
$VersionPattern = '(?m)^set\(OPENMW_VERSION\s+[^)]+\)$'
$VersionMatches = [regex]::Matches($CMake, $VersionPattern)
if ($VersionMatches.Count -ne 1) {
    throw "Expected exactly one OPENMW_VERSION definition, found $($VersionMatches.Count)."
}
$WantedVersion = "set(OPENMW_VERSION $FinalCommit)"
if ($VersionMatches[0].Value -ne $WantedVersion) {
    $OldVersion = $VersionMatches[0].Value
    $CMake = $CMake.Replace($OldVersion, $WantedVersion)
    Write-Host "OpenMW 0.50 Final: changed engine pin from $OldVersion to $WantedVersion." -ForegroundColor Cyan
}

$OldCommentPattern = '(?m)^# OpenMW 0\.49\.0 Final.*$'
$CMake = [regex]::Replace(
    $CMake,
    $OldCommentPattern,
    '# OpenMW 0.50.0 Final — immutable commit behind tag openmw-0.50.0',
    1
)

$WantedPatchBlock = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0001-gl4es-shaders.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0002-android-lifecycle.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0003-android-ui.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0004-static-osg-link.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0005-gl4es-save-psa.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0006-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw050-final/0007-android-shadow-depth-clamp-fallback.patch &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw050-final/apply-android-shadow-gles2-manual-compare.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw050-final/apply-ndk-r26-format.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw050-final/apply-postprocessing-final.py <SOURCE_DIR>
)
'@

$PatchPattern = '(?ms)^set\(OPENMW_PATCH\s*\n.*?^\)\s*$'
$PatchMatches = [regex]::Matches($CMake, $PatchPattern)
if ($PatchMatches.Count -ne 1) {
    throw "Expected exactly one OPENMW_PATCH block, found $($PatchMatches.Count)."
}
if ($PatchMatches[0].Value.Trim() -ne $WantedPatchBlock.Trim()) {
    $CMake = $CMake.Remove($PatchMatches[0].Index, $PatchMatches[0].Length).Insert(
        $PatchMatches[0].Index,
        $WantedPatchBlock.TrimEnd()
    )
    Write-Host 'OpenMW 0.50 Final: installed clean Android patch chain.' -ForegroundColor Cyan
}

Write-Utf8Lf $CMakeFile $CMake

# Build-script marker must match the same immutable engine.
$Build = Read-Lf $BuildSh
$Build = $Build.Replace('OpenMW 0.49.0 Final', 'OpenMW 0.50.0 Final')
$Build = $Build.Replace('675146bd8bce6245d78889f543b5c02a1e3936fe', $FinalCommit)
Write-Utf8Lf $BuildSh $Build

# Gradle must reject stale 0.49 payloads after the migration.
$Gradle = Read-Lf $GradleFile
if (-not $Gradle.Contains('def openMwVersionCode = 50')) {
    throw 'app/build.gradle is not the v14/OpenMW 0.50 version.'
}
if (-not $Gradle.Contains($FinalCommit)) {
    throw 'app/build.gradle does not verify the OpenMW 0.50 Final commit.'
}

# If an old OpenMW ExternalProject exists, force only that project to refresh.
# Dependencies/toolchain/prefix remain reusable.
$OpenMwPrefix = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix'
if (Test-Path $OpenMwPrefix) {
    $OldMarker = Join-Path $OpenMwPrefix 'src\openmw\CMakeLists.txt'
    if (Test-Path $OldMarker) {
        $SourceCMake = Read-Lf $OldMarker
        if ($SourceCMake -notmatch 'set\(OPENMW_VERSION_MINOR 50\)') {
            Remove-Item $OpenMwPrefix -Recurse -Force
            Write-Host 'OpenMW 0.50 Final: removed stale pre-0.50 OpenMW ExternalProject tree.' -ForegroundColor Yellow
        }
    }
}

# Structural verification.
$Verify = Read-Lf $CMakeFile
foreach ($Token in @(
    "set(OPENMW_VERSION $FinalCommit)",
    'patches/openmw050-final/0001-gl4es-shaders.patch',
    'patches/openmw050-final/0006-ndk-r26-stringstream-compat.patch',
    'patches/openmw050-final/0007-android-shadow-depth-clamp-fallback.patch',
    'patches/osg/android-shadow-texture-compat.patch',
    'apply-android-shadow-gles2-manual-compare.py',
    'apply-ndk-r26-format.py',
    'apply-postprocessing-final.py'
)) {
    if (-not $Verify.Contains($Token)) {
        throw "OpenMW 0.50 setup verification failed: missing $Token"
    }
}

$FormatPatcherText = Read-Lf $FormatPatcher
foreach ($Token in @(
    'OPENMW_ANDROID_NDK_R26_EXPERIMENTAL_FORMAT',
    'OPENMW_ANDROID_NDK_R26_FORMAT_PROBE',
    'OPENMW_ANDROID_NDK_R26_EXPERIMENTAL_FORMAT_LINK',
    'c++experimental',
    '-fexperimental-library'
)) {
    if (-not $FormatPatcherText.Contains($Token)) {
        throw "OpenMW 0.50 NDK r26 format patch verification failed: missing $Token"
    }
}

$ShadowPatcherText = Read-Lf $ShadowPatcher
foreach ($Token in @(
    'OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE',
    'sampler2DShadow',
    'shadow2DProj',
    'setShadowComparison(false)'
)) {
    if (-not $ShadowPatcherText.Contains($Token)) {
        throw "OpenMW 0.50 GLES2 shadow patch verification failed: missing $Token"
    }
}

$OsgShadowPatchText = Read-Lf $OsgShadowPatch
if (-not $OsgShadowPatchText.Contains('OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE')) {
    throw 'OpenMW 0.50 OSG GLES2 shadow compatibility patch is missing its marker.'
}

Write-Host ''
Write-Host 'OpenMW Android native source setup: READY' -ForegroundColor Green
Write-Host "Pinned engine: OpenMW 0.50.0 Final / $FinalCommit"
Write-Host 'Android patch set: GL4ES shaders + GLES2 manual shadow compare + lifecycle + UI + static OSG + save PSA + NDK r26 + consolidated post-processing startup'
