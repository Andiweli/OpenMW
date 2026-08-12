$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$ShadowFrag = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\shadows_fragment.glsl'
$ShadowCast = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\shadowcasting.vert'
$ObjectsFrag = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\objects.frag'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

foreach ($Required in @($BuildGradle, $MarkerFile, $ShadowFrag, $ShadowCast, $ObjectsFrag, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12a requires the Patch-12 project tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $MarkerFile) -ne $ExpectedMarker) {
    throw 'Patch 12a refused a non-0.51-Final runtime payload.'
}

$Receiver = Read-Lf $ShadowFrag
$Caster = Read-Lf $ShadowCast
$Objects = Read-Lf $ObjectsFrag

if (-not $Receiver.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    $Receiver.Contains('uniform sampler2DShadow') -or
    $Receiver.Contains('shadow2DProj(') -or
    -not $Receiver.Contains('uniform sampler2D shadowTexture@shadow_texture_unit_index;') -or
    -not $Receiver.Contains('step(shadowXYZ.z, texture2D(')) {
    throw 'Patch 12a cannot enable the Gradle gate because the Patch-12 GLES2 shadow receiver is incomplete.'
}

if (-not $Caster.Contains('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK') -or
    -not $Caster.Contains('gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);')) {
    throw 'Patch 12a cannot enable the Gradle gate because the Patch-12 shadow-caster fallback is incomplete.'
}

if (-not $Objects.Contains('OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG') -or
    $Objects.Contains('#define ADDITIVE_BLENDING')) {
    throw 'Patch 12a refused the tree because the confirmed Patch-11 additive-fog fix is missing.'
}

$BeforeSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
$Text = Read-Lf $BuildGradle

$OldBlock = @'
        // Shadows are deliberately disabled for Patch 2. The old 0.50 manual
        // shadow receiver must NOT leak into this 0.51 baseline payload.
        if (shadowFragmentShader.contains('OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE') ||
                !shadowFragmentShader.contains('uniform sampler2DShadow') ||
                !shadowFragmentShader.contains('shadow2DProj(')) {
            throw new GradleException(
                    'OpenMW 0.51 runtime gate contains a stale/non-upstream shadow receiver.\n' +
                    'Patch 2 expects the native 0.51 shadow shader while shadows remain forced off.'
            )
        }
'@

$NewBlock = @'
        // Patch 12 / Gate F: Android GLES2 cannot rely on sampler2DShadow /
        // shadow2DProj. Require the explicit depth-compare receiver and the
        // shadow-caster depth-clamp fallback instead. Shadows are now controlled
        // by the launcher; post processing and OMWFX remain gated off.
        if (!shadowFragmentShader.contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') ||
                shadowFragmentShader.contains('uniform sampler2DShadow') ||
                shadowFragmentShader.contains('shadow2DProj(') ||
                !shadowFragmentShader.contains('uniform sampler2D shadowTexture@shadow_texture_unit_index;') ||
                !shadowFragmentShader.contains('step(shadowXYZ.z, texture2D(') ||
                !shadowShader.contains('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK') ||
                !shadowShader.contains('gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);')) {
            throw new GradleException(
                    'OpenMW 0.51 Patch 12 shadow payload is incomplete.\n' +
                    'Re-run tools\\apply-openmw-051-patch12-shadows.ps1 before assembling the APK.'
            )
        }
'@

$NewBlock = $NewBlock -replace "`r`n", "`n"
$OldBlock = $OldBlock -replace "`r`n", "`n"

if ($Text.Contains('Patch 12 / Gate F: Android GLES2 cannot rely on sampler2DShadow')) {
    Write-Host 'Patch-12 Gradle gate is already installed; validating only.' -ForegroundColor DarkGray
} elseif ($Text.Contains($OldBlock)) {
    $Text = $Text.Replace($OldBlock, $NewBlock)
    [IO.File]::WriteAllText($BuildGradle, ($Text -replace "`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    Write-Host 'Updated app/build.gradle from obsolete Patch-2 shadow gate to Patch-12 Gate-F validation.' -ForegroundColor Green
} else {
    throw 'Could not locate the obsolete Patch-2 shadow verification block in app/build.gradle. Refusing a blind edit.'
}

$Check = Read-Lf $BuildGradle
if (-not $Check.Contains('Patch 12 / Gate F: Android GLES2 cannot rely on sampler2DShadow') -or
    $Check.Contains('Patch 2 expects the native 0.51 shadow shader while shadows remain forced off.')) {
    throw 'Patch 12a Gradle-gate verification failed.'
}

$AfterSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterSha -ne $BeforeSha) {
    throw "Patch 12a unexpectedly changed libopenmw.so: before=$BeforeSha after=$AfterSha"
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12a build-gate hotfix: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterSha"
Write-Host 'No native rebuild is required.' -ForegroundColor Yellow
Write-Host 'Next: assemble the APK normally in Android Studio.' -ForegroundColor Cyan
