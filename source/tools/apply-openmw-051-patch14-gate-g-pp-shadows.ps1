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
$Adjustments = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\vfs\shaders\adjustments.omwfx'

foreach ($Required in @($MarkerFile, $JniLib, $Patch13Sha, $MainActivity, $BuildGradle, $Adjustments)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 14 requires the already applied/tested Patch-13 project tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 14 refused a non-0.51.0-Final runtime payload.'
}

$MainText = Read-Lf $MainActivity
$GradleText = Read-Lf $BuildGradle
$AdjustmentsText = Read-Lf $Adjustments

if (-not $MainText.Contains('OpenMW 0.51 Patch 14 runtime: shadows=launcher-controlled, postProcessing=true, chain=adjustments, omwfx=false')) {
    throw 'Patch 14 MainActivity.kt was not copied/applied correctly.'
}
if ($MainText.Contains('shadows=false (test isolation), postProcessing=true, chain=adjustments')) {
    throw 'Patch 14 still contains the Patch-13 forced-shadow-OFF runtime gate.'
}
if (-not $GradleText.Contains('OpenMW 0.51 Patch 14')) {
    throw 'Patch 14 app/build.gradle was not copied/applied correctly.'
}
if (-not $GradleText.Contains('openmw-051-patch13-libopenmw.sha256')) {
    throw 'Patch 14 lost the Patch-13 native-library integrity gate.'
}
if (-not $AdjustmentsText.Contains('author = "OpenMW"') -or
    -not $AdjustmentsText.Contains('passes = main;') -or
    $AdjustmentsText.Contains('omw_SamplerNormals')) {
    throw 'Bundled adjustments.omwfx no longer matches the proven simple Gate-G technique.'
}

$ExpectedSha = ((Get-Content $Patch13Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSha -ne $ActualSha) {
    throw "Patch 14 requires the exact Patch-13 native library. Expected=$ExpectedSha actual=$ActualSha"
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 14 - Gate G PP + stable shadows: READY' -ForegroundColor Green
Write-Host 'Native rebuild: NO (Patch-13 libopenmw.so is reused unchanged).' -ForegroundColor Cyan
Write-Host "Verified Patch-13 libopenmw.so SHA-256: $ActualSha" -ForegroundColor Green
Write-Host ''
Write-Host 'Runtime for this test:' -ForegroundColor Cyan
Write-Host '  Post Processing: ON'
Write-Host '  Chain: adjustments'
Write-Host '  Shadows: launcher-controlled (Patch-12k one-map path)'
Write-Host '  OMWFX: OFF'
Write-Host ''
Write-Host 'Expected Logcat marker:' -ForegroundColor Cyan
Write-Host '  OpenMW 0.51 Patch 14 runtime: shadows=launcher-controlled, postProcessing=true, chain=adjustments, omwfx=false'
Write-Host ''
Write-Host 'You can assemble/reinstall the APK now.' -ForegroundColor Green
