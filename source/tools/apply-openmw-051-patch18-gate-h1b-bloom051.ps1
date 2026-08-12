param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 18 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 18 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$bloom = Require-File "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 18 Gate H1b runtime" "MainActivity runtime marker is missing."
Require-Text $main '"gateh_bloom051"' "MainActivity does not select the unique 0.51 bloom reference."
Require-Text $main "OPENMW051-BLOOM-REFERENCE" "MainActivity H1b stage marker is missing."
Require-Text $gradle "gateh_bloom051.omwfx" "Gradle does not validate the H1b bloom reference."
Require-Text $bloom "passes = nomipmap, horizontal, vertical, final;" "Bloom reference is not the expected four-pass 0.51 implementation."
Require-Text $bloom "internal_format = rgb16f;" "Bloom reference lost the 0.51 rgb16f render target."
Require-Text $bloom "source_type = half_float;" "Bloom reference lost the 0.51 half-float render target type."
Require-Text $bloom "default = 0.20;" "Bloom threshold test default is not 0.20."
Require-Text $bloom "default = 1.00;" "Bloom sky-factor test default is not 1.00."
Require-Text $bloom "default = 0.60;" "Bloom radius/strength test defaults are missing."

$mainText = Get-Content -LiteralPath $main -Raw

# Patch 18 must isolate the *active 0.51 Gate-H runtime path* only.
# MainActivity intentionally still retains the historical 0.50 OMWFX preset
# definition (including bloomlinear_android) for later migration/reference.
# Treating those preserved constants/comments as active H1b chains is a false
# positive, so constrain this check to applyOpenMw051RuntimeGateSettings().
$runtimeStartMarker = "private fun applyOpenMw051RuntimeGateSettings()"
$runtimeEndMarker = "// v14.2 OpenMW 0.50 launcher settings"
$runtimeStart = $mainText.IndexOf($runtimeStartMarker)
if ($runtimeStart -lt 0) {
    throw "Patch 18 validation failed: active 0.51 runtime gate function was not found."
}
$runtimeEnd = $mainText.IndexOf($runtimeEndMarker, $runtimeStart)
if ($runtimeEnd -lt 0) {
    throw "Patch 18 validation failed: could not delimit active 0.51 runtime gate function."
}
$runtimeText = $mainText.Substring($runtimeStart, $runtimeEnd - $runtimeStart)

Require-Text $main '"gateh_bloom051"' "MainActivity does not contain the H1b reference name."
if (-not $runtimeText.Contains('"gateh_bloom051"')) {
    throw "Patch 18 validation failed: active runtime gate does not select gateh_bloom051."
}
foreach ($oldChain in @('"gateh_probe"', '"lensflare_android,bloomlinear_android"', '"bloomlinear_android"')) {
    if ($runtimeText.Contains($oldChain)) {
        throw "Patch 18 isolation failed: obsolete Gate-H chain remains in active runtime block: $oldChain"
    }
}

# Clean the obsolete Patch-17 source probe if the previous patch left it behind.
$oldProbe = Join-Path $ProjectRoot "app/src/main/assets/android_omwfx/gateh_probe.omwfx"
if (Test-Path -LiteralPath $oldProbe -PathType Leaf) {
    Remove-Item -LiteralPath $oldProbe -Force
    Write-Host "Removed obsolete Patch 17 source probe: app/src/main/assets/android_omwfx/gateh_probe.omwfx"
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha. Re-run Patch 13 native build before packaging."
}

Write-Host "OpenMW 0.51 Patch 18 Gate H1b official-bloom reference validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "Expected OMWFX runtime chain: gateh_bloom051"
Write-Host "Test defaults: threshold=0.20, skyFactor=1.00, radius=0.60, strength=0.60"
Write-Host "Expected visual result: clearly visible bloom around bright sky/sun/bright surfaces"
