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

function Insert-TagAfterAlphaTest([string]$Path, [string]$Label, [string]$Marker, [string]$Rgb) {
    if (-not (Test-Path $Path)) {
        throw "Patch 10 missing $Label shader: $Path"
    }

    $Text = Read-Lf $Path
    if ($Text.Contains($Marker)) {
        Write-Host "Patch 10 already present in $Label." -ForegroundColor DarkGray
        return
    }

    $AlphaLine = '    gl_FragData[0].a = alphaTest(gl_FragData[0].a, alphaRef);'
    if (-not $Text.Contains($AlphaLine)) {
        throw "Patch 10 refused unexpected $Label shader; alpha-test anchor missing."
    }
    if ([regex]::Matches($Text, [regex]::Escape($AlphaLine)).Count -ne 1) {
        throw "Patch 10 found non-unique alpha-test anchor in $Label shader."
    }

    $Insert = @"
$AlphaLine

    // $Marker
    // Patch 10 diagnostic shader-prefix tag. Preserve sampled alpha/alpha-test,
    // replace RGB with an unmistakable flat colour, and return before lighting/fog.
    gl_FragData[0].rgb = vec3($Rgb);
    return;
"@

    $Text = $Text.Replace($AlphaLine, $Insert.TrimEnd("`r", "`n"))
    Write-Utf8Lf $Path $Text

    $Verify = Read-Lf $Path
    if (-not $Verify.Contains($Marker) -or -not $Verify.Contains("vec3($Rgb)")) {
        throw "Patch 10 verification failed for $Label shader."
    }
    Write-Host "Applied Patch 10 shader-prefix tag to $Label." -ForegroundColor Cyan
}

function Replace-Patch9ObjectsWithTag([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        throw "Patch 10 missing $Label shader: $Path"
    }

    $Text = Read-Lf $Path
    $Marker = 'OPENMW_ANDROID_051_SHADER_PREFIX_TAG_OBJECTS'
    if ($Text.Contains($Marker)) {
        Write-Host "Patch 10 already present in $Label." -ForegroundColor DarkGray
        return
    }

    if ($Text.Contains('OPENMW_ANDROID_051_OBJECT_LIGHTING_BYPASS_DIAG')) {
        $Pattern = '(?s)\n    // OPENMW_ANDROID_051_OBJECT_LIGHTING_BYPASS_DIAG.*?\n    return;\n\n#if @normalMap'
        $Replacement = @'

    // OPENMW_ANDROID_051_SHADER_PREFIX_TAG_OBJECTS
    // Patch 10: objects shader = MAGENTA. Preserve sampled alpha/alpha-test,
    // then return before lighting/fog so shader identity is visually unambiguous.
    gl_FragData[0].rgb = vec3(1.0, 0.0, 1.0);
    return;

#if @normalMap
'@
        $NewText = [regex]::Replace($Text, $Pattern, $Replacement, 1)
        if ($NewText -eq $Text) {
            throw "Patch 10 could not replace the Patch-9 objects diagnostic in $Label."
        }
        $Text = $NewText
        Write-Utf8Lf $Path $Text
    }
    else {
        Insert-TagAfterAlphaTest $Path $Label $Marker '1.0, 0.0, 1.0'
        return
    }

    $Verify = Read-Lf $Path
    if (-not $Verify.Contains($Marker) -or $Verify.Contains('OPENMW_ANDROID_051_OBJECT_LIGHTING_BYPASS_DIAG')) {
        throw "Patch 10 objects verification failed for $Label."
    }
    Write-Host "Replaced Patch-9 bypass with Patch-10 MAGENTA tag in $Label." -ForegroundColor Cyan
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($MarkerFile, $MainActivity, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 10 requires the existing successful OpenMW 0.51 Patch-9 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $MarkerFile) -ne $ExpectedMarker) {
    throw 'Patch 10 refused a non-0.51-Final runtime payload.'
}

$MainText = Read-Lf $MainActivity
if (-not $MainText.Contains('OpenMW 0.51 Patch 10 shader-prefix colour diagnostic + Patch-8 compatibility shaders')) {
    throw 'Patch 10 package is incomplete or was not overlaid correctly: MainActivity Patch-10 marker missing.'
}

$BeforeJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
$BeforeSymbolHash = if (Test-Path $SymbolLib) { (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 10 - shader-prefix colour diagnostic' -ForegroundColor Cyan
Write-Host 'Terrain stays normal. NIF shader families get flat diagnostic colours:' -ForegroundColor Cyan
Write-Host '  MAGENTA = compatibility/objects' -ForegroundColor Magenta
Write-Host '  GREEN   = compatibility/bs/default' -ForegroundColor Green
Write-Host '  CYAN    = compatibility/bs/nolighting' -ForegroundColor Cyan
Write-Host '  YELLOW  = compatibility/groundcover' -ForegroundColor Yellow
Write-Host 'If a black object stays black, none of these OpenMW fragment shaders is drawing it.' -ForegroundColor Yellow
Write-Host 'No native rebuild; libopenmw.so must remain byte-identical.' -ForegroundColor Yellow

$Families = @(
    @{ Rel='shaders\compatibility\objects.frag'; Label='objects'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_OBJECTS'; Rgb='1.0, 0.0, 1.0'; Objects=$true },
    @{ Rel='shaders\compatibility\bs\default.frag'; Label='bs/default'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_BS_DEFAULT'; Rgb='0.0, 1.0, 0.0'; Objects=$false },
    @{ Rel='shaders\compatibility\bs\nolighting.frag'; Label='bs/nolighting'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_BS_NOLIGHTING'; Rgb='0.0, 1.0, 1.0'; Objects=$false },
    @{ Rel='shaders\compatibility\groundcover.frag'; Label='groundcover'; Marker='OPENMW_ANDROID_051_SHADER_PREFIX_TAG_GROUNDCOVER'; Rgb='1.0, 1.0, 0.0'; Objects=$false }
)

foreach ($Family in $Families) {
    $Asset = Join-Path $ProjectRoot ('app\src\main\assets\libopenmw\resources\' + $Family.Rel)
    $Source = Join-Path $ProjectRoot ('buildscripts\build\arm64\openmw-prefix\src\openmw\files\' + $Family.Rel)
    $Build = Join-Path $ProjectRoot ('buildscripts\build\arm64\openmw-prefix\src\openmw-build\resources\' + $Family.Rel)

    foreach ($Pair in @(@($Source, 'native source ' + $Family.Label), @($Asset, 'APK asset ' + $Family.Label))) {
        if ($Family.Objects) {
            Replace-Patch9ObjectsWithTag $Pair[0] $Pair[1]
        }
        else {
            Insert-TagAfterAlphaTest $Pair[0] $Pair[1] $Family.Marker $Family.Rgb
        }
    }

    if (Test-Path $Build) {
        Copy-Item $Source $Build -Force
        if (-not (Read-Lf $Build).Contains($Family.Marker)) {
            throw "Patch 10 failed to update CMake resource mirror for $($Family.Label)."
        }
    }
}

$AfterJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterJniHash -ne $BeforeJniHash) {
    throw "Patch 10 unexpectedly modified packaged libopenmw.so: before=$BeforeJniHash after=$AfterJniHash"
}
if ($BeforeSymbolHash -ne $null) {
    $AfterSymbolHash = (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($AfterSymbolHash -ne $BeforeSymbolHash) {
        throw "Patch 10 unexpectedly modified symbol libopenmw.so: before=$BeforeSymbolHash after=$AfterSymbolHash"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 10: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterJniHash"
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio. Do NOT run a native OpenMW rebuild.'
Write-Host 'Test meaning:'
Write-Host '  MAGENTA object  -> compatibility/objects is the real path.'
Write-Host '  GREEN object    -> compatibility/bs/default is the real path.'
Write-Host '  CYAN object     -> compatibility/bs/nolighting is the real path.'
Write-Host '  YELLOW object   -> compatibility/groundcover is the real path.'
Write-Host '  Still black     -> rendered outside these OpenMW fragment shaders; investigate GL4ES/FFP or another prefix.'
