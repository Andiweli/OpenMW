param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Replace-Exact([string]$Path, [string]$Label, [string]$Old, [string]$New) {
    $Text = Read-Lf $Path
    if ($Text.Contains($New)) {
        Write-Host "$Label already applied."
        return
    }
    $Count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($Count -ne 1) {
        throw "${Label}: expected exactly one old block in $Path, found $Count"
    }
    Write-Utf8Lf $Path ($Text.Replace($Old, $New))
    Write-Host "Applied $Label."
}

$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$SourceShadow = Join-Path $SourceRoot 'files\shaders\compatibility\shadows_fragment.glsl'
$AssetShadow = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\shadows_fragment.glsl'
$Patcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'

foreach ($Required in @($SourceShadow, $AssetShadow, $Patcher, $MainActivity, $JniLib, $Marker)) {
    if (-not (Test-Path $Required)) { throw "Missing required Patch-12 project file: $Required" }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=f4bec41444214a7903bebd178389ca22ca13f646"
if ((Read-Lf $Marker).Trim() -ne $ExpectedMarker) {
    throw 'OpenMW engine marker is not the pinned 0.51.0 Final runtime.'
}

$BeforeSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()

$OldReceiver = '                shadowing = min(step(shadowXYZ.z, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);'
$NewReceiver = @'
                // OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS
                // Raw GLES2 depth sampling must never compare receivers outside
                // the valid projected shadow depth volume. Otherwise z > 1 can
                // become a view-dependent full-shadow patch with CLAMP_TO_EDGE.
                if (shadowSpaceCoords@shadow_texture_unit_index.w > 0.0 && shadowXYZ.z > 0.0 && shadowXYZ.z < 1.0)
                    shadowing = min(step(shadowXYZ.z, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);
'@.TrimEnd([char[]]"`r`n")

Replace-Exact $SourceShadow 'Patch 12b shadow-coordinate bounds in native resource source' $OldReceiver $NewReceiver

# The APK must contain the exact same runtime shader as the patched source.
Copy-Item $SourceShadow $AssetShadow -Force
if ((Read-Lf $SourceShadow) -ne (Read-Lf $AssetShadow)) {
    throw 'Patch 12b asset copy does not match native resource source.'
}

# Permanently teach clean 0.51 builds to generate the bounded manual compare.
$OldPatcherLine = "        'shadowing = min(step(shadowXYZ.z, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);',"
$NewPatcherBlock = @'
        '''// OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS
                // Raw GLES2 depth sampling must never compare receivers outside
                // the valid projected shadow depth volume. Otherwise z > 1 can
                // become a view-dependent full-shadow patch with CLAMP_TO_EDGE.
                if (shadowSpaceCoords@shadow_texture_unit_index.w > 0.0 && shadowXYZ.z > 0.0 && shadowXYZ.z < 1.0)
                    shadowing = min(step(shadowXYZ.z, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);''',
'@.TrimEnd([char[]]"`r`n")
Replace-Exact $Patcher 'Patch 12b permanent runtime patcher shadow bounds' $OldPatcherLine $NewPatcherBlock

# Make the running APK self-identifying in Logcat. This is Java/Kotlin only.
$Main = Read-Lf $MainActivity
$Main = $Main.Replace(
    'Synced OpenMW 0.51 Patch 12 GLES2 shadows + GL4ES compatibility; post processing remains disabled',
    'Synced OpenMW 0.51 Patch 12b bounded GLES2 shadows + GL4ES compatibility; post processing remains disabled'
)
$Main = $Main.Replace(
    'OpenMW 0.51 Patch 12 runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Patch 12b runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $Main

$VerifySource = Read-Lf $SourceShadow
$VerifyAsset = Read-Lf $AssetShadow
$VerifyPatcher = Read-Lf $Patcher
foreach ($Text in @($VerifySource, $VerifyAsset, $VerifyPatcher)) {
    if (-not $Text.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
        throw 'Patch 12b verification failed: coordinate-bounds marker missing.'
    }
}
if (-not $VerifySource.Contains('shadowSpaceCoords@shadow_texture_unit_index.w > 0.0') -or
    -not $VerifySource.Contains('shadowXYZ.z > 0.0 && shadowXYZ.z < 1.0')) {
    throw 'Patch 12b verification failed: W/Z validity test is incomplete.'
}
# Only reject a truly unguarded receiver line. The guarded Patch-12b line
# contains the same comparison text with deeper indentation, so a plain
# substring test would be a false positive.
$UnguardedReceiverPattern = '(?m)^ {16}shadowing = min\(step\(shadowXYZ\.z, texture2D\(shadowTexture@shadow_texture_unit_index, shadowXYZ\.xy\)\.r\), shadowing\);\s*$'
if ([regex]::IsMatch($VerifySource, $UnguardedReceiverPattern)) {
    throw 'Patch 12b verification failed: truly unguarded manual compare remains in receiver.'
}

$AfterSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterSha -ne $BeforeSha) {
    throw "Patch 12b must not modify libopenmw.so. Before=$BeforeSha After=$AfterSha"
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12b - shadow coordinate bounds: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterSha" -ForegroundColor Green
Write-Host 'No native rebuild is required.' -ForegroundColor Green
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio.'
Write-Host 'Test the same city route and rotate the camera while standing still.'
