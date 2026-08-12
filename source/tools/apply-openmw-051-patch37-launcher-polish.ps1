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
            throw "Patch 37 validation failed for $Path. Missing: $Token"
        }
    }
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "Patch 37 refused a modified retained file: $Path expected=$Expected actual=$Actual"
    }
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$Patch35Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch35-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$FragmentSettings = Join-Path $ProjectRoot 'app\src\main\java\ui\fragments\FragmentSettings.kt'
$SettingsXml = Join-Path $ProjectRoot 'app\src\main\res\xml\settings.xml'
$EngineXml = Join-Path $ProjectRoot 'app\src\main\res\xml\gs_engine.xml'
$StringsXml = Join-Path $ProjectRoot 'app\src\main\res\values\strings.xml'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$Bloom = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\gateh_bloom051.omwfx'
$Godrays = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\godrays_android_051_depthfixed_vivid.omwfx'
$Lensflare = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\lensflare_android_051_rayocc.omwfx'
$RainLens = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\rainlens_android_051_v12_dense.omwfx'
$WetWorld = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\wetworld_android_051_weather.omwfx'
$WaterShader = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources\shaders\compatibility\water.frag'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $Patch35Sha,
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
        throw "Patch 37 requires the completed Patch-36 project plus the extracted Patch-37 files. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 37 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $Patch35Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 37 requires the exact Patch-35 WetWorld native library. expected=$ExpectedNativeSha actual=$ActualNativeSha"
}

Assert-Sha256 $RuntimePatcher '8c66bd0a222f278ecb02b588be3c39608af703191aa45dffa378834c9bb37447'
Assert-Sha256 $Bloom '61297e5cfa7fee016d7bdaedc7c3147f7e37babe41bb6bf613eef3819a4c4c53'
Assert-Sha256 $Godrays '2441858e1c5971663dc4489bddf9c96791fa15ddaf6ea8f77d8c89ce4fca4cfe'
Assert-Sha256 $Lensflare '785a017542ea1add0fb8caf63de48a31998e8451bdcb1defa045401de6053ca4'
Assert-Sha256 $RainLens '1e17bd665ac1b445372f6a016bf9baa4e4bc65ee5ff80d36c1c36db4050d5446'
Assert-Sha256 $WetWorld '4d1c205e9514e9d489dd325ccee80bb97e2776dc59bffe7e2577a014d5958c57'
Assert-Sha256 $WaterShader 'd717b2112fae4006a683029fbbca288145372897b5df62f43575febffec802e8'

# Keep the PowerShell source ASCII-only for Windows PowerShell 5.1, which can
# otherwise decode a UTF-8 script without BOM through the active ANSI codepage.
$PortCreditsToken = '"This port by Andreas \"Andiweli\" St' + [char]0x00FC + 'rmer\n"'

Assert-ContainsAll $MainActivity @(
    'migrateOpenMw050SettingsPreferences()',
    'migrateOpenMw051SettingsPreferences()',
    'private fun controllerTriggerThresholds(): Pair<Int, Int>',
    'private fun applyOpenMw051LauncherSettings()',
    '"pref_omw051_controller_trigger_thresholds"',
    '"gs_groundcover_point_lighting"',
    '"controller trigger press" to triggerPress.toString()',
    '"controller trigger release" to triggerRelease.toString()',
    '"point lighting" to if (groundcoverPointLighting) "true" else "false"',
    'applyOpenMw051LauncherSettings()',
    'text = "ARM64 \u2022 v${BuildConfig.VERSION_NAME}"',
    $PortCreditsToken,
    'OpenMW 0.51 Patch 35 Gate H5a runtime',
    '"wetworld_android_051_weather,godrays_android_051_depthfixed_vivid,lensflare_android_051_rayocc,gateh_bloom051,rainlens_android_051_v12_dense"'
)

Assert-ContainsAll $FragmentSettings @(
    'import android.preference.ListPreference',
    'prepareControllerTriggerPreference()',
    'val key = "pref_omw051_controller_trigger_thresholds"',
    '"Custom ($triggerPress press, $triggerRelease release)"'
)

Assert-ContainsAll $SettingsXml @(
    'android:key="pref_omw051_controller_trigger_thresholds"',
    'android:entries="@array/pref_omw051_controller_trigger_sensitivity_entries"',
    'android:entryValues="@array/pref_omw051_controller_trigger_sensitivity_values"',
    'android:defaultValue="30720,26624"',
    'android:dependency="pref_omw050_controller_menus"',
    'android:summary="@string/pref_nohighp_summary"',
    'Use OpenMW 0.51 gamepad-optimized menu navigation',
    'Enable OpenMW 0.51 positional-audio Doppler effect'
)

Assert-ContainsAll $EngineXml @(
    'android:key="gs_groundcover_point_lighting"',
    'android:title="Point Lighting on Groundcover"',
    'android:defaultValue="true"'
)

Assert-ContainsAll $StringsXml @(
    'name="pref_omw051_controller_trigger_sensitivity_entries"',
    'name="pref_omw051_controller_trigger_sensitivity_values"',
    '<item>30720,26624</item>',
    '<item>24576,20480</item>',
    '<item>16384,12288</item>',
    '<string name="pref_nohighp_summary">Uses medium instead of high precision; available only with the Modified shader preset</string>'
)

Assert-ContainsAll $BuildGradle @(
    'OpenMW 0.51 Patch 37',
    'migrateOpenMw051SettingsPreferences()',
    'pref_omw051_controller_trigger_thresholds',
    'gs_groundcover_point_lighting',
    'openmw-051-patch35-libopenmw.sha256',
    'def gateH5aWetWorld =',
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
    throw 'Patch 37 launcher setting order is invalid.'
}

$MainText = Read-Lf $MainActivity
$VersionInfoIndex = $MainText.IndexOf('text = "ARM64 \u2022 v${BuildConfig.VERSION_NAME}"')
$PortCreditsIndex = $MainText.IndexOf($PortCreditsToken)
if ($VersionInfoIndex -lt 0 -or $PortCreditsIndex -le $VersionInfoIndex) {
    throw 'Patch 37 About version must appear above the port credits.'
}

Write-Host 'OpenMW 0.51 Patch 37 launcher polish validation: PASS'
Write-Host 'Native rebuild: NO'
Write-Host 'Launcher order: Controller Tooltips; Trigger Sensitivity; On-Screen Controls; Hide On-Screen Buttons'
Write-Host 'About: ARM64 plus application version'
Write-Host 'Medium shader precision: explained and still limited to the Modified shader preset'
Write-Host 'Retained runtime: Patch-35 WetWorld + Patch-34 RainLens + Patch-30 optics + Patch-12k shadows'
