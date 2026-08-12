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

function Remove-ColourDiagnostic([string]$Path, [string]$Label, [string]$Marker) {
    if (-not (Test-Path $Path)) { throw "Patch 11 missing $Label shader: $Path" }
    $Text = Read-Lf $Path
    if (-not $Text.Contains($Marker)) {
        Write-Host "Patch-10 colour tag already absent from $Label." -ForegroundColor DarkGray
        return
    }

    $Pattern = "(?ms)^\s*// " + [regex]::Escape($Marker) + ".*?^\s*return;\s*\n"
    $NewText = [regex]::Replace($Text, $Pattern, '', 1)
    if ($NewText -eq $Text -or $NewText.Contains($Marker)) {
        throw "Patch 11 could not remove Patch-10 colour diagnostic from $Label."
    }
    Write-Utf8Lf $Path $NewText
    Write-Host "Removed Patch-10 colour diagnostic from $Label." -ForegroundColor Cyan
}

function Apply-ObjectsAdditiveFogCompat([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) { throw "Patch 11 missing $Label shader: $Path" }
    $Text = Read-Lf $Path
    $Marker = 'OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG'

    if ($Text.Contains($Marker)) {
        if ($Text.Contains('#define ADDITIVE_BLENDING')) {
            throw "Patch 11 marker exists but ADDITIVE_BLENDING is still defined in $Label."
        }
        Write-Host "Patch 11 already present in $Label." -ForegroundColor DarkGray
        return
    }

    $Old = @'
#if @additiveBlending
#define ADDITIVE_BLENDING
#endif
'@
    if (-not $Text.Contains($Old.Trim())) {
        throw "Patch 11 refused unexpected $Label shader; additive-blending block missing."
    }

    $New = @'
// OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG
// Android/GL4ES compatibility: OpenMW's additive fog branch fades RGB toward
// black instead of the scene fog colour. The stable 0.50 Android GL4ES patch
// deliberately did not define ADDITIVE_BLENDING for compatibility/objects.frag.
// Keep the same compatibility behaviour while diagnosing 0.51 forced shaders.
'@
    $Text = $Text.Replace($Old.Trim(), $New.Trim())
    Write-Utf8Lf $Path $Text

    $Verify = Read-Lf $Path
    if (-not $Verify.Contains($Marker) -or $Verify.Contains('#define ADDITIVE_BLENDING')) {
        throw "Patch 11 verification failed for $Label."
    }
    Write-Host "Applied legacy Android/GL4ES additive-fog compatibility to $Label." -ForegroundColor Green
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($MarkerFile, $MainActivity, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 11 requires the existing successful OpenMW 0.51 Patch-10 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $MarkerFile) -ne $ExpectedMarker) {
    throw 'Patch 11 refused a non-0.51-Final runtime payload.'
}

$MainText = Read-Lf $MainActivity
if (-not $MainText.Contains('OpenMW 0.51 Patch 11 GL4ES additive-fog compatibility + Patch-8 shaders')) {
    throw 'Patch 11 package is incomplete or was not overlaid correctly: MainActivity Patch-11 marker missing.'
}

$BeforeJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
$BeforeSymbolHash = if (Test-Path $SymbolLib) { (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 11 - GL4ES additive fog compatibility test' -ForegroundColor Cyan
Write-Host 'Removes Patch-10 flat diagnostic colours.' -ForegroundColor Cyan
Write-Host 'Ports the exact 0.50 Android GL4ES behaviour: objects.frag no longer defines ADDITIVE_BLENDING.' -ForegroundColor Cyan
Write-Host 'No native rebuild; libopenmw.so must remain byte-identical.' -ForegroundColor Yellow

$Families = @(
    @{ Rel='shaders\compatibility\objects.frag'; Label='objects'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_OBJECTS'; Objects=$true },
    @{ Rel='shaders\compatibility\bs\default.frag'; Label='bs/default'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_BS_DEFAULT'; Objects=$false },
    @{ Rel='shaders\compatibility\bs\nolighting.frag'; Label='bs/nolighting'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_BS_NOLIGHTING'; Objects=$false },
    @{ Rel='shaders\compatibility\groundcover.frag'; Label='groundcover'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_GROUNDCOVER'; Objects=$false }
)

foreach ($Family in $Families) {
    $Asset = Join-Path $ProjectRoot ('app\src\main\assets\libopenmw\resources\' + $Family.Rel)
    $Source = Join-Path $ProjectRoot ('buildscripts\build\arm64\openmw-prefix\src\openmw\files\' + $Family.Rel)
    $Build = Join-Path $ProjectRoot ('buildscripts\build\arm64\openmw-prefix\src\openmw-build\resources\' + $Family.Rel)

    foreach ($Pair in @(@($Source, 'native source ' + $Family.Label), @($Asset, 'APK asset ' + $Family.Label))) {
        Remove-ColourDiagnostic $Pair[0] $Pair[1] $Family.Marker
        if ($Family.Objects) {
            Apply-ObjectsAdditiveFogCompat $Pair[0] $Pair[1]
        }
    }

    if (Test-Path $Build) {
        Copy-Item $Source $Build -Force
    }
}

$AssetObjects = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\objects.frag'
$SourceObjects = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw\files\shaders\compatibility\objects.frag'
foreach ($Path in @($AssetObjects, $SourceObjects)) {
    $T = Read-Lf $Path
    if (-not $T.Contains('OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG')) {
        throw "Patch 11 final verification missing additive-fog marker: $Path"
    }
    if ($T.Contains('#define ADDITIVE_BLENDING')) {
        throw "Patch 11 final verification: ADDITIVE_BLENDING still defined: $Path"
    }
    if (-not $T.Contains('OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG')) {
        throw "Patch 11 final verification: Patch-7 explicit object fog was lost: $Path"
    }
}

foreach ($Family in $Families) {
    $Asset = Join-Path $ProjectRoot ('app\src\main\assets\libopenmw\resources\' + $Family.Rel)
    if ((Read-Lf $Asset).Contains($Family.Marker)) {
        throw "Patch 11 final verification: Patch-10 diagnostic remains in $($Family.Label)."
    }
}

$AfterJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterJniHash -ne $BeforeJniHash) {
    throw "Patch 11 unexpectedly modified packaged libopenmw.so: before=$BeforeJniHash after=$AfterJniHash"
}
if ($BeforeSymbolHash -ne $null) {
    $AfterSymbolHash = (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($AfterSymbolHash -ne $BeforeSymbolHash) {
        throw "Patch 11 unexpectedly modified symbol libopenmw.so: before=$BeforeSymbolHash after=$AfterSymbolHash"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 11: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterJniHash"
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio. Do NOT run a native OpenMW rebuild.'
Write-Host 'Test: use the same exterior scene and compare low/default/high viewing distance.'
Write-Host 'Expected if this is the missing 0.50 GL4ES compatibility hunk: rocks/trees fade into the fog colour instead of becoming black silhouettes.'
