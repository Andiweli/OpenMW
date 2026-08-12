$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$Patch13Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch13-libopenmw.sha256'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$BloomAsset = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\bloomlinear_android.omwfx'
$Adjustments = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\vfs\shaders\adjustments.omwfx'

foreach ($Required in @($MarkerFile, $JniLib, $Patch13Sha, $MainActivity, $BuildGradle, $BloomAsset, $Adjustments)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 15 requires the already applied/tested Patch-14 project tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 15 refused a non-0.51.0-Final runtime payload.'
}

$MainText = Read-Lf $MainActivity
$GradleText = Read-Lf $BuildGradle
$BloomText = Read-Lf $BloomAsset
$AdjustmentsText = Read-Lf $Adjustments

if (-not $MainText.Contains('OpenMW 0.51 Patch 15 Gate H1 runtime: shadows=launcher-controlled')) {
    throw 'Patch 15 MainActivity.kt was not copied/applied correctly.'
}
if (-not $MainText.Contains('chain=$postProcessingChain')) {
    throw 'Patch 15 runtime chain selection is missing.'
}
if (-not $MainText.Contains('"bloomlinear_android"') -or
    -not $MainText.Contains('"adjustments"')) {
    throw 'Patch 15 is missing the Bloom/adjustments Gate-H1 chain selection.'
}
if (-not $MainText.Contains('gateH1BlockedAndroidShaders')) {
    throw 'Patch 15 stale Android-OMWFX isolation guard is missing.'
}
if ($MainText.Contains('OpenMW 0.51 Patch 14 runtime: shadows=launcher-controlled, postProcessing=true, chain=adjustments, omwfx=false')) {
    throw 'Patch 15 still contains the active Patch-14 runtime marker.'
}

if (-not $GradleText.Contains('OpenMW 0.51 Patch 15') -or
    -not $GradleText.Contains("src/main/assets/android_omwfx/bloomlinear_android.omwfx")) {
    throw 'Patch 15 app/build.gradle was not copied/applied correctly.'
}
if (-not $GradleText.Contains('openmw-051-patch13-libopenmw.sha256')) {
    throw 'Patch 15 lost the proven Patch-13 native-library integrity gate.'
}
if ($GradleText -match 'assets\s*\{[^}]*srcDir\s+omwfxGeneratedAssetsDir') {
    throw 'Patch 15 must not merge the full generated upstream OMWFX overlay.'
}

if (-not $BloomText.Contains('render_target RT_NoMipmap') -or
    -not $BloomText.Contains('render_target RT_Horizontal') -or
    -not $BloomText.Contains('render_target RT_Vertical') -or
    -not $BloomText.Contains('passes = nomipmap, horizontal, vertical, final;') -or
    $BloomText.Contains('pass_normals') -or
    $BloomText.Contains('omw_SamplerNormals')) {
    throw 'Patch 15 Bloom shader is not the intended isolated no-normals Gate-H1 payload.'
}

if (-not $AdjustmentsText.Contains('author = "OpenMW"') -or
    -not $AdjustmentsText.Contains('passes = main;') -or
    $AdjustmentsText.Contains('omw_SamplerNormals')) {
    throw 'Bundled adjustments.omwfx no longer matches the proven Gate-G fallback technique.'
}

$ExpectedSha = ((Get-Content $Patch13Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSha -ne $ActualSha) {
    throw "Patch 15 requires the exact tested Patch-13 native library. Expected=$ExpectedSha actual=$ActualSha"
}

$BloomSha = (Get-FileHash $BloomAsset -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 15 - Gate H1 isolated OMWFX Bloom: READY' -ForegroundColor Green
Write-Host 'Native rebuild: NO (the tested Patch-13 libopenmw.so is reused unchanged).' -ForegroundColor Cyan
Write-Host "Verified Patch-13 libopenmw.so SHA-256: $ActualSha" -ForegroundColor Green
Write-Host "Bloom asset SHA-256: $BloomSha" -ForegroundColor Green
Write-Host ''
Write-Host 'Runtime selection:' -ForegroundColor Cyan
Write-Host '  Launcher shader preset = OMWFX  -> PP chain: bloomlinear_android'
Write-Host '  Any other shader preset         -> PP chain: adjustments'
Write-Host '  Shadows                          -> launcher-controlled Patch-12k path'
Write-Host '  Lensflare/Godrays/RainLens/WetWorld -> blocked from Gate H1 runtime VFS'
Write-Host '  Full upstream OMWFX overlay      -> NOT merged'
Write-Host ''
Write-Host 'Expected Logcat marker with OMWFX selected:' -ForegroundColor Cyan
Write-Host '  OpenMW 0.51 Patch 15 Gate H1 runtime: shadows=launcher-controlled, postProcessing=true, chain=bloomlinear_android, omwfxStage=bloom-only'
Write-Host ''
Write-Host 'Assemble/reinstall the APK now. No native OpenMW rebuild is required.' -ForegroundColor Green
