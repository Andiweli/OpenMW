$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$MainActivityPath = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$SettingsXmlPath = Join-Path $ProjectRoot 'app\src\main\res\xml\settings.xml'
$ManifestPath = Join-Path $ProjectRoot 'app\src\main\AndroidManifest.xml'
$V141Script = Join-Path $PSScriptRoot 'apply-openmw-050-launcher-polish.ps1'

function Read-Lf([string]$Path) {
    return [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Backup-Once([string]$Path) {
    $backupRoot = Join-Path $ProjectRoot 'tools\patch-backups\v14.2.1'
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

Write-Host 'OpenMW Android v14.2.1 - OpenMW 0.50 launcher settings' -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot"
Write-Host ''

# v14.2 accidentally placed a backup file inside res/xml. Android's resource
# merger treats every file in that directory as a resource and rejects this
# non-.xml filename. Remove that stale patch artifact before any build.
$staleResourceBackups = @(
    (Join-Path $ProjectRoot 'app\src\main\res\xml\settings.xml.before-v14.2-openmw050-settings')
)
foreach ($stale in $staleResourceBackups) {
    if (Test-Path $stale) {
        Remove-Item $stale -Force
        Write-Host "Removed stale Android resource backup: $stale" -ForegroundColor Yellow
    }
}

foreach ($required in @($MainActivityPath, $SettingsXmlPath, $ManifestPath, $V141Script)) {
    if (-not (Test-Path $required)) {
        throw "Required file missing: $required"
    }
}

# Ensure the v14.1 launcher polish exists first. The bundled script is v14.1.1
# and contains the compile fix for the invalid ScrollView.LayoutParams reference.
$main = Read-Lf $MainActivityPath
if (-not $main.Contains('// v14.1 launcher popup/about polish')) {
    Write-Host 'v14.1 launcher polish not found; applying corrected v14.1.1 first...' -ForegroundColor Yellow
    & $V141Script
}

Backup-Once $MainActivityPath
Backup-Once $SettingsXmlPath
Backup-Once $ManifestPath

$main = Read-Lf $MainActivityPath

# -----------------------------------------------------------------------------
# A. Fix the v14.1 Kotlin build error unconditionally.
# ScrollView inherits FrameLayout, but ScrollView.LayoutParams is not a valid
# Kotlin nested type reference. Use FrameLayout.LayoutParams explicitly.
# -----------------------------------------------------------------------------
if ($main.Contains('android.widget.ScrollView.LayoutParams(')) {
    $main = $main.Replace(
        'android.widget.ScrollView.LayoutParams(',
        'android.widget.FrameLayout.LayoutParams('
    )
}
if ($main.Contains('android.widget.ScrollView.LayoutParams(')) {
    throw 'Failed to remove the invalid ScrollView.LayoutParams reference.'
}
Write-Host 'OK: fixed About dialog LayoutParams compile error.' -ForegroundColor Green

# -----------------------------------------------------------------------------
# B. Add OpenMW 0.50 preferences to the launcher settings screen.
# Official 0.50 defaults:
#   [GUI] controller menus = false
#   [GUI] controller tooltips = false
#   [Sound] camera listener = false
#   [Sound] doppler factor = 0.25
# -----------------------------------------------------------------------------
$settings = Read-Lf $SettingsXmlPath
if (-not $settings.Contains('pref_omw050_controller_menus')) {
    $advancedAnchor = '    <PreferenceCategory android:title="@string/pref_advanced">'
    $advancedIndex = $settings.IndexOf($advancedAnchor)
    if ($advancedIndex -lt 0) {
        throw 'Could not find the Advanced preference category insertion point in settings.xml.'
    }

    $openmw050Prefs = @'
    <PreferenceCategory android:title="OpenMW 0.50 - Controls">
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
    </PreferenceCategory>

    <PreferenceCategory android:title="OpenMW 0.50 - Audio">
        <CheckBoxPreference
            android:key="pref_omw050_doppler"
            android:title="Doppler Effect"
            android:summary="Enable OpenMW 0.50 positional-audio Doppler effect (factor 0.25)."
            android:defaultValue="true" />

        <CheckBoxPreference
            android:key="pref_omw050_camera_listener"
            android:title="Camera as Audio Listener"
            android:summary="Use the camera position instead of the player as the 3D audio listener."
            android:defaultValue="false" />
    </PreferenceCategory>

'@
    $settings = $settings.Insert($advancedIndex, $openmw050Prefs)
    Write-Host 'OK: added OpenMW 0.50 Controls and Audio categories to settings.xml.' -ForegroundColor Green
} else {
    Write-Host 'OpenMW 0.50 preferences already exist in settings.xml.' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# C. Preserve existing settings.cfg values on first migration, then let the
# launcher own these four settings.
# -----------------------------------------------------------------------------
$marker = '// v14.2 OpenMW 0.50 launcher settings'
if (-not $main.Contains($marker)) {
    $migrationCallAnchor = '        migrateObjectPagingMinSizeDefault()'
    $callCount = ([regex]::Matches($main, [regex]::Escape($migrationCallAnchor))).Count
    if ($callCount -ne 1) {
        throw "Expected exactly one migrateObjectPagingMinSizeDefault() call; found $callCount."
    }

    $main = $main.Replace(
        $migrationCallAnchor,
        $migrationCallAnchor + "`n        migrateOpenMw050SettingsPreferences()"
    )

    $helperAnchor = '    private fun applyShaderPresetSettings() {'
    $helperIndex = $main.IndexOf($helperAnchor)
    if ($helperIndex -lt 0) {
        throw 'Could not find applyShaderPresetSettings() insertion point in MainActivity.kt.'
    }

    $helper = @'
    // v14.2 OpenMW 0.50 launcher settings
    private fun readOpenMwSetting(
        file: File,
        sectionName: String,
        key: String
    ): String? {
        if (!file.isFile) {
            return null
        }

        val wantedSection = "[$sectionName]"
        var inSection = false

        return try {
            for (line in file.readLines()) {
                val trimmed = line.trim()

                if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
                    inSection = trimmed.equals(wantedSection, ignoreCase = true)
                    continue
                }

                if (!inSection || trimmed.isEmpty() ||
                    trimmed.startsWith("#") || trimmed.startsWith(";")) {
                    continue
                }

                val equals = trimmed.indexOf('=')
                if (equals <= 0) {
                    continue
                }

                val foundKey = trimmed.substring(0, equals).trim()
                if (foundKey.equals(key, ignoreCase = true)) {
                    return trimmed.substring(equals + 1)
                        .substringBefore('#')
                        .substringBefore(';')
                        .trim()
                }
            }

            null
        } catch (e: IOException) {
            Log.w(TAG, "Could not read OpenMW 0.50 setting [$sectionName] $key", e)
            null
        }
    }

    /**
     * Import existing user choices once. If settings.cfg does not contain one
     * of the new OpenMW 0.50 settings, use the official 0.50 default.
     *
     * This means an existing hand-edited settings.cfg is respected when the
     * new launcher controls first appear.
     */
    private fun migrateOpenMw050SettingsPreferences() {
        val migrationKey = "migration_openmw050_launcher_settings_v1"
        if (prefs.getBoolean(migrationKey, false)) {
            return
        }

        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

        fun readBoolean(section: String, key: String, defaultValue: Boolean): Boolean {
            val raw = readOpenMwSetting(settingsFile, section, key) ?: return defaultValue
            return when {
                raw.equals("true", ignoreCase = true) -> true
                raw.equals("false", ignoreCase = true) -> false
                else -> defaultValue
            }
        }

        val controllerMenus =
            readBoolean("GUI", "controller menus", false)
        val controllerTooltips =
            readBoolean("GUI", "controller tooltips", false)
        val cameraListener =
            readBoolean("Sound", "camera listener", false)

        val dopplerFactor =
            readOpenMwSetting(settingsFile, "Sound", "doppler factor")
                ?.toDoubleOrNull()
        val dopplerEnabled = dopplerFactor?.let { it != 0.0 } ?: true

        prefs.edit()
            .putBoolean("pref_omw050_controller_menus", controllerMenus)
            .putBoolean("pref_omw050_controller_tooltips", controllerTooltips)
            .putBoolean("pref_omw050_doppler", dopplerEnabled)
            .putBoolean("pref_omw050_camera_listener", cameraListener)
            .putBoolean(migrationKey, true)
            .apply()

        Log.i(
            TAG,
            "Imported OpenMW 0.50 launcher settings: " +
                "controllerMenus=$controllerMenus, " +
                "controllerTooltips=$controllerTooltips, " +
                "doppler=$dopplerEnabled, " +
                "cameraListener=$cameraListener"
        )
    }

    /**
     * Write only the four launcher-owned OpenMW 0.50 settings to the user's
     * settings.cfg. Unrelated settings and OMWFX/F2 edits remain untouched.
     */
    private fun applyOpenMw050LauncherSettings() {
        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

        val controllerMenus =
            prefs.getBoolean("pref_omw050_controller_menus", false)
        val controllerTooltips =
            prefs.getBoolean("pref_omw050_controller_tooltips", false)
        val dopplerEnabled =
            prefs.getBoolean("pref_omw050_doppler", true)
        val cameraListener =
            prefs.getBoolean("pref_omw050_camera_listener", false)

        updateSettingsSection(
            settingsFile,
            "GUI",
            linkedMapOf(
                "controller menus" to if (controllerMenus) "true" else "false",
                "controller tooltips" to if (controllerTooltips) "true" else "false"
            )
        )

        updateSettingsSection(
            settingsFile,
            "Sound",
            linkedMapOf(
                "doppler factor" to if (dopplerEnabled) "0.25" else "0.0",
                "camera listener" to if (cameraListener) "true" else "false"
            )
        )

        Log.i(
            TAG,
            "Applied OpenMW 0.50 launcher settings: " +
                "controllerMenus=$controllerMenus, " +
                "controllerTooltips=$controllerTooltips, " +
                "doppler=${if (dopplerEnabled) "0.25" else "0.0"}, " +
                "cameraListener=$cameraListener"
        )
    }

'@
    $main = $main.Insert($helperIndex, $helper)

    $applyAnchor = '                applyShaderPresetSettings()'
    $applyCount = ([regex]::Matches($main, [regex]::Escape($applyAnchor))).Count
    if ($applyCount -ne 1) {
        throw "Expected exactly one applyShaderPresetSettings() launch call; found $applyCount."
    }

    $main = $main.Replace(
        $applyAnchor,
        $applyAnchor + "`n`n                // Apply the launcher-owned OpenMW 0.50 controller/audio settings.`n                applyOpenMw050LauncherSettings()"
    )

    Write-Host 'OK: added first-run import and settings.cfg writer for OpenMW 0.50 options.' -ForegroundColor Green
} else {
    Write-Host 'OpenMW 0.50 MainActivity settings integration already exists.' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# D. Final source-side validation.
# -----------------------------------------------------------------------------
if (-not $main.Contains('android.widget.FrameLayout.LayoutParams(')) {
    throw 'About dialog FrameLayout.LayoutParams fix is missing.'
}
if ($main.Contains('android.widget.ScrollView.LayoutParams(')) {
    throw 'Invalid ScrollView.LayoutParams reference is still present.'
}
foreach ($needle in @(
    'migrateOpenMw050SettingsPreferences()',
    'applyOpenMw050LauncherSettings()',
    '"controller menus"',
    '"controller tooltips"',
    '"doppler factor"',
    '"camera listener"'
)) {
    if (-not $main.Contains($needle)) {
        throw "MainActivity validation failed; missing: $needle"
    }
}
foreach ($needle in @(
    'pref_omw050_controller_menus',
    'pref_omw050_controller_tooltips',
    'pref_omw050_doppler',
    'pref_omw050_camera_listener'
)) {
    if (-not $settings.Contains($needle)) {
        throw "settings.xml validation failed; missing: $needle"
    }
}

Write-Utf8Lf $MainActivityPath $main
Write-Utf8Lf $SettingsXmlPath $settings

Write-Host ''
Write-Host 'OpenMW Android v14.2.1 launcher update: SUCCESS' -ForegroundColor Green
Write-Host 'Changes included:' -ForegroundColor Cyan
Write-Host '  - v14.1 About dialog Kotlin compile fix'
Write-Host '  - Android game classification from v14.1'
Write-Host '  - below-anchor User Configuration popup from v14.1'
Write-Host '  - expandable About licence sections from v14.1'
Write-Host '  - OpenMW 0.50 Controller Menus'
Write-Host '  - OpenMW 0.50 Controller Tooltips'
Write-Host '  - OpenMW 0.50 Doppler Effect'
Write-Host '  - OpenMW 0.50 Camera as Audio Listener'
Write-Host ''
Write-Host 'No native/WSL rebuild is required.' -ForegroundColor Green
Write-Host 'Build with: .\gradlew.bat :app:assembleMainlineDebug' -ForegroundColor Cyan
