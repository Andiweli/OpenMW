param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 21 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 21 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$bloom = Require-File "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$lens = Require-File "app/src/main/assets/android_omwfx/lensflare_android.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 21 Gate H2b runtime" "MainActivity runtime marker is missing."
Require-Text $main '"lensflare_android,gateh_bloom051"' "MainActivity does not select the H2b lensflare+bloom chain."
Require-Text $main "LENSFLARE+CALIBRATED-BLOOM" "MainActivity H2b stage marker is missing."
Require-Text $gradle "Patch 21" "Gradle Patch-21 marker is missing."
Require-Text $gradle "gateh_bloom051.omwfx" "Gradle does not validate the H2b bloom asset."
Require-Text $gradle "lensflare_android.omwfx" "Gradle does not validate the H2b lens flare asset."

$bloomText = Get-Content -LiteralPath $bloom -Raw
foreach ($needle in @(
    'passes = nomipmap, horizontal, vertical, final;',
    'internal_format = rgb16f;',
    'source_type = half_float;',
    "uniform_float uThreshold {`n    default = 0.30;",
    "uniform_float uSkyFactor {`n    default = 0.60;",
    "uniform_float uRadius {`n    default = 0.55;",
    "uniform_float uStrength {`n    default = 0.35;"
)) {
    if (-not $bloomText.Contains($needle)) {
        throw "Patch 21 calibrated bloom validation failed: missing $needle"
    }
}

$lensText = Get-Content -LiteralPath $lens -Raw
foreach ($needle in @(
    "uniform_float flare_strength {`n    default = 0.27;",
    "uniform_float halo_size {`n    default = 0.18;",
    "uniform_float ghost_strength {`n    default = 0.13;",
    'float sunOcclusion(vec2 sunUv)',
    'omw.sunVis <= 0.001',
    'passes = main;',
    'version = "1.1";'
)) {
    if (-not $lensText.Contains($needle)) {
        throw "Patch 21 lens flare validation failed: missing $needle"
    }
}

$mainText = Get-Content -LiteralPath $main -Raw
$runtimeStartMarker = "private fun applyOpenMw051RuntimeGateSettings()"
$runtimeEndMarker = "// v14.2 OpenMW 0.50 launcher settings"
$runtimeStart = $mainText.IndexOf($runtimeStartMarker)
if ($runtimeStart -lt 0) {
    throw "Patch 21 validation failed: active 0.51 runtime gate function was not found."
}
$runtimeEnd = $mainText.IndexOf($runtimeEndMarker, $runtimeStart)
if ($runtimeEnd -lt 0) {
    throw "Patch 21 validation failed: could not delimit active 0.51 runtime gate function."
}
$runtimeText = $mainText.Substring($runtimeStart, $runtimeEnd - $runtimeStart)
foreach ($needle in @('"lensflare_android,gateh_bloom051"','"OPENMW051-BLOOM-CALIBRATED"')) { }
if (-not $runtimeText.Contains('"lensflare_android,gateh_bloom051"')) {
    throw "Patch 21 validation failed: active runtime gate does not select the lensflare+bloom chain."
}

$blockedStartMarker = "val gateH2bBlockedShaders = listOf("
$blockedEndMarker = ")`n        gateH2bBlockedShaders.forEach"
$blockedStart = $mainText.IndexOf($blockedStartMarker)
if ($blockedStart -lt 0) {
    throw "Patch 21 validation failed: gateH2bBlockedShaders declaration is missing."
}
$blockedEnd = $mainText.IndexOf($blockedEndMarker, $blockedStart)
if ($blockedEnd -lt 0) {
    throw "Patch 21 validation failed: gateH2bBlockedShaders block is malformed."
}
$blockedText = $mainText.Substring($blockedStart, $blockedEnd - $blockedStart)
if ($blockedText.Contains('lensflare_android.omwfx')) {
    throw "Patch 21 isolation failed: lensflare_android.omwfx is incorrectly present in the H2b deletion list."
}
foreach ($requiredBlocked in @('gateh_probe.omwfx','bloomlinear_android.omwfx','godrays_android.omwfx','rainlens_android.omwfx','wetworld_android.omwfx')) {
    if (-not $blockedText.Contains($requiredBlocked)) {
        throw "Patch 21 isolation failed: expected blocked shader is missing from H2b list: $requiredBlocked"
    }
}

foreach ($oldChain in @('"gateh_probe"', '"bloomlinear_android"')) {
    if ($runtimeText.Contains($oldChain)) {
        throw "Patch 21 isolation failed: obsolete Gate-H chain remains in active runtime block: $oldChain"
    }
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha."
}

Write-Host "OpenMW 0.51 Patch 21 Gate H2b lensflare+bloom validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "OMWFX runtime chain: lensflare_android,gateh_bloom051"
Write-Host "Bloom defaults: threshold=0.30, skyFactor=0.60, radius=0.55, strength=0.35"
Write-Host "Lens flare defaults: flare=0.27, halo=0.18, ghosts=0.13"
Write-Host "Expected visual result: visible solar halo and lens ghosts, then bloom softens the result"
