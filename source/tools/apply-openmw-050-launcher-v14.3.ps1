$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$MainActivityPath = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$SettingsXmlPath = Join-Path $ProjectRoot 'app\src\main\res\xml\settings.xml'

function Read-Lf([string]$Path) {
    return [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Backup-Once([string]$Path) {
    $backupRoot = Join-Path $ProjectRoot 'tools\patch-backups\v14.3'
    $fullPath = (Resolve-Path $Path).Path
    $relative = $fullPath.Substring($ProjectRoot.Length).TrimStart('\')
    $backup = Join-Path $backupRoot $relative
    $backupDir = Split-Path -Parent $backup

    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    if (-not (Test-Path $backup)) {
        Copy-Item $Path $backup
    }
}

function Replace-RegexOnce(
    [string]$Text,
    [string]$Pattern,
    [string]$Replacement,
    [string]$Label
) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) {
        throw "Cannot apply '$Label': expected exactly one match, found $($matches.Count)."
    }

    $m = $matches[0]
    return $Text.Substring(0, $m.Index) + $Replacement +
        $Text.Substring($m.Index + $m.Length)
}

function Remove-PreferenceByKey([string]$Text, [string]$Key) {
    $pattern =
        '(?ms)^[ \t]*<CheckBoxPreference\b[^>]*android:key="' +
        [regex]::Escape($Key) +
        '"[^>]*/>[ \t]*\n?'
    return [regex]::Replace($Text, $pattern, '')
}

Write-Host 'OpenMW Android v14.3 - OMWFX repair + launcher organization + Skip GUI' -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot"
Write-Host ''

foreach ($required in @($MainActivityPath, $SettingsXmlPath)) {
    if (-not (Test-Path $required)) {
        throw "Required file missing: $required"
    }
}

Backup-Once $MainActivityPath
Backup-Once $SettingsXmlPath

$main = Read-Lf $MainActivityPath
$settings = Read-Lf $SettingsXmlPath

if (-not $main.Contains('// v14.2 OpenMW 0.50 launcher settings')) {
    throw 'v14.2 OpenMW 0.50 launcher settings are missing. Apply v14.2.1 first.'
}
if (-not $main.Contains('private fun readOpenMwSetting(')) {
    throw 'v14.2 readOpenMwSetting() helper is missing.'
}
if (-not $main.Contains('"bloomlinear_android"')) {
    throw 'The expected v13.23.2 OMWFX chain was not found. Refusing to patch an older shader baseline.'
}

# -----------------------------------------------------------------------------
# A. Repair the OpenMW 0.50 OMWFX migration state.
#
# The established launcher deliberately does not rewrite the post-processing
# chain after the OMWFX preset has already been applied, so F2 edits survive.
# After the engine/config migration to 0.50, however, settings.cfg can contain
# a fresh/disabled Post Processing section while SharedPreferences still says
# OMWFX was already applied. The result is that the complete OMWFX chain is
# absent even though the launcher still shows OMWFX selected.
#
# Perform ONE dedicated 0.50 repair. It writes only:
#   [Post Processing]
#   enabled = true
#   chain = wetworld_android,godrays_android,lensflare_android,
#           bloomlinear_android,hdr
#
# It does not touch shaders.yaml or any per-effect F2 uniform values.
# The historical OMWFX preset migration key remains unchanged.
# -----------------------------------------------------------------------------
$omwfxMethod = @'
    // v14.3 OpenMW 0.50 OMWFX state repair
    private fun applyShaderPresetSettings() {
        val selected = prefs.getString("pref_shadersDir_v2", "none") ?: "none"
        val previouslyApplied = prefs.getString(OMWFX_APPLIED_PRESET_KEY, null)
        val openMw050RepairKey = "launcher_omwfx_openmw050_repair_v1"
        val repairPending = !prefs.getBoolean(openMw050RepairKey, false)

        if (selected == OMWFX_PRESET_VALUE) {
            if (previouslyApplied != OMWFX_PRESET_VALUE || repairPending) {
                val chain = availableOmwfxChain()
                val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")
                val oldEnabled =
                    readOpenMwSetting(settingsFile, "Post Processing", "enabled")
                val oldChain =
                    readOpenMwSetting(settingsFile, "Post Processing", "chain")

                updateSettingsSection(
                    settingsFile,
                    "Post Processing",
                    linkedMapOf(
                        "enabled" to "true",
                        "chain" to chain
                    )
                )

                if (repairPending) {
                    Log.i(
                        TAG,
                        "OpenMW 0.50 OMWFX repair: " +
                            "enabled=$oldEnabled, chain=$oldChain -> " +
                            "enabled=true, chain=$chain"
                    )
                    prefs.edit()
                        .putBoolean(openMw050RepairKey, true)
                        .apply()
                } else {
                    Log.i(
                        TAG,
                        "Enabled OMWFX Android v13.23.2 preset with " +
                            "balanced Android Bloom + WetWorld v2 + " +
                            "Godrays + Lensflare: $chain"
                    )
                }
            }
        } else if (previouslyApplied == OMWFX_PRESET_VALUE) {
            val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

            updateSettingsSection(
                settingsFile,
                "Post Processing",
                linkedMapOf(
                    "enabled" to "false",
                    "chain" to ""
                )
            )

            Log.i(TAG, "Disabled OMWFX post-processing preset.")
        }

        if (previouslyApplied != selected) {
            prefs.edit()
                .putString(OMWFX_APPLIED_PRESET_KEY, selected)
                .apply()
        }
    }

'@

$omwfxPattern =
    '(?s)    (?:\/\/ v14\.3 OpenMW 0\.50 OMWFX state repair\n)?' +
    'private fun applyShaderPresetSettings\(\) \{.*?\n    \}\n\n' +
    '(?=    private fun configureDefaultsBin\()'

$omwfxMatches = [regex]::Matches($main, $omwfxPattern)
if ($omwfxMatches.Count -ne 1) {
    throw "Could not safely locate applyShaderPresetSettings(); found $($omwfxMatches.Count) candidates."
}
$m = $omwfxMatches[0]
$main = $main.Substring(0, $m.Index) + $omwfxMethod +
    $main.Substring($m.Index + $m.Length)

Write-Host 'OK: added one-time OpenMW 0.50 OMWFX chain repair without touching F2 effect values.' -ForegroundColor Green

# -----------------------------------------------------------------------------
# B. Reorganize the four new OpenMW 0.50 launcher controls.
#    - Controller Menus / Tooltips -> existing User Interface category,
#      directly after pref_mouse_mode ("Mouse mode in menus").
#    - Audio category title -> simply "Audio".
# -----------------------------------------------------------------------------
$settings = Remove-PreferenceByKey $settings 'pref_omw050_controller_menus'
$settings = Remove-PreferenceByKey $settings 'pref_omw050_controller_tooltips'

# The old dedicated category is empty after removing the two preferences.
$settings = [regex]::Replace(
    $settings,
    '(?ms)^[ \t]*<PreferenceCategory android:title="OpenMW 0\.50 - Controls">\s*</PreferenceCategory>\s*',
    ''
)

if ($settings.Contains('<PreferenceCategory android:title="OpenMW 0.50 - Audio">')) {
    $settings = $settings.Replace(
        '<PreferenceCategory android:title="OpenMW 0.50 - Audio">',
        '<PreferenceCategory android:title="Audio">'
    )
}

$controllerPrefs = @'
        <CheckBoxPreference
            android:key="pref_omw050_controller_menus"
            android:title="Controller Menus"
            android:summary="Use OpenMW 0.50 gamepad-optimized menu navigation."
            android:defaultValue="false" />

        <CheckBoxPreference
            android:key="pref_omw050_controller_tooltips"
            android:title="Controller Tooltips"
            android:summary="Always show item tooltips without pressing R3."
            android:defaultValue="false" />
'@

$mousePattern =
    '(?ms)^[ \t]*<ListPreference\b[^>]*android:key="pref_mouse_mode"[^>]*/>[ \t]*\n?'
$mouseMatches = [regex]::Matches($settings, $mousePattern)
if ($mouseMatches.Count -ne 1) {
    throw "Could not locate pref_mouse_mode in settings.xml; found $($mouseMatches.Count) candidates."
}
$mouse = $mouseMatches[0]
$mouseBlock = $mouse.Value.TrimEnd("`r", "`n")
$mouseReplacement = $mouseBlock + "`n`n" + $controllerPrefs + "`n"
$settings = $settings.Substring(0, $mouse.Index) + $mouseReplacement +
    $settings.Substring($mouse.Index + $mouse.Length)

if (-not $settings.Contains('<PreferenceCategory android:title="Audio">')) {
    throw 'Could not rename the OpenMW 0.50 audio category to "Audio".'
}

Write-Host 'OK: moved Controller Menus/Tooltips directly below Mouse mode in menus.' -ForegroundColor Green
Write-Host 'OK: renamed the new audio category to Audio.' -ForegroundColor Green

# -----------------------------------------------------------------------------
# C. Add Skip GUI as the LAST entry in Advanced.
# -----------------------------------------------------------------------------
$settings = Remove-PreferenceByKey $settings 'pref_skip_gui'

$advancedPattern =
    '(?ms)^[ \t]*<PreferenceCategory android:title="@string/pref_advanced">.*?' +
    '^[ \t]*</PreferenceCategory>'
$advancedMatches = [regex]::Matches($settings, $advancedPattern)
if ($advancedMatches.Count -ne 1) {
    throw "Could not locate the Advanced preference category; found $($advancedMatches.Count) candidates."
}

$advanced = $advancedMatches[0]
$advancedText = $advanced.Value
$closeIndex = $advancedText.LastIndexOf('</PreferenceCategory>')
if ($closeIndex -lt 0) {
    throw 'Advanced category closing tag was not found.'
}

$advancedBody = $advancedText.Substring(0, $closeIndex).TrimEnd()
$advancedClose = $advancedText.Substring($closeIndex)
$skipPreference = @'

        <CheckBoxPreference
            android:key="pref_skip_gui"
            android:title="Skip GUI (press Vol up during launch to show GUI)"
            android:defaultValue="false" />
'@

$newAdvanced = $advancedBody + $skipPreference + "`n    " + $advancedClose
$settings = $settings.Substring(0, $advanced.Index) + $newAdvanced +
    $settings.Substring($advanced.Index + $advanced.Length)

Write-Host 'OK: added Skip GUI as the final Advanced option.' -ForegroundColor Green

# -----------------------------------------------------------------------------
# D. Skip-GUI runtime behavior.
#
# If enabled, a fresh launcher process arms a short 800 ms override window.
# Holding/pressing Volume Up during that window cancels auto-launch and leaves
# the launcher visible. The first Volume-Up press and repeats are consumed until
# release, so using the override does not also raise system volume.
#
# Auto launch goes through checkStartGame(), not directly through startGame(),
# so missing game files/content still produce the normal launcher dialogs.
# -----------------------------------------------------------------------------
$skipMarker = '// v14.3 Skip GUI launch'
if (-not $main.Contains($skipMarker)) {
    $fieldAnchor = '    private lateinit var prefs: SharedPreferences'
    $fieldCount = ([regex]::Matches($main, [regex]::Escape($fieldAnchor))).Count
    if ($fieldCount -ne 1) {
        throw "Expected one prefs field; found $fieldCount."
    }

    $skipFields = @'

    // v14.3 Skip GUI launch
    private val skipGuiHandler =
        android.os.Handler(android.os.Looper.getMainLooper())
    private var skipGuiAutoLaunchPending = false
    private var skipGuiOverrideRequested = false
    private var skipGuiVolumeOverrideHeld = false

    private val skipGuiAutoLaunchRunnable = java.lang.Runnable {
        if (!skipGuiAutoLaunchPending || skipGuiOverrideRequested || isFinishing) {
            return@Runnable
        }

        skipGuiAutoLaunchPending = false
        Log.i(TAG, "Skip GUI: launching game directly after Volume Up override window.")
        checkStartGame()
    }
'@
    $main = $main.Replace($fieldAnchor, $fieldAnchor + $skipFields)

    $prefsAnchor =
        '        prefs = PreferenceManager.getDefaultSharedPreferences(this)'
    $prefsCount = ([regex]::Matches($main, [regex]::Escape($prefsAnchor))).Count
    if ($prefsCount -ne 1) {
        throw "Expected one SharedPreferences initialization; found $prefsCount."
    }

    $prefsInit = @'
        prefs = PreferenceManager.getDefaultSharedPreferences(this)

        // Only a fresh app launch may auto-skip. Activity recreation while the
        // launcher is already open must never unexpectedly start the game.
        skipGuiOverrideRequested = false
        skipGuiVolumeOverrideHeld = false
        skipGuiAutoLaunchPending =
            savedInstanceState == null && prefs.getBoolean("pref_skip_gui", false)
'@
    $main = $main.Replace($prefsAnchor, $prefsInit)

    $bugsnagBlock = @'
        if (prefs.getString("bugsnag_consent", "")!! == "") {
            askBugsnagConsent()
        }
'@
    $bugsnagCount = ([regex]::Matches($main, [regex]::Escape($bugsnagBlock))).Count
    if ($bugsnagCount -ne 1) {
        throw "Expected one Bugsnag consent block; found $bugsnagCount."
    }

    $bugsnagAndSkip = @'
        val bugsnagConsentMissing =
            MyApp.haveBugsnagApiKey &&
                prefs.getString("bugsnag_consent", "").isNullOrEmpty()

        if (prefs.getString("bugsnag_consent", "")!! == "") {
            askBugsnagConsent()
        }

        if (skipGuiAutoLaunchPending) {
            if (bugsnagConsentMissing) {
                // A mandatory first-run consent dialog takes precedence. The
                // user can use Skip GUI normally on the next app launch.
                skipGuiAutoLaunchPending = false
                Log.i(TAG, "Skip GUI: launcher kept open for Bugsnag consent.")
            } else {
                Log.i(
                    TAG,
                    "Skip GUI armed: press/hold Volume Up during startup to show launcher."
                )
                skipGuiHandler.postDelayed(skipGuiAutoLaunchRunnable, 800L)
            }
        }
'@
    $main = $main.Replace($bugsnagBlock, $bugsnagAndSkip)

    $resumeAnchor = '    override fun onResume() {'
    $resumeIndex = $main.IndexOf($resumeAnchor)
    if ($resumeIndex -lt 0) {
        throw 'Could not find onResume() insertion point for Skip GUI key handling.'
    }

    $skipMethods = @'
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) {
            if (skipGuiAutoLaunchPending &&
                event.action == android.view.KeyEvent.ACTION_DOWN) {
                skipGuiOverrideRequested = true
                skipGuiAutoLaunchPending = false
                skipGuiVolumeOverrideHeld = true
                skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)

                Log.i(TAG, "Skip GUI overridden by Volume Up; launcher remains visible.")
                return true
            }

            // Consume repeats and the matching key-up after the override so the
            // shortcut does not also change Android's media volume.
            if (skipGuiVolumeOverrideHeld) {
                if (event.action == android.view.KeyEvent.ACTION_UP) {
                    skipGuiVolumeOverrideHeld = false
                }
                return true
            }
        }

        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)
        skipGuiAutoLaunchPending = false
        super.onDestroy()
    }

'@
    $main = $main.Insert($resumeIndex, $skipMethods)

    Write-Host 'OK: added Skip GUI auto-launch with Volume Up startup override.' -ForegroundColor Green
} else {
    Write-Host 'Skip GUI runtime behavior is already present.' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# E. Final validation.
# -----------------------------------------------------------------------------
foreach ($needle in @(
    '// v14.3 OpenMW 0.50 OMWFX state repair',
    'launcher_omwfx_openmw050_repair_v1',
    'OpenMW 0.50 OMWFX repair:',
    '// v14.3 Skip GUI launch',
    'skipGuiAutoLaunchRunnable',
    'KEYCODE_VOLUME_UP',
    'prefs.getBoolean("pref_skip_gui", false)'
)) {
    if (-not $main.Contains($needle)) {
        throw "MainActivity validation failed; missing: $needle"
    }
}

# Preserve the known-good v13.23.2 chain and historical migration key.
foreach ($needle in @(
    '"wetworld_android"',
    '"godrays_android"',
    '"lensflare_android"',
    '"bloomlinear_android"',
    '"hdr"',
    'launcher_shader_preset_applied_v18_balanced_android_bloom'
)) {
    if (-not $main.Contains($needle)) {
        throw "OMWFX baseline validation failed; missing: $needle"
    }
}

foreach ($key in @(
    'pref_omw050_controller_menus',
    'pref_omw050_controller_tooltips',
    'pref_omw050_doppler',
    'pref_omw050_camera_listener',
    'pref_skip_gui'
)) {
    $count = ([regex]::Matches($settings, 'android:key="' + [regex]::Escape($key) + '"')).Count
    if ($count -ne 1) {
        throw "settings.xml validation failed for $key; expected exactly one entry, found $count."
    }
}

if ($settings.Contains('OpenMW 0.50 - Controls')) {
    throw 'Old OpenMW 0.50 - Controls category still exists.'
}
if ($settings.Contains('OpenMW 0.50 - Audio')) {
    throw 'Old OpenMW 0.50 - Audio category title still exists.'
}
if (-not $settings.Contains('<PreferenceCategory android:title="Audio">')) {
    throw 'Audio category title validation failed.'
}

# Ensure controller controls really follow the mouse mode preference.
$mousePos = $settings.IndexOf('android:key="pref_mouse_mode"')
$controllerMenusPos = $settings.IndexOf('android:key="pref_omw050_controller_menus"')
$controllerTooltipsPos = $settings.IndexOf('android:key="pref_omw050_controller_tooltips"')
if ($mousePos -lt 0 -or $controllerMenusPos -le $mousePos -or
    $controllerTooltipsPos -le $controllerMenusPos) {
    throw 'Controller preference ordering validation failed.'
}

# Ensure Skip GUI is inside Advanced and comes after graphics-library selection.
$advancedPos = $settings.IndexOf('<PreferenceCategory android:title="@string/pref_advanced">')
$graphicsLibraryPos = $settings.IndexOf('android:key="pref_graphicsLibrary_v2"', $advancedPos)
$skipGuiPos = $settings.IndexOf('android:key="pref_skip_gui"', $advancedPos)
if ($advancedPos -lt 0 -or $graphicsLibraryPos -lt 0 -or $skipGuiPos -le $graphicsLibraryPos) {
    throw 'Skip GUI Advanced-category ordering validation failed.'
}

Write-Utf8Lf $MainActivityPath $main
Write-Utf8Lf $SettingsXmlPath $settings

Write-Host ''
Write-Host 'OpenMW Android v14.3 launcher update: SUCCESS' -ForegroundColor Green
Write-Host 'Changes included:' -ForegroundColor Cyan
Write-Host '  - one-time OpenMW 0.50 OMWFX chain repair'
Write-Host '  - preserves v13.23.2 WetWorld/Godrays/Lensflare/Balanced Bloom/HDR chain'
Write-Host '  - Controller Menus + Tooltips moved to User Interface'
Write-Host '  - new audio category renamed to Audio'
Write-Host '  - Skip GUI checkbox added at bottom of Advanced'
Write-Host '  - Volume Up during the 800 ms startup window keeps launcher visible'
Write-Host ''
Write-Host 'No native/WSL rebuild is required.' -ForegroundColor Green
Write-Host 'No payload finalizer and no Gradle clean are required.' -ForegroundColor Green
Write-Host 'Build with: .\gradlew.bat :app:assembleMainlineDebug' -ForegroundColor Cyan
