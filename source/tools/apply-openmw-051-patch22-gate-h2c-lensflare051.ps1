param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 22 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 22 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$bloom = Require-File "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$lens = Require-File "app/src/main/assets/android_omwfx/lensflare_android_051.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 22 Gate H2c runtime" "MainActivity runtime marker is missing."
Require-Text $main '"lensflare_android_051,gateh_bloom051"' "MainActivity does not select the H2c chain."
Require-Text $main "LENSFLARE051-VISIBILITY+NATIVE-SUNGLARE+BLOOM" "MainActivity H2c stage marker is missing."
Require-Text $main 'val gateH2cBlockedShaders = listOf(' "H2c blocked-shader list is not declared."
Require-Text $gradle "Patch 22" "Gradle Patch-22 marker is missing."
Require-Text $gradle "lensflare_android_051.omwfx" "Gradle does not validate the unique H2c lens flare asset."

$bloomText = Get-Content -LiteralPath $bloom -Raw
foreach ($needle in @(
    "uniform_float uThreshold {`n    default = 0.30;",
    "uniform_float uSkyFactor {`n    default = 0.60;",
    "uniform_float uRadius {`n    default = 0.55;",
    "uniform_float uStrength {`n    default = 0.35;"
)) {
    if (-not $bloomText.Contains($needle)) {
        throw "Patch 22 bloom baseline validation failed: missing $needle"
    }
}

$lensText = Get-Content -LiteralPath $lens -Raw
foreach ($needle in @(
    'vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);',
    'vec4 clip = omw.projectionMatrix * viewDir;',
    'float visibility = omw.sunVis * edgeFade051(sunUv);',
    'passes = main;',
    'version = "2.0-051";'
)) {
    if (-not $lensText.Contains($needle)) {
        throw "Patch 22 lens flare validation failed: missing $needle"
    }
}
if ($lensText.Contains('sunOcclusion(')) {
    throw "Patch 22 isolation failed: legacy far-depth sunOcclusion remains in H2c lens flare."
}
if ($lensText.Contains('Disable_SunGlare')) {
    throw "Patch 22 isolation failed: H2c must retain OpenMW builtin sunglare."
}

$mainText = Get-Content -LiteralPath $main -Raw
$runtimeStartMarker = "private fun applyOpenMw051RuntimeGateSettings()"
$runtimeEndMarker = "// v14.2 OpenMW 0.50 launcher settings"
$runtimeStart = $mainText.IndexOf($runtimeStartMarker)
if ($runtimeStart -lt 0) { throw "Patch 22 validation failed: active runtime function missing." }
$runtimeEnd = $mainText.IndexOf($runtimeEndMarker, $runtimeStart)
if ($runtimeEnd -lt 0) { throw "Patch 22 validation failed: runtime function delimiter missing." }
$runtimeText = $mainText.Substring($runtimeStart, $runtimeEnd - $runtimeStart)
if (-not $runtimeText.Contains('"lensflare_android_051,gateh_bloom051"')) {
    throw "Patch 22 validation failed: active runtime chain is not H2c."
}
if ($runtimeText.Contains('"lensflare_android,gateh_bloom051"')) {
    throw "Patch 22 isolation failed: legacy H2b chain remains active."
}

# Ensure runtime cleanup removes the legacy filename, but not the unique H2c asset.
$syncStart = $mainText.IndexOf('val gateH2cBlockedShaders = listOf(')
if ($syncStart -lt 0) { throw "Patch 22 validation failed: H2c cleanup list missing." }
$syncEnd = $mainText.IndexOf(')', $syncStart)
$blockedText = $mainText.Substring($syncStart, $syncEnd - $syncStart)
if (-not $blockedText.Contains('"lensflare_android.omwfx"')) {
    throw "Patch 22 validation failed: legacy lensflare_android is not removed from runtime VFS."
}
if ($blockedText.Contains('"lensflare_android_051.omwfx"')) {
    throw "Patch 22 isolation failed: active H2c lens flare is in its own delete list."
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha."
}

Write-Host "OpenMW 0.51 Patch 22 Gate H2c validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "OMWFX runtime chain: lensflare_android_051,gateh_bloom051"
Write-Host "Builtin sunglare: RETAINED"
Write-Host "Legacy far-depth lensflare occlusion: BYPASSED for this visibility gate"
Write-Host "Expected: native sun brightness restored + visible halo/ghosts at the projected sun disc"
