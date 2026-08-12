param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-File([string]$RelativePath) {
    $path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing required Patch 17 file: $RelativePath"
    }
    return $path
}

function Require-Text([string]$Path, [string]$Needle, [string]$Description) {
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Patch 17 validation failed: $Description"
    }
}

$main = Require-File "app/src/main/java/ui/activity/MainActivity.kt"
$gradle = Require-File "app/build.gradle"
$probe = Require-File "app/src/main/assets/android_omwfx/gateh_probe.omwfx"
$nativeLib = Require-File "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$nativeShaFile = Require-File "buildscripts/openmw-051-patch13-libopenmw.sha256"

Require-Text $main "OpenMW 0.51 Patch 17 Gate H diagnostic runtime" "MainActivity runtime marker is missing."
Require-Text $main '"gateh_probe"' "MainActivity does not select gateh_probe."
Require-Text $main "MAGENTA-PROBE" "MainActivity diagnostic stage marker is missing."
Require-Text $gradle "gateh_probe.omwfx" "Gradle does not validate the diagnostic shader."
Require-Text $probe "omw_GetLastShader" "Diagnostic shader does not sample the previous stage."
Require-Text $probe "vec3(1.0, 0.0, 1.0)" "Diagnostic shader does not contain the strong magenta tint."
Require-Text $probe "passes = main;" "Diagnostic shader technique is incomplete."

$probeText = Get-Content -LiteralPath $probe -Raw
foreach ($forbidden in @("render_target", "omw_GetLinearDepth", "omw_SamplerNormals", "pass_normals")) {
    if ($probeText.Contains($forbidden)) {
        throw "Patch 17 diagnostic shader unexpectedly depends on '$forbidden'."
    }
}

$mainText = Get-Content -LiteralPath $main -Raw
if ($mainText.Contains('"lensflare_android,bloomlinear_android"')) {
    throw "Patch 17 isolation failed: Patch 16 Lensflare+Bloom chain is still active."
}

$expectedShaText = (Get-Content -LiteralPath $nativeShaFile -Raw).Trim()
$expectedSha = ($expectedShaText -split '\s+')[0].ToLowerInvariant()
$currentSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeLib).Hash.ToLowerInvariant()
if ($expectedSha -ne $currentSha) {
    throw "Native libopenmw.so differs from the device-proven Patch 13 Gate G binary. Expected $expectedSha, actual $currentSha. Re-run Patch 13 native build before packaging."
}

Write-Host "OpenMW 0.51 Patch 17 Gate H diagnostic validation: PASS"
Write-Host "Native rebuild: NO"
Write-Host "Expected OMWFX runtime chain: gateh_probe"
Write-Host "Expected visual result: strong magenta tint over the 3D scene"
Write-Host "If no tint on startup, toggle Post Processing OFF then ON once."
Write-Host "  Tint appears after toggle -> startup/reload timing path is implicated."
Write-Host "  Still no tint -> custom chain/VFS/technique discovery is implicated."
