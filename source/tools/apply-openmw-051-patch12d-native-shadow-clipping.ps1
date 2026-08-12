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

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$SourceCaster = Join-Path $SourceRoot 'files\shaders\compatibility\shadowcasting.vert'
$AssetCaster = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\shadowcasting.vert'
$BuildCaster = Join-Path $BuildRoot 'files\shaders\compatibility\shadowcasting.vert'
$MwShadowTechnique = Join-Path $SourceRoot 'components\sceneutil\mwshadowtechnique.cpp'
$ShadowCpp = Join-Path $SourceRoot 'components\sceneutil\shadow.cpp'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'

foreach ($Required in @($MarkerFile, $JniLib, $SourceCaster, $AssetCaster, $MwShadowTechnique, $ShadowCpp, $RuntimePatcher, $MainActivity, $BuildGradle)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12d requires the working Patch-12c tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 12d refused a non-0.51-Final runtime payload.'
}

# Require the current Gate-F baseline before touching the caster path.
$SourceCasterText = Read-Lf $SourceCaster
$ShadowCppText = Read-Lf $ShadowCpp
$PatcherText = Read-Lf $RuntimePatcher
if (-not $ShadowCppText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12d requires Patch 12c orthographic shadow projection to be present.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    -not $PatcherText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12d requires the Patch-12/12b manual receiver and coordinate bounds baseline.'
}

$BeforeSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()

$OldCasterBlock = @'
    // OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK
    // GL_DEPTH_CLAMP/ARB_clip_control are unavailable through the GLES2 backend.
    // Clamp caster clip-space Z explicitly instead.
    gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);
'@.TrimEnd([char[]]"`r`n")

$NewCasterBlock = @'
    // OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING
    // GL_DEPTH_CLAMP/ARB_clip_control are unavailable through the GLES2 backend.
    // Deliberately use normal GLES2 near/far clipping here. Per-vertex Z
    // clamping can collapse off-volume caster vertices onto a clip plane and
    // produce large view-dependent triangular shadow projections.
'@.TrimEnd([char[]]"`r`n")

foreach ($CasterPath in @($SourceCaster, $AssetCaster)) {
    Replace-Exact $CasterPath 'Patch 12d native shadow-caster clipping' $OldCasterBlock $NewCasterBlock
}
if (Test-Path $BuildCaster) {
    $BuildCasterText = Read-Lf $BuildCaster
    if ($BuildCasterText.Contains($OldCasterBlock) -or $BuildCasterText.Contains($NewCasterBlock)) {
        Replace-Exact $BuildCaster 'Patch 12d CMake resource-mirror caster clipping' $OldCasterBlock $NewCasterBlock
    }
}

# The C++ side already skips ClipControl and GL_DEPTH_CLAMP on Android. Rename
# its marker/comment so clean builds no longer claim that the shader emulates it.
$OldCppAndroidBlock = @'
#else
    // OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK
    // shadowcasting.vert clamps clip-space Z explicitly on Android/GL4ES.
#endif
'@.TrimEnd([char[]]"`r`n")
$NewCppAndroidBlock = @'
#else
    // OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING
    // Android/GL4ES intentionally uses normal GLES2 clip-volume clipping;
    // do not emulate GL_DEPTH_CLAMP by clamping caster vertices in the shader.
#endif
'@.TrimEnd([char[]]"`r`n")
Replace-Exact $MwShadowTechnique 'Patch 12d MWShadowTechnique Android clipping marker' $OldCppAndroidBlock $NewCppAndroidBlock

# Permanently change the clean-build runtime patcher from vertex Z clamping to
# ordinary GLES2 clipping. Keep the C++ desktop-only state guard intact.
$Patcher = Read-Lf $RuntimePatcher
$Patcher = $Patcher.Replace(
    '# lacks GL_DEPTH_CLAMP / ARB_clip_control, so the casting vertex shader clamps' + "`n" +
    '# clip-space Z explicitly. Desktop platforms retain upstream behaviour.',
    '# lacks GL_DEPTH_CLAMP / ARB_clip_control. Android deliberately uses normal' + "`n" +
    '# GLES2 clip-volume clipping for shadow casters; desktop retains depth clamp.'
)
$Patcher = $Patcher.Replace(
    "depth_clamp_marker = 'OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK'",
    "native_clip_marker = 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING'"
)

$OldPatcherCaster = @'
text = shadow_casting.read_text(encoding='utf-8')
if depth_clamp_marker not in text:
    text = replace_once(
        text,
        '    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n',
        '''    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;

    // OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK
    // GL_DEPTH_CLAMP/ARB_clip_control are unavailable through the GLES2 backend.
    // Clamp caster clip-space Z explicitly instead.
    gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);
''',
        'shadowcasting.vert/depth clamp fallback',
    )
    shadow_casting.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android GLES2 shadow-caster depth-clamp fallback.')
'@.TrimEnd([char[]]"`r`n")
$NewPatcherCaster = @'
text = shadow_casting.read_text(encoding='utf-8')
if native_clip_marker not in text:
    text = replace_once(
        text,
        '    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n',
        '''    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;

    // OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING
    // GL_DEPTH_CLAMP/ARB_clip_control are unavailable through the GLES2 backend.
    // Deliberately use normal GLES2 near/far clipping here. Per-vertex Z
    // clamping can collapse off-volume caster vertices onto a clip plane and
    // produce large view-dependent triangular shadow projections.
''',
        'shadowcasting.vert/native GLES2 clipping marker',
    )
    shadow_casting.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android GLES2 native shadow-caster clipping marker.')
'@.TrimEnd([char[]]"`r`n")
if ($Patcher.Contains($OldPatcherCaster)) {
    $Patcher = $Patcher.Replace($OldPatcherCaster, $NewPatcherCaster)
} elseif (-not $Patcher.Contains($NewPatcherCaster)) {
    throw 'Patch 12d could not locate the permanent shadowcasting.vert clamp block.'
}

$Patcher = $Patcher.Replace('if depth_clamp_marker not in text:', 'if native_clip_marker not in text:')
$Patcher = $Patcher.Replace(
    '    // OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK' + "`n" +
    '    // shadowcasting.vert clamps clip-space Z explicitly on Android/GL4ES.',
    '    // OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' + "`n" +
    '    // Android/GL4ES intentionally uses normal GLES2 clip-volume clipping;' + "`n" +
    '    // do not emulate GL_DEPTH_CLAMP by clamping caster vertices in the shader.'
)
$Patcher = $Patcher.Replace('(depth_clamp_marker, shadow_casting_text),', '(native_clip_marker, shadow_casting_text),')
$Patcher = $Patcher.Replace('(depth_clamp_marker, mwshadowtechnique_text),', '(native_clip_marker, mwshadowtechnique_text),')

# Add a permanent safety check against accidentally reintroducing the harmful
# vertex-clamp emulation on a later clean build.
$VerifyAnchor = @'
if 'sampler2DShadow' in mwshadowtechnique_text or 'shadow2DProj(' in mwshadowtechnique_text:
    raise SystemExit('OpenMW 0.51 MWShadowTechnique fallback shaders still use unsupported shadow samplers')

print('OpenMW 0.51 Android runtime baseline patch: READY')
'@.TrimEnd([char[]]"`r`n")
$VerifyReplacement = @'
if 'sampler2DShadow' in mwshadowtechnique_text or 'shadow2DProj(' in mwshadowtechnique_text:
    raise SystemExit('OpenMW 0.51 MWShadowTechnique fallback shaders still use unsupported shadow samplers')
if 'gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);' in shadow_casting_text:
    raise SystemExit('OpenMW 0.51 Android shadow caster still contains per-vertex Z clamp emulation')

print('OpenMW 0.51 Android runtime baseline patch: READY')
'@.TrimEnd([char[]]"`r`n")
if ($Patcher.Contains($VerifyAnchor)) {
    $Patcher = $Patcher.Replace($VerifyAnchor, $VerifyReplacement)
} elseif (-not $Patcher.Contains('Android shadow caster still contains per-vertex Z clamp emulation')) {
    throw 'Patch 12d could not extend the permanent runtime verification.'
}
Write-Utf8Lf $RuntimePatcher $Patcher

# MainActivity runtime gate: require the new marker and reject a reintroduced
# per-vertex clamp. Also make the running APK self-identifying in Logcat.
$Main = Read-Lf $MainActivity
$Main = $Main.Replace('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK', 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')
$Main = $Main.Replace(
    '// supplies an explicit clip-space Z clamp instead of GL_DEPTH_CLAMP.',
    '// uses normal GLES2 near/far clipping instead of emulating GL_DEPTH_CLAMP.'
)
$OldRuntimeCondition = @'
            !shadowCastingText.contains("OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING")) {
'@.TrimEnd([char[]]"`r`n")
$NewRuntimeCondition = @'
            !shadowCastingText.contains("OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING") ||
            shadowCastingText.contains("gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);")) {
'@.TrimEnd([char[]]"`r`n")
if ($Main.Contains($OldRuntimeCondition)) {
    $Main = $Main.Replace($OldRuntimeCondition, $NewRuntimeCondition)
}
$Main = $Main.Replace(
    'Synced OpenMW 0.51 Patch 12c orthographic GLES2 shadows + GL4ES compatibility; post processing remains disabled',
    'Synced OpenMW 0.51 Patch 12d orthographic + native-clipped GLES2 shadows; post processing remains disabled'
)
$Main = $Main.Replace(
    'OpenMW 0.51 Patch 12c runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Patch 12d runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $Main

# Gradle payload gate: the current APK must carry native clipping, not the old
# vertex-clamp fallback.
$Gradle = Read-Lf $BuildGradle
$Gradle = $Gradle.Replace('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK', 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')
$Gradle = $Gradle.Replace('shadow-caster depth-clamp fallback instead.', 'shadow caster using normal GLES2 clip-volume clipping instead.')
$Gradle = $Gradle.Replace(
    "!shadowShader.contains('gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);'))",
    "shadowShader.contains('gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);'))"
)
$Gradle = $Gradle.Replace('OpenMW 0.51 Patch 12 shadow payload is incomplete.', 'OpenMW 0.51 Patch 12d shadow payload is incomplete.')
Write-Utf8Lf $BuildGradle $Gradle

# Keep the historical Patch-12c helper from rejecting the new superseding
# marker if it is ever run again on this tree.
$Patch12cHelper = Join-Path $ProjectRoot 'tools\apply-openmw-051-patch12c-orthographic-shadows.ps1'
if (Test-Path $Patch12cHelper) {
    $P12c = Read-Lf $Patch12cHelper
    $P12c = $P12c.Replace('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK', 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')
    $P12c = $P12c.Replace('Patch-12 caster compatibility was lost.', 'Patch-12d native shadow clipping marker was lost.')
    Write-Utf8Lf $Patch12cHelper $P12c
}

# Final structural verification.
$SourceCasterText = Read-Lf $SourceCaster
$AssetCasterText = Read-Lf $AssetCaster
$MwShadowText = Read-Lf $MwShadowTechnique
$PatcherText = Read-Lf $RuntimePatcher
$MainText = Read-Lf $MainActivity
$GradleText = Read-Lf $BuildGradle

foreach ($Body in @($SourceCasterText, $AssetCasterText, $MwShadowText, $PatcherText, $MainText, $GradleText)) {
    if (-not $Body.Contains('OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')) {
        throw 'Patch 12d verification failed: native-clipping marker missing from one or more required files.'
    }
}
foreach ($Body in @($SourceCasterText, $AssetCasterText, $PatcherText, $MainText, $GradleText)) {
    if ($Body.Contains('gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);') -and
        -not ($Body -eq $PatcherText -or $Body -eq $MainText -or $Body -eq $GradleText)) {
        throw 'Patch 12d verification failed: per-vertex Z clamp remains in a runtime shadow caster.'
    }
}
if ($SourceCasterText.Contains('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK') -or
    $AssetCasterText.Contains('OPENMW_ANDROID_051_GLES2_DEPTH_CLAMP_FALLBACK')) {
    throw 'Patch 12d verification failed: obsolete depth-clamp fallback marker remains in runtime shader.'
}
if (-not $ShadowCppText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12d verification failed: Patch 12c orthographic projection was lost.'
}
if (-not $PatcherText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12d verification failed: Patch 12b receiver bounds were lost.'
}
if (-not $GradleText.Contains("shadowShader.contains('gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);'))")) {
    throw 'Patch 12d Gradle gate does not reject the obsolete vertex clamp.'
}

$AfterSha = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterSha -ne $BeforeSha) {
    throw "Patch 12d must not modify libopenmw.so. Before=$BeforeSha After=$AfterSha"
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12d - native GLES2 shadow clipping: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterSha" -ForegroundColor Green
Write-Host 'No native rebuild is required.' -ForegroundColor Green
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio.' -ForegroundColor Cyan
Write-Host 'Test the known triangle location first with Match Sunlight to sun ON, then OFF.'
