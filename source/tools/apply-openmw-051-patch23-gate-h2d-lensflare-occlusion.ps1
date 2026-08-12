param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 23 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 23 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$bloom = Require-File "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$lens = Require-File "app/src/main/assets/android_omwfx/lensflare_android_051_occ.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 23 Gate H2d runtime" "MainActivity runtime marker is missing."
Require-Text $main '"lensflare_android_051_occ,gateh_bloom051"' "MainActivity does not select the H2d chain."
Require-Text $main "LENSFLARE051-OCCLUDED+NATIVE-SUNGLARE+BLOOM" "MainActivity H2d stage marker is missing."
Require-Text $main 'val gateH2dBlockedShaders = listOf(' "H2d blocked-shader list is not declared."
Require-Text $gradle "Patch 23" "Gradle Patch-23 marker is missing."
Require-Text $gradle "lensflare_android_051_occ.omwfx" "Gradle does not validate the H2d lens flare asset."

$bloomText = Get-Content -LiteralPath $bloom -Raw
foreach ($needle in @(
    "uniform_float uThreshold {`n    default = 0.30;",
    "uniform_float uSkyFactor {`n    default = 0.60;",
    "uniform_float uRadius {`n    default = 0.55;",
    "uniform_float uStrength {`n    default = 0.35;"
)) {
    if (-not $bloomText.Contains($needle)) {
        throw "Patch 23 bloom baseline validation failed: missing $needle"
    }
}

$lensText = Get-Content -LiteralPath $lens -Raw
foreach ($needle in @(
    'vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);',
    'float skyVisibility051(vec2 uv)',
    'float sunOcclusion051(vec2 sunUv)',
    'float openFraction = visible / 13.0;',
    'return smoothstep(0.70, 0.94, openFraction);',
    'float visibility = omw.sunVis * edgeFade051(sunUv) * occlusion;',
    'passes = main;',
    'version = "2.1-051-occ";'
)) {
    if (-not $lensText.Contains($needle)) {
        throw "Patch 23 lens flare validation failed: missing $needle"
    }
}
if ($lensText.Contains('Disable_SunGlare')) {
    throw "Patch 23 isolation failed: H2d must retain OpenMW builtin sunglare."
}

$mainText = Get-Content -LiteralPath $main -Raw
$runtimeStartMarker = "private fun applyOpenMw051RuntimeGateSettings()"
$runtimeEndMarker = "// v14.2 OpenMW 0.50 launcher settings"
$runtimeStart = $mainText.IndexOf($runtimeStartMarker)
if ($runtimeStart -lt 0) { throw "Patch 23 validation failed: active runtime function missing." }
$runtimeEnd = $mainText.IndexOf($runtimeEndMarker, $runtimeStart)
if ($runtimeEnd -lt 0) { throw "Patch 23 validation failed: runtime function delimiter missing." }
$runtimeText = $mainText.Substring($runtimeStart, $runtimeEnd - $runtimeStart)
if (-not $runtimeText.Contains('"lensflare_android_051_occ,gateh_bloom051"')) {
    throw "Patch 23 validation failed: active runtime chain is not H2d."
}
foreach ($obsoleteChain in @('"lensflare_android_051,gateh_bloom051"','"lensflare_android,gateh_bloom051"')) {
    if ($runtimeText.Contains($obsoleteChain)) {
        throw "Patch 23 isolation failed: obsolete lensflare chain remains active: $obsoleteChain"
    }
}

$syncStart = $mainText.IndexOf('val gateH2dBlockedShaders = listOf(')
if ($syncStart -lt 0) { throw "Patch 23 validation failed: H2d cleanup list missing." }
$syncEnd = $mainText.IndexOf(')', $syncStart)
$blockedText = $mainText.Substring($syncStart, $syncEnd - $syncStart)
foreach ($requiredOld in @('"lensflare_android.omwfx"','"lensflare_android_051.omwfx"','"godrays_android.omwfx"','"rainlens_android.omwfx"','"wetworld_android.omwfx"')) {
    if (-not $blockedText.Contains($requiredOld)) {
        throw "Patch 23 validation failed: obsolete/isolated shader is not removed: $requiredOld"
    }
}
if ($blockedText.Contains('"lensflare_android_051_occ.omwfx"')) {
    throw "Patch 23 isolation failed: active H2d lens flare is in its own delete list."
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha."
}

Write-Host "OpenMW 0.51 Patch 23 Gate H2d validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "OMWFX runtime chain: lensflare_android_051_occ,gateh_bloom051"
Write-Host "Lensflare occlusion: 13-sample OpenMW-0.51 far-depth mask; strict foliage suppression"
Write-Host "Builtin sunglare: RETAINED"
Write-Host "Godrays/RainLens/WetWorld: still isolated"
Write-Host "Expected: flare visible only when the sun disc is substantially unobstructed"
