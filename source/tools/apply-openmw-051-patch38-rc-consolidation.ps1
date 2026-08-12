$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Assert-ContainsAll([string]$Path, [string[]]$RequiredTokens) {
    $Text = Read-Lf $Path
    foreach ($Token in $RequiredTokens) {
        if (-not $Text.Contains($Token)) {
            throw "Patch 38 validation failed for $Path. Missing: $Token"
        }
    }
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "Patch 38 refused a modified retained file: $Path expected=$Expected actual=$Actual"
    }
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$NativeSha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch35-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$FragmentSettings = Join-Path $ProjectRoot 'app\src\main\java\ui\fragments\FragmentSettings.kt'
$SettingsXml = Join-Path $ProjectRoot 'app\src\main\res\xml\settings.xml'
$EngineXml = Join-Path $ProjectRoot 'app\src\main\res\xml\gs_engine.xml'
$StringsXml = Join-Path $ProjectRoot 'app\src\main\res\values\strings.xml'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$OmwfxAssetDir = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx'
$Bloom = Join-Path $OmwfxAssetDir 'gateh_bloom051.omwfx'
$Godrays = Join-Path $OmwfxAssetDir 'godrays_android_051_depthfixed_vivid.omwfx'
$Lensflare = Join-Path $OmwfxAssetDir 'lensflare_android_051_rayocc.omwfx'
$RainLens = Join-Path $OmwfxAssetDir 'rainlens_android_051_v12_dense.omwfx'
$WetWorld = Join-Path $OmwfxAssetDir 'wetworld_android_051_weather.omwfx'
$WaterShader = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\water.frag'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $NativeSha,
    $RuntimePatcher,
    $MainActivity,
    $FragmentSettings,
    $SettingsXml,
    $EngineXml,
    $StringsXml,
    $BuildGradle,
    $Bloom,
    $Godrays,
    $Lensflare,
    $RainLens,
    $WetWorld,
    $WaterShader
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 38 requires the completed Patch-37 project plus the extracted Patch-38 files. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 38 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $NativeSha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 38 requires the exact verified WetWorld native library. expected=$ExpectedNativeSha actual=$ActualNativeSha"
}

Assert-Sha256 $RuntimePatcher '8c66bd0a222f278ecb02b588be3c39608af703191aa45dffa378834c9bb37447'
Assert-Sha256 $FragmentSettings '041a8d49837062fdb4abb41079923990d0a57ed2fee2569e3b38c1b33090bbe0'
Assert-Sha256 $SettingsXml '68839f12828e9afe7cf420e5a56d28f0dac07ee95ebaa6b65d6e8673aa6f8980'
Assert-Sha256 $EngineXml 'b2d09b76702b9c2d1dbe319474eea5fca93cac3e867510a04dc71513221c4efe'
Assert-Sha256 $StringsXml '77ca19ee2635c6186b3b01ce2bf3140223aafa7e3d8a774372508e58acfbe78d'
Assert-Sha256 $Bloom '61297e5cfa7fee016d7bdaedc7c3147f7e37babe41bb6bf613eef3819a4c4c53'
Assert-Sha256 $Godrays '2441858e1c5971663dc4489bddf9c96791fa15ddaf6ea8f77d8c89ce4fca4cfe'
Assert-Sha256 $Lensflare '785a017542ea1add0fb8caf63de48a31998e8451bdcb1defa045401de6053ca4'
Assert-Sha256 $RainLens '1e17bd665ac1b445372f6a016bf9baa4e4bc65ee5ff80d36c1c36db4050d5446'
Assert-Sha256 $WetWorld '4d1c205e9514e9d489dd325ccee80bb97e2776dc59bffe7e2577a014d5958c57'
Assert-Sha256 $WaterShader 'd717b2112fae4006a683029fbbca288145372897b5df62f43575febffec802e8'

Assert-ContainsAll $MainActivity @(
    'private fun applyOpenMw051RuntimeSettings()',
    'OMWFX_RECOMMENDED_CHAIN.joinToString(",")',
    'val omwfxSelected = selectedShaderPreset == OMWFX_PRESET_VALUE',
    'val obsoleteAndroidOmwfxShaders = listOf(',
    'OpenMW 0.51 Android release runtime:',
    'Synced OpenMW 0.51 Android OMWFX release payload:',
    'migrateOpenMw051SettingsPreferences()',
    'private fun controllerTriggerThresholds(): Pair<Int, Int>',
    'private fun applyOpenMw051LauncherSettings()',
    'text = "ARM64 \u2022 v${BuildConfig.VERSION_NAME}"',
    'launcher_shader_preset_applied_v35_openmw051_gate_h5a'
)

$MainText = Read-Lf $MainActivity
foreach ($Forbidden in @(
    'applyOpenMw051RuntimeGateSettings()',
    'omwfxGateH5aSelected',
    'gateH5aBlockedShaders',
    'OMWFX Gate H5a was selected',
    'OpenMW 0.51 Patch 35 Gate H5a runtime'
)) {
    if ($MainText.Contains($Forbidden)) {
        throw "Patch 38 MainActivity still contains obsolete development state: $Forbidden"
    }
}

Assert-ContainsAll $BuildGradle @(
    'OpenMW 0.51 Android release-candidate baseline',
    'Checks the consolidated OpenMW 0.51 Android release-candidate payload.',
    'private fun applyOpenMw051RuntimeSettings()',
    'OMWFX_RECOMMENDED_CHAIN.joinToString(",")',
    'launcherMainActivity.contains(''Gate H5a'')',
    'def finalBloom =',
    'def finalLensflare =',
    'def finalGodrays =',
    'def finalRainLens =',
    'def finalWetWorld =',
    'openmw-051-patch35-libopenmw.sha256',
    'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH',
    'OPENMW_ANDROID_051_WETWORLD_WATER_MASK'
)

foreach ($XmlPath in @($SettingsXml, $EngineXml, $StringsXml)) {
    $Document = New-Object System.Xml.XmlDocument
    $Document.PreserveWhitespace = $true
    $Document.Load($XmlPath)
}

$SettingsText = Read-Lf $SettingsXml
$ControllerTooltipsIndex = $SettingsText.IndexOf('android:key="pref_omw050_controller_tooltips"')
$ControllerTriggerIndex = $SettingsText.IndexOf('android:key="pref_omw051_controller_trigger_thresholds"')
$OnScreenControlsIndex = $SettingsText.IndexOf('android:key="pref_controls"')
$HideOnScreenButtonsIndex = $SettingsText.IndexOf('android:key="pref_hide_controls"')
if (
    $ControllerTooltipsIndex -lt 0 -or
    $ControllerTriggerIndex -le $ControllerTooltipsIndex -or
    $OnScreenControlsIndex -le $ControllerTriggerIndex -or
    $HideOnScreenButtonsIndex -le $OnScreenControlsIndex
) {
    throw 'Patch 38 retained launcher setting order is invalid.'
}

$ObsoleteAssets = @(
    'gateh_probe.omwfx',
    'bloomlinear_android.omwfx',
    'lensflare_android.omwfx',
    'lensflare_android_051.omwfx',
    'lensflare_android_051_occ.omwfx',
    'lensflare_android_051_depthocc.omwfx',
    'lensflare_android_051_h2f.omwfx',
    'godrays_android.omwfx',
    'godrays_android_051.omwfx',
    'godrays_android_051_rayocc.omwfx',
    'godrays_android_051_dynamic.omwfx',
    'godrays_android_051_depthfixed.omwfx',
    'rainlens_android.omwfx',
    'rainlens_android_051_weather.omwfx',
    'rainlens_android_051_teardrops.omwfx',
    'rainlens_android_051_v12.omwfx',
    'wetworld_android.omwfx'
)

$RemovedAssets = 0
foreach ($AssetName in $ObsoleteAssets) {
    $AssetPath = Join-Path $OmwfxAssetDir $AssetName
    if (Test-Path -LiteralPath $AssetPath) {
        Remove-Item -LiteralPath $AssetPath -Force
        $RemovedAssets++
    }
}

$PythonCache = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\__pycache__'
$RemovedPythonCache = Test-Path -LiteralPath $PythonCache
if ($RemovedPythonCache) {
    Remove-Item -LiteralPath $PythonCache -Recurse -Force
}

foreach ($AssetName in $ObsoleteAssets) {
    $AssetPath = Join-Path $OmwfxAssetDir $AssetName
    if (Test-Path -LiteralPath $AssetPath) {
        throw "Patch 38 failed to remove obsolete OMWFX asset: $AssetPath"
    }
}

Write-Host 'OpenMW 0.51 Patch 38 release-candidate consolidation: PASS'
Write-Host 'Native rebuild: NO'
Write-Host 'Normal APK build: YES'
Write-Host 'Runtime behavior: unchanged confirmed shadows and five-effect OMWFX chain'
Write-Host "Removed obsolete Android OMWFX assets: $RemovedAssets"
Write-Host "Removed Python cache: $RemovedPythonCache"
