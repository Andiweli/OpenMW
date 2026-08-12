param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'
$DiagMarker = 'OPENMW_ANDROID_051_OBJECT_LIGHTING_BYPASS_DIAG'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Apply-ObjectLightingDiagnostic([string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        throw "Patch 9 missing $Label shader: $Path"
    }

    $Text = Read-Lf $Path
    if ($Text.Contains($DiagMarker)) {
        Write-Host "Patch 9 already present in $Label." -ForegroundColor DarkGray
        return
    }

    foreach ($Required in @(
        '#define OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG',
        'vec3 viewNormal = normalToView(normalize(passNormal));',
        'gl_FragData[0].a = alphaTest(gl_FragData[0].a, alphaRef);',
        'gl_FragData[0] = applyFogAtPos(gl_FragData[0], passViewPos, far);'
    )) {
        if (-not $Text.Contains($Required)) {
            throw "Patch 9 refused unexpected $Label objects.frag; missing: $Required"
        }
    }

    $Anchor = @'
    gl_FragData[0].a = alphaTest(gl_FragData[0].a, alphaRef);

#if @normalMap
'@

    $Replacement = @'
    gl_FragData[0].a = alphaTest(gl_FragData[0].a, alphaRef);

    // OPENMW_ANDROID_051_OBJECT_LIGHTING_BYPASS_DIAG
    // Patch 9 diagnostic: sampled object colour + real fog, lighting bypassed.
    // Keep diffuse/dark-map sampling and alpha testing above, then apply the
    // real OpenMW view-distance fog using passViewPos. Returning here bypasses
    // normals, material/light evaluation, specular, env/emissive and the final
    // RGB lighting multiplication. This is intentionally diagnostic only.
    gl_FragData[0] = applyFogAtPos(gl_FragData[0], passViewPos, far);
    return;

#if @normalMap
'@

    if (-not $Text.Contains($Anchor)) {
        throw "Patch 9 could not find unique alpha-test diagnostic anchor in $Label objects.frag."
    }
    if ([regex]::Matches($Text, [regex]::Escape($Anchor)).Count -ne 1) {
        throw "Patch 9 found a non-unique alpha-test anchor in $Label objects.frag."
    }

    $Text = $Text.Replace($Anchor, $Replacement)
    Write-Utf8Lf $Path $Text

    $Verify = Read-Lf $Path
    if (-not $Verify.Contains($DiagMarker) -or
        -not $Verify.Contains('Patch 9 diagnostic: sampled object colour + real fog, lighting bypassed.')) {
        throw "Patch 9 verification failed for $Label objects.frag."
    }

    Write-Host "Applied Patch 9 object-lighting A/B diagnostic to $Label." -ForegroundColor Cyan
}

$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$AssetShader = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\objects.frag'
$SourceShader = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw\files\shaders\compatibility\objects.frag'
$BuildShader = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build\resources\shaders\compatibility\objects.frag'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($Marker, $MainActivity, $AssetShader, $SourceShader, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 9 requires the existing successful OpenMW 0.51 Patch-8 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $Marker) -ne $ExpectedMarker) {
    throw 'Patch 9 refused a non-0.51-Final runtime payload.'
}

$MainText = Read-Lf $MainActivity
if (-not $MainText.Contains('OpenMW 0.51 Patch 9 object-lighting bypass diagnostic + Patch-8 compatibility shaders')) {
    throw 'Patch 9 package is incomplete or was not overlaid correctly: MainActivity Patch-9 marker missing.'
}

$BeforeJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
$BeforeSymbolHash = if (Test-Path $SymbolLib) { (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 9 - object lighting/material A/B diagnostic' -ForegroundColor Cyan
Write-Host 'Diffuse texture + alpha + real fog remain active; object lighting/material RGB is bypassed.' -ForegroundColor Cyan
Write-Host 'No native rebuild; libopenmw.so must remain byte-identical.' -ForegroundColor Yellow

Apply-ObjectLightingDiagnostic $SourceShader 'native source'
Apply-ObjectLightingDiagnostic $AssetShader 'APK asset'

if (Test-Path $BuildShader) {
    # Keep the CMake resource mirror coherent too. It is not used to relink the .so.
    $BuildDir = Split-Path $BuildShader -Parent
    if (-not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null }
    Copy-Item $SourceShader $BuildShader -Force
    $BuildText = Read-Lf $BuildShader
    if (-not $BuildText.Contains($DiagMarker)) {
        throw 'Patch 9 failed to update CMake resource mirror.'
    }
}

# The APK asset is the authoritative payload copied to both runtime resource trees
# by MainActivity at every launch. Make sure it still contains the Patch-7/8 bases.
$AssetText = Read-Lf $AssetShader
foreach ($Required in @(
    $DiagMarker,
    '#define OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG',
    'vec3 viewNormal = normalToView(normalize(passNormal));'
)) {
    if (-not $AssetText.Contains($Required)) {
        throw "Patch 9 final APK shader verification failed; missing: $Required"
    }
}

$AfterJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterJniHash -ne $BeforeJniHash) {
    throw "Patch 9 unexpectedly modified packaged libopenmw.so: before=$BeforeJniHash after=$AfterJniHash"
}
if ($BeforeSymbolHash -ne $null) {
    $AfterSymbolHash = (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($AfterSymbolHash -ne $BeforeSymbolHash) {
        throw "Patch 9 unexpectedly modified symbol libopenmw.so: before=$BeforeSymbolHash after=$AfterSymbolHash"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 9: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterJniHash"
Write-Host 'Diagnostic meaning:'
Write-Host '  - If black distant NIFs regain their textures/colour: lighting/material state is the culprit.'
Write-Host '  - If textures return but fog is still wrong: passViewPos/fog-distance path is also faulty.'
Write-Host '  - If objects stay black: the fault is before lighting (texture/material sampling/state binding).'
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio. Do NOT run a native OpenMW rebuild.'
