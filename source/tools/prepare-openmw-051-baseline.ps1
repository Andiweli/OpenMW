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

foreach ($Required in @(
    $CMakeFile,
    $VersionFile,
    (Join-Path $PatchDir '0001-ndk-r26-stringstream-compat.patch'),
    (Join-Path $PatchDir '0002-static-osg-link.patch'),
    $FormatPatcher
)) {
    if (-not (Test-Path $Required)) {
        throw "Missing OpenMW 0.51 baseline migration file: $Required"
    }
}

# Keep the proven Android dependency/toolchain baseline unchanged while only
# replacing the OpenMW engine itself.
$CMakeBefore = Read-Lf $CMakeFile
foreach ($Token in @(
    'set(GL4ES_VERSION 5ac069d82ad8ca2cc3c574484e4c5bad880db83e)',
    'set(OSG_VERSION 69cfecebfb6dc703b42e8de39eed750a84a87489)',
    '-DOPENMW_GL4ES_MANUAL_INIT=OFF',
    '-DCMAKE_CXX_STANDARD=20',
    '-DOSG_STATIC=TRUE'
)) {
    if (-not $CMakeBefore.Contains($Token)) {
        throw "0.51 baseline safety check failed: expected unchanged build token is missing: $Token"
    }
}

$VersionText = Read-Lf $VersionFile
if (-not $VersionText.Contains('NDK_VERSION="r26b"')) {
    throw '0.51 baseline safety check failed: Android NDK is no longer r26b.'
}

$CMake = $CMakeBefore

# Pin exactly the official OpenMW 0.51.0 Final release commit.
$VersionPattern = '(?m)^set\(OPENMW_VERSION\s+[^)]+\)$'
$VersionMatches = [regex]::Matches($CMake, $VersionPattern)
if ($VersionMatches.Count -ne 1) {
    throw "Expected exactly one OPENMW_VERSION definition, found $($VersionMatches.Count)."
}
$WantedVersion = "set(OPENMW_VERSION $FinalCommit)"
if ($VersionMatches[0].Value -ne $WantedVersion) {
    $OldVersion = $VersionMatches[0].Value
    $CMake = $CMake.Replace($OldVersion, $WantedVersion)
    Write-Host "OpenMW 0.51 baseline: changed engine pin from $OldVersion to $WantedVersion." -ForegroundColor Cyan
}

$CommentPattern = '(?m)^# OpenMW 0\.(49|50|51).*?$'
if ([regex]::IsMatch($CMake, $CommentPattern)) {
    $CMake = [regex]::Replace(
        $CMake,
        $CommentPattern,
        '# OpenMW 0.51.0 Final baseline — immutable commit behind tag openmw-0.51.0',
        1
    )
}

# Patch 1 intentionally contains only build/toolchain compatibility. Graphics,
# lifecycle, shadow and post-processing changes are deferred until this baseline
# compiles and links successfully against the exact 0.51 Final source.
$WantedPatchBlock = @'
set(OPENMW_PATCH
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw051-final/0001-ndk-r26-stringstream-compat.patch &&
        patch -d <SOURCE_DIR> -p1 -t -N < ${CMAKE_SOURCE_DIR}/patches/openmw051-final/0002-static-osg-link.patch &&
        python3 ${CMAKE_SOURCE_DIR}/patches/openmw051-final/apply-ndk-r26-format.py <SOURCE_DIR>
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
    Write-Host 'OpenMW 0.51 baseline: installed minimal compatibility patch chain.' -ForegroundColor Cyan
}

Write-Utf8Lf $CMakeFile $CMake

# Force only the OpenMW ExternalProject source/build tree to refresh when it is
# still 0.49/0.50. All expensive third-party dependency prefixes stay reusable.
$OpenMwPrefix = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix'
if (Test-Path $OpenMwPrefix) {
    $OldMarker = Join-Path $OpenMwPrefix 'src\openmw\CMakeLists.txt'
    if (Test-Path $OldMarker) {
        $SourceCMake = Read-Lf $OldMarker
        if ($SourceCMake -notmatch 'set\(OPENMW_VERSION_MINOR\s+51\)') {
            Remove-Item $OpenMwPrefix -Recurse -Force
            Write-Host 'OpenMW 0.51 baseline: removed stale pre-0.51 OpenMW ExternalProject tree.' -ForegroundColor Yellow
        }
    }
}

# Structural verification.
$Verify = Read-Lf $CMakeFile
foreach ($Token in @(
    "set(OPENMW_VERSION $FinalCommit)",
    'patches/openmw051-final/0001-ndk-r26-stringstream-compat.patch',
    'patches/openmw051-final/0002-static-osg-link.patch',
    'patches/openmw051-final/apply-ndk-r26-format.py'
)) {
    if (-not $Verify.Contains($Token)) {
        throw "OpenMW 0.51 baseline setup verification failed: missing $Token"
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
        throw "0.51 baseline accidentally still applies a deferred 0.50 patch: $Forbidden"
    }
}


if ($Verify.Contains('patches/osg/psa.patch')) {
    throw '0.51 baseline must not schedule the obsolete OSG GL4ES_SavePSA shim for a clean dependency rebuild.'
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
        throw "OpenMW 0.51 NDK r26 format patch verification failed: missing $Token"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 native baseline setup: READY' -ForegroundColor Green
Write-Host "Pinned engine: OpenMW 0.51.0 Final / $FinalCommit"
Write-Host 'Active patch set: NDK r26 stringstream + static OSG link + NDK r26 std::format only'
Write-Host 'Deferred OpenMW-engine patches: GL4ES shaders, lifecycle, UI, PSA save, shadows, post-processing/OMWFX'
Write-Host 'Dependency versions stay unchanged; obsolete OSG GL4ES_SavePSA shim is no longer scheduled on clean rebuilds.'
