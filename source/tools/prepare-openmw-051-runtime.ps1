param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$CMakeFile = Join-Path $ProjectRoot 'buildscripts\CMakeLists.txt'
$VersionFile = Join-Path $ProjectRoot 'buildscripts\include\version.sh'
$PatchDir = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final'
$FormatPatcher = Join-Path $PatchDir 'apply-ndk-r26-format.py'
$RuntimePatcher = Join-Path $PatchDir 'apply-android-runtime-baseline.py'
$Gl4esCorePatcher = Join-Path $PatchDir 'apply-android-gl4es-core-inline.py'

foreach ($Required in @(
    $CMakeFile,
    $VersionFile,
    (Join-Path $PatchDir '0001-ndk-r26-stringstream-compat.patch'),
    (Join-Path $PatchDir '0002-static-osg-link.patch'),
    $FormatPatcher,
    $RuntimePatcher,
    $Gl4esCorePatcher
)) {
    if (-not (Test-Path $Required)) {
        throw "Missing OpenMW 0.51 runtime migration file: $Required"
    }
}

$CMakeBefore = Read-Lf $CMakeFile
foreach ($Token in @(
    'set(GL4ES_VERSION 5ac069d82ad8ca2cc3c574484e4c5bad880db83e)',
    'set(OSG_VERSION 69cfecebfb6dc703b42e8de39eed750a84a87489)',
    '-DOPENMW_GL4ES_MANUAL_INIT=OFF',
    '-DCMAKE_CXX_STANDARD=20',
    '-DOSG_STATIC=TRUE'
)) {
    if (-not $CMakeBefore.Contains($Token)) {
        throw "0.51 runtime safety check failed: expected unchanged build token is missing: $Token"
    }
}

$VersionText = Read-Lf $VersionFile
if (-not $VersionText.Contains('NDK_VERSION="r26b"')) {
    throw '0.51 runtime safety check failed: Android NDK is no longer r26b.'
}

$CMake = $CMakeBefore
$VersionPattern = '(?m)^set\(OPENMW_VERSION\s+[^)]+\)$'
$VersionMatches = [regex]::Matches($CMake, $VersionPattern)
if ($VersionMatches.Count -ne 1) {
    throw "Expected exactly one OPENMW_VERSION definition, found $($VersionMatches.Count)."
}
$WantedVersion = "set(OPENMW_VERSION $FinalCommit)"
if ($VersionMatches[0].Value -ne $WantedVersion) {
    $CMake = $CMake.Replace($VersionMatches[0].Value, $WantedVersion)
}

$CommentPattern = '(?m)^# OpenMW 0\.(49|50|51).*?$'
if ([regex]::IsMatch($CMake, $CommentPattern)) {
    $CMake = [regex]::Replace(
        $CMake,
        $CommentPattern,
        '# OpenMW 0.51.0 Final Android runtime gate — immutable commit behind tag openmw-0.51.0',
        1
    )
}

$WantedPatchBlock = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw051-final/0001-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw051-final/0002-static-osg-link.patch &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-ndk-r26-format.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-runtime-baseline.py <SOURCE_DIR> &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-android-gl4es-core-inline.py <SOURCE_DIR>
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
    Write-Host 'OpenMW 0.51 runtime: installed Patch 3 Android runtime patch chain.' -ForegroundColor Cyan
}

Write-Utf8Lf $CMakeFile $CMake

# Patch 1 may already have produced an unpatched 0.51 ExternalProject tree.
# Refresh OpenMW only if the Patch-2 runtime marker is absent; all third-party
# dependency prefixes remain reusable.
$OpenMwPrefix = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix'
if (Test-Path $OpenMwPrefix) {
    $AndroidMainMarker = Join-Path $OpenMwPrefix 'src\openmw\apps\openmw\androidmain.cpp'
    $HasPatch2 = $false
    if (Test-Path $AndroidMainMarker) {
        $HasPatch2 = (Read-Lf $AndroidMainMarker).Contains('OPENMW_ANDROID_051_RUNTIME_BASELINE')
    }
    if (-not $HasPatch2) {
        Remove-Item $OpenMwPrefix -Recurse -Force
        Write-Host 'OpenMW 0.51 runtime: removed Patch-1 OpenMW tree so Patch 2 is applied cleanly.' -ForegroundColor Yellow
    }
}

$Verify = Read-Lf $CMakeFile
foreach ($Token in @(
    "set(OPENMW_VERSION $FinalCommit)",
    'patches/openmw051-final/0001-ndk-r26-stringstream-compat.patch',
    'patches/openmw051-final/0002-static-osg-link.patch',
    'patches/openmw051-final/apply-ndk-r26-format.py',
    'patches/openmw051-final/apply-android-runtime-baseline.py',
    'patches/openmw051-final/apply-android-gl4es-core-inline.py'
)) {
    if (-not $Verify.Contains($Token)) {
        throw "OpenMW 0.51 runtime setup verification failed: missing $Token"
    }
}

foreach ($Forbidden in @(
    'patches/openmw050-final/0001-gl4es-shaders.patch',
    'patches/openmw050-final/0002-android-lifecycle.patch',
    'patches/openmw050-final/0003-android-ui.patch',
    'patches/openmw050-final/0005-gl4es-save-psa.patch',
    'patches/openmw050-final/0007-android-shadow-depth-clamp-fallback.patch',
    'apply-android-shadow-gles2-manual-compare.py',
    'apply-postprocessing-final.py'
)) {
    if ($Verify.Contains($Forbidden)) {
        throw "0.51 runtime accidentally still applies a deferred 0.50 engine patch: $Forbidden"
    }
}

if ($Verify.Contains('patches/osg/psa.patch')) {
    throw '0.51 runtime must not schedule the obsolete OSG GL4ES_SavePSA shim.'
}

$RuntimeText = Read-Lf $RuntimePatcher
foreach ($Token in @(
    'OPENMW_ANDROID_051_RUNTIME_BASELINE',
    'OPENMW_ANDROID_051_LOADINGSCREEN_NO_FB_COPY',
    'SDL_HINT_ANDROID_BLOCK_ON_PAUSE',
    'uniform vec2 scaling;',
    'uniform bool useAdvancedShader;'
)) {
    if (-not $RuntimeText.Contains($Token)) {
        throw "OpenMW 0.51 runtime patch verification failed: missing $Token"
    }
}

$Gl4esCoreText = Read-Lf $Gl4esCorePatcher
foreach ($Token in @(
    'OPENMW_ANDROID_051_GL4ES_CORE_INLINE',
    'vec4 modelToClip(vec4 pos)',
    'vec4 sampleReflectionMap(vec2 uv)',
    'uniform highp sampler2D opaqueDepthTex;'
)) {
    if (-not $Gl4esCoreText.Contains($Token)) {
        throw "OpenMW 0.51 GL4ES core patch verification failed: missing $Token"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 3 runtime setup: READY' -ForegroundColor Green
Write-Host "Pinned engine: OpenMW 0.51.0 Final / $FinalCommit"
Write-Host 'Active engine patches: NDK r26 compatibility + static OSG + Android lifecycle + loading-screen workaround + GL4ES uniform syntax + core helper inlining'
Write-Host 'Runtime config fix: preserve/restore OpenMW 0.51 resources/vfs-mw before game/mod data paths'
Write-Host 'Still deferred: remaining GL4ES normal-space fixes, GLES2 shadow compare/depth-clamp, post-processing API 5 Android stabilization, OMWFX enablement'
