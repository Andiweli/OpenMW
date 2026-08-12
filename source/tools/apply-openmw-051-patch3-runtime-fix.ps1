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

$AssetRoot = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw'
$ResourceRoot = Join-Path $AssetRoot 'resources'
$Marker = Join-Path $AssetRoot 'openmw\openmw-engine-version.txt'
$BaseCfg = Join-Path $AssetRoot 'openmw\openmw.base.cfg'
$BuildResourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build\resources'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'

foreach ($Required in @($Marker, $BaseCfg, $ResourceRoot)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 3 requires the successful Patch-2 0.51 runtime payload. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $Marker) -ne $ExpectedMarker) {
    throw "Patch 3 refused a non-0.51 payload: $Marker"
}

# OpenMW 0.51's new engine-owned Morrowind compatibility data lives in vfs-mw.
# If an earlier payload deployment omitted it, recover the complete directory
# from the already-built OpenMW 0.51 resource output without rebuilding native code.
$AssetVfsMw = Join-Path $ResourceRoot 'vfs-mw'
$AssetEsmFallbacks = Join-Path $AssetVfsMw 'scripts\omw\esmfallbacks.lua'
if (-not (Test-Path $AssetEsmFallbacks)) {
    $BuildVfsMw = Join-Path $BuildResourceRoot 'vfs-mw'
    $BuildEsmFallbacks = Join-Path $BuildVfsMw 'scripts\omw\esmfallbacks.lua'
    if (-not (Test-Path $BuildEsmFallbacks)) {
        throw "OpenMW 0.51 vfs-mw is missing from both APK assets and the completed native build output. Expected: $BuildEsmFallbacks"
    }
    if (Test-Path $AssetVfsMw) { Remove-Item $AssetVfsMw -Recurse -Force }
    Copy-Item $BuildVfsMw $AssetVfsMw -Recurse
    Write-Host 'Recovered OpenMW 0.51 resources\vfs-mw from the existing native build output.' -ForegroundColor Cyan
}

$VertexHeader = @'
// OPENMW_ANDROID_051_GL4ES_CORE_INLINE
// GL4ES/GLES2 compatibility: keep helper implementations in the consuming
// shader instead of linking a helper-only shader object without main().
uniform mat4 projectionMatrix;

vec4 modelToView(vec4 pos)
{
    return gl_ModelViewMatrix * pos;
}

vec4 modelToClip(vec4 pos)
{
    return projectionMatrix * modelToView(pos);
}

vec4 viewToClip(vec4 pos)
{
    return projectionMatrix * pos;
}
'@

$FragmentHeader = @'
#ifndef OPENMW_FRAGMENT_H_GLSL
#define OPENMW_FRAGMENT_H_GLSL

// OPENMW_ANDROID_051_GL4ES_CORE_INLINE
// GL4ES/GLES2 compatibility: inline the helper implementations. The stock
// OpenMW 0.51 helper-link path creates helper-only shader objects which the tested
// Adreno GLES compiler rejects because they contain no main().
uniform sampler2D reflectionMap;

vec4 sampleReflectionMap(vec2 uv)
{
    return texture2D(reflectionMap, uv);
}

#if @waterRefraction
uniform sampler2D refractionMap;
uniform highp sampler2D refractionDepthMap;

vec4 sampleRefractionMap(vec2 uv)
{
    return texture2D(refractionMap, uv);
}

float sampleRefractionDepthMap(vec2 uv)
{
    return texture2D(refractionDepthMap, uv).x;
}
#endif

uniform sampler2D lastShader;

vec4 samplerLastShader(vec2 uv)
{
    return texture2D(lastShader, uv);
}

#if @skyBlending
uniform sampler2D sky;

vec3 sampleSkyColor(vec2 uv)
{
    return texture2D(sky, uv).xyz;
}
#endif

uniform highp sampler2D opaqueDepthTex;

vec4 sampleOpaqueDepthTex(vec2 uv)
{
    return texture2D(opaqueDepthTex, uv);
}

#endif  // OPENMW_FRAGMENT_H_GLSL
'@

function Install-CoreHeader([string]$Root, [string]$Relative, [string]$Wanted) {
    if (-not (Test-Path $Root)) { return }
    $Path = Join-Path $Root $Relative
    if (-not (Test-Path $Path)) {
        throw "Expected OpenMW 0.51 shader header is missing: $Path"
    }
    $Current = Read-Lf $Path
    if ($Current.Contains('OPENMW_ANDROID_051_GL4ES_CORE_INLINE')) {
        if ($Current.TrimEnd() -ne $Wanted.TrimEnd()) {
            throw "Patch 3 marker exists but shader content is unexpected: $Path"
        }
        return
    }
    if (-not $Current.Contains('@link "lib/core/')) {
        throw "Patch 3 refused unexpected shader architecture: $Path"
    }
    Write-Utf8Lf $Path ($Wanted.TrimEnd() + "`n")
}

$VertexRelative = 'shaders\lib\core\vertex.h.glsl'
$FragmentRelative = 'shaders\lib\core\fragment.h.glsl'
Install-CoreHeader $ResourceRoot $VertexRelative $VertexHeader
Install-CoreHeader $ResourceRoot $FragmentRelative $FragmentHeader

# Keep the already-extracted OpenMW source and CMake resource output coherent so
# a later incremental native build cannot silently reintroduce the broken files.
if (Test-Path $SourceRoot) {
    Install-CoreHeader (Join-Path $SourceRoot 'files') $VertexRelative $VertexHeader
    Install-CoreHeader (Join-Path $SourceRoot 'files') $FragmentRelative $FragmentHeader
}
if (Test-Path $BuildResourceRoot) {
    Install-CoreHeader $BuildResourceRoot $VertexRelative $VertexHeader
    Install-CoreHeader $BuildResourceRoot $FragmentRelative $FragmentHeader
}

# Restore the upstream 0.51 internal data intent in the packaged base config.
# MainActivity Patch 3 will rewrite this to the absolute writable Android mirror
# after CaveBros' generic data= writer has run.
$Base = Read-Lf $BaseCfg
if (-not $Base.Contains('vfs-mw')) {
    $ResourceLinePattern = '(?m)^resources=.*$'
    $Matches = [regex]::Matches($Base, $ResourceLinePattern)
    if ($Matches.Count -ne 1) {
        throw "Cannot safely add vfs-mw to openmw.base.cfg: expected one resources= line, found $($Matches.Count)."
    }
    $Line = $Matches[0].Value
    $Base = $Base.Replace($Line, $Line + "`ndata=./resources/vfs-mw")
    Write-Utf8Lf $BaseCfg $Base
}

$AssetVertex = Join-Path $ResourceRoot $VertexRelative
$AssetFragment = Join-Path $ResourceRoot $FragmentRelative
foreach ($Path in @($AssetVertex, $AssetFragment, $AssetEsmFallbacks)) {
    if (-not (Test-Path $Path)) { throw "Patch 3 verification failed: missing $Path" }
}
if ((Read-Lf $AssetVertex).Contains('@link "lib/core/vertex.glsl"') -or
    (Read-Lf $AssetFragment).Contains('@link "lib/core/fragment.glsl"')) {
    throw 'Patch 3 verification failed: a GL4ES-hostile core @link remains in APK resources.'
}
if (-not (Read-Lf $BaseCfg).Contains('vfs-mw')) {
    throw 'Patch 3 verification failed: openmw.base.cfg still lacks vfs-mw.'
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 3 runtime resource fix: SUCCESS' -ForegroundColor Green
Write-Host 'Native libopenmw.so was NOT rebuilt and was NOT modified.' -ForegroundColor Green
Write-Host 'Fixed: GL4ES core helper shader linking + OpenMW 0.51 vfs-mw data path.'
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio.' -ForegroundColor Cyan
