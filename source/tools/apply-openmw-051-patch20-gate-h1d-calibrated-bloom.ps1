param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 20 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 20 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$bloom = Require-File "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 20 Gate H1d runtime" "MainActivity runtime marker is missing."
Require-Text $main '"gateh_bloom051"' "MainActivity does not select the unique 0.51 bloom technique."
Require-Text $main "OPENMW051-BLOOM-CALIBRATED" "MainActivity H1d stage marker is missing."
Require-Text $gradle "Patch 20" "Gradle Patch-20 marker is missing."
Require-Text $gradle "gateh_bloom051.omwfx" "Gradle does not validate the H1d bloom asset."

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
        throw "Patch 20 calibrated bloom validation failed: missing $needle"
    }
}

# Guard against accidentally retaining either Patch-18 diagnostic or Patch-19 conservative defaults.
foreach ($oldDefault in @(
    "uniform_float uThreshold {`n    default = 0.20;",
    "uniform_float uThreshold {`n    default = 0.40;",
    "uniform_float uSkyFactor {`n    default = 1.00;",
    "uniform_float uSkyFactor {`n    default = 0.25;",
    "uniform_float uRadius {`n    default = 0.50;",
    "uniform_float uStrength {`n    default = 0.20;",
    "uniform_float uStrength {`n    default = 0.60;"
)) {
    if ($bloomText.Contains($oldDefault)) {
        throw "Patch 20 isolation failed: obsolete bloom default remains: $oldDefault"
    }
}

$mainText = Get-Content -LiteralPath $main -Raw
$runtimeStartMarker = "private fun applyOpenMw051RuntimeGateSettings()"
$runtimeEndMarker = "// v14.2 OpenMW 0.50 launcher settings"
$runtimeStart = $mainText.IndexOf($runtimeStartMarker)
if ($runtimeStart -lt 0) {
    throw "Patch 20 validation failed: active 0.51 runtime gate function was not found."
}
$runtimeEnd = $mainText.IndexOf($runtimeEndMarker, $runtimeStart)
if ($runtimeEnd -lt 0) {
    throw "Patch 20 validation failed: could not delimit active 0.51 runtime gate function."
}
$runtimeText = $mainText.Substring($runtimeStart, $runtimeEnd - $runtimeStart)
if (-not $runtimeText.Contains('"gateh_bloom051"')) {
    throw "Patch 20 validation failed: active runtime gate does not select gateh_bloom051."
}
foreach ($oldChain in @('"gateh_probe"', '"lensflare_android,bloomlinear_android"', '"bloomlinear_android"')) {
    if ($runtimeText.Contains($oldChain)) {
        throw "Patch 20 isolation failed: obsolete Gate-H chain remains in active runtime block: $oldChain"
    }
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha."
}

Write-Host "OpenMW 0.51 Patch 20 Gate H1d calibrated-bloom validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "OMWFX runtime chain: gateh_bloom051"
Write-Host "Calibrated defaults: threshold=0.30, skyFactor=0.60, radius=0.55, strength=0.35, gamma=2.20, clamp=1.00"
Write-Host "Expected visual result: clearly stronger than Patch 19, controlled below Patch 18 diagnostic strength"
