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
    $backupRoot = Join-Path $ProjectRoot 'tools\patch-backups\v14.4'
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

function Remove-PreferenceByKey([string]$Text, [string]$Key) {
    $pattern =
        '(?ms)^[ \t]*<CheckBoxPreference\b[^>]*android:key="' +
        [regex]::Escape($Key) +
        '"[^>]*/>[ \t]*\n?'
    return [regex]::Replace($Text, $pattern, '')
}

Write-Host 'OpenMW Android v14.4 - no-flash Skip GUI + OMWFX 0.50 diagnostic preparation' -ForegroundColor Cyan
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

if (-not $main.Contains('// v14.3 Skip GUI launch')) {
    throw 'v14.3 Skip GUI runtime is missing. Apply v14.3 first.'
}
if (-not $main.Contains('// v14.3 OpenMW 0.50 OMWFX state repair')) {
    throw 'v14.3 OpenMW 0.50 OMWFX repair is missing. Apply v14.3 first.'
}
if (-not $settings.Contains('android:key="pref_skip_gui"')) {
    throw 'v14.3 pref_skip_gui is missing from settings.xml.'
}

# -----------------------------------------------------------------------------
# A. Put Skip GUI FIRST in Advanced and use the requested exact wording.
# -----------------------------------------------------------------------------
$settings = Remove-PreferenceByKey $settings 'pref_skip_gui'

$advancedOpenPattern = '(?m)^([ \t]*)<PreferenceCategory android:title="@string/pref_advanced">[ \t]*$'
$advancedOpenMatches = [regex]::Matches($settings, $advancedOpenPattern)
if ($advancedOpenMatches.Count -ne 1) {
    throw "Could not locate the Advanced preference category opening tag; found $($advancedOpenMatches.Count) candidates."
}

$advancedOpen = $advancedOpenMatches[0]
$skipPreference = @'

        <CheckBoxPreference
            android:key="pref_skip_gui"
            android:title="Skip GUI (press 'Volume up' during launch to show GUI again)"
            android:defaultValue="false" />
'@

$insertAt = $advancedOpen.Index + $advancedOpen.Length
$settings = $settings.Substring(0, $insertAt) + $skipPreference + $settings.Substring($insertAt)

Write-Host "OK: Skip GUI is now the first Advanced option with the requested label." -ForegroundColor Green

# -----------------------------------------------------------------------------
# B. Make Skip GUI visually silent.
#
# v14.3 armed the shortcut only after setContentView(), which let the launcher
# become visible briefly. v14.4 decides the fresh-launch skip before attaching
# the layout and makes the Activity decor transparent while the 800 ms Volume
# Up override window is active. The normal launcher is still built internally,
# so the override can reveal it immediately without a second Activity setup.
#
# The separate "Preparing for launch..." ProgressDialog is also suppressed for
# the direct path. Any validation/preparation error restores the launcher first.
# -----------------------------------------------------------------------------
$marker = '// v14.4 Skip GUI no-flash'
if (-not $main.Contains($marker)) {
    $fieldAnchor = '    private var skipGuiVolumeOverrideHeld = false'
    $fieldCount = ([regex]::Matches($main, [regex]::Escape($fieldAnchor))).Count
    if ($fieldCount -ne 1) {
        throw "Could not locate the v14.3 Skip GUI state fields exactly once; found $fieldCount."
    }
    $main = $main.Replace(
        $fieldAnchor,
        $fieldAnchor + "`n    private var skipGuiDirectLaunchActive = false`n`n    $marker"
    )

    $oldRunnable = @'
        skipGuiAutoLaunchPending = false
        Log.i(TAG, "Skip GUI: launching game directly after Volume Up override window.")
        checkStartGame()
'@
    $newRunnable = @'
        skipGuiAutoLaunchPending = false
        skipGuiDirectLaunchActive = true
        Log.i(TAG, "Skip GUI: launching game directly after Volume Up override window.")
        checkStartGame()
'@
    if (-not $main.Contains($oldRunnable)) {
        throw 'Could not locate the v14.3 Skip GUI auto-launch runnable body.'
    }
    $main = $main.Replace($oldRunnable, $newRunnable)

    $oldOnCreateInit = @'
        PermissionHelper.getWriteExternalStoragePermission(this@MainActivity)
        setContentView(R.layout.main)
        prefs = PreferenceManager.getDefaultSharedPreferences(this)

        // Only a fresh app launch may auto-skip. Activity recreation while the
        // launcher is already open must never unexpectedly start the game.
        skipGuiOverrideRequested = false
        skipGuiVolumeOverrideHeld = false
        skipGuiAutoLaunchPending =
            savedInstanceState == null && prefs.getBoolean("pref_skip_gui", false)
'@
    $newOnCreateInit = @'
        prefs = PreferenceManager.getDefaultSharedPreferences(this)

        // Only a fresh app launch may auto-skip. Activity recreation while the
        // launcher is already open must never unexpectedly start the game.
        // A first-run Bugsnag consent dialog must remain visible and therefore
        // takes precedence over the direct-launch path.
        val bugsnagConsentMissing =
            MyApp.haveBugsnagApiKey &&
                prefs.getString("bugsnag_consent", "").isNullOrEmpty()

        skipGuiOverrideRequested = false
        skipGuiVolumeOverrideHeld = false
        skipGuiDirectLaunchActive = false
        skipGuiAutoLaunchPending =
            savedInstanceState == null &&
                prefs.getBoolean("pref_skip_gui", false) &&
                !bugsnagConsentMissing

        if (skipGuiAutoLaunchPending) {
            // Hide the actual launcher layout before it can be presented. The
            // Android system launch/splash window is outside this Activity and
            // may still be visible briefly depending on the device firmware.
            window.decorView.alpha = 0f
            Log.i(TAG, "Skip GUI: launcher decor hidden before layout presentation.")
        }

        PermissionHelper.getWriteExternalStoragePermission(this@MainActivity)
        setContentView(R.layout.main)
'@
    if (-not $main.Contains($oldOnCreateInit)) {
        throw 'Could not locate the v14.3 onCreate Skip GUI initialization block.'
    }
    $main = $main.Replace($oldOnCreateInit, $newOnCreateInit)

    $oldBugsnagAndSkip = @'
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
    $newBugsnagAndSkip = @'
        if (prefs.getString("bugsnag_consent", "")!! == "") {
            askBugsnagConsent()
        }

        if (skipGuiAutoLaunchPending) {
            Log.i(
                TAG,
                "Skip GUI armed: press/hold Volume Up during startup to show launcher."
            )
            skipGuiHandler.postDelayed(skipGuiAutoLaunchRunnable, 800L)
        }
'@
    if (-not $main.Contains($oldBugsnagAndSkip)) {
        throw 'Could not locate the v14.3 Bugsnag/Skip GUI scheduling block.'
    }
    $main = $main.Replace($oldBugsnagAndSkip, $newBugsnagAndSkip)

    $oldOverride = @'
                skipGuiOverrideRequested = true
                skipGuiAutoLaunchPending = false
                skipGuiVolumeOverrideHeld = true
                skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)

                Log.i(TAG, "Skip GUI overridden by Volume Up; launcher remains visible.")
                return true
'@
    $newOverride = @'
                skipGuiOverrideRequested = true
                skipGuiAutoLaunchPending = false
                skipGuiDirectLaunchActive = false
                skipGuiVolumeOverrideHeld = true
                skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)
                window.decorView.alpha = 1f

                Log.i(TAG, "Skip GUI overridden by Volume Up; launcher remains visible.")
                return true
'@
    if (-not $main.Contains($oldOverride)) {
        throw 'Could not locate the v14.3 Volume Up override block.'
    }
    $main = $main.Replace($oldOverride, $newOverride)

    $resumeAnchor = '    override fun onResume() {'
    $resumeIndex = $main.IndexOf($resumeAnchor)
    if ($resumeIndex -lt 0) {
        throw 'Could not find onResume() for Skip GUI reveal helper insertion.'
    }
    $revealHelper = @'
    private fun revealLauncherAfterSkipGui(reason: String) {
        if (!skipGuiDirectLaunchActive && window.decorView.alpha >= 1f) {
            return
        }

        skipGuiDirectLaunchActive = false
        skipGuiAutoLaunchPending = false
        skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)
        window.decorView.alpha = 1f
        Log.i(TAG, "Skip GUI: launcher restored ($reason).")
    }

'@
    $main = $main.Insert($resumeIndex, $revealHelper)

    $noDataOld = @'
        if (!inst.check()) {
            AlertDialog.Builder(this)
'@
    $noDataNew = @'
        if (!inst.check()) {
            revealLauncherAfterSkipGui("game files need configuration")
            AlertDialog.Builder(this)
'@
    if (-not $main.Contains($noDataOld)) {
        throw 'Could not locate the no-data-files validation dialog.'
    }
    $main = $main.Replace($noDataOld, $noDataNew)

    $noModsOld = @'
        if (plugins.mods.count { it.enabled } == 0) {
            // No mods enabled, show a warning
            AlertDialog.Builder(this)
'@
    $noModsNew = @'
        if (plugins.mods.count { it.enabled } == 0) {
            // No mods enabled, show a warning
            revealLauncherAfterSkipGui("content selection needs confirmation")
            AlertDialog.Builder(this)
'@
    if (-not $main.Contains($noModsOld)) {
        throw 'Could not locate the no-content-files warning dialog.'
    }
    $main = $main.Replace($noModsOld, $noModsNew)

    $progressOld = @'
        val dialog = ProgressDialog.show(
            this, "", "Preparing for launch...", true)
'@
    $progressNew = @'
        val dialog = if (skipGuiDirectLaunchActive) {
            null
        } else {
            ProgressDialog.show(this, "", "Preparing for launch...", true)
        }
'@
    if (-not $main.Contains($progressOld)) {
        throw 'Could not locate the Preparing for launch ProgressDialog.'
    }
    $main = $main.Replace($progressOld, $progressNew)

    $successOld = @'
                runOnUiThread {
                    obtainFixedScreenResolution()
                    dialog.dismiss()
                    runGame()
                }
'@
    $successNew = @'
                runOnUiThread {
                    obtainFixedScreenResolution()
                    dialog?.dismiss()
                    runGame()
                }
'@
    if (-not $main.Contains($successOld)) {
        throw 'Could not locate the successful launch ProgressDialog dismissal.'
    }
    $main = $main.Replace($successOld, $successNew)

    $failureOld = @'
                runOnUiThread {
                    dialog.dismiss()
                    AlertDialog.Builder(activity)
'@
    $failureNew = @'
                runOnUiThread {
                    revealLauncherAfterSkipGui("launch preparation failed")
                    dialog?.dismiss()
                    AlertDialog.Builder(activity)
'@
    if (-not $main.Contains($failureOld)) {
        throw 'Could not locate the failed launch ProgressDialog dismissal.'
    }
    $main = $main.Replace($failureOld, $failureNew)

    Write-Host 'OK: Skip GUI launcher layout is hidden before presentation and direct launch has no progress dialog.' -ForegroundColor Green
    Write-Host 'OK: Volume Up / validation errors restore the normal launcher immediately.' -ForegroundColor Green
} else {
    Write-Host 'v14.4 Skip GUI no-flash runtime is already present.' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# C. Final validation.
# -----------------------------------------------------------------------------
foreach ($needle in @(
    '// v14.3 Skip GUI launch',
    '// v14.4 Skip GUI no-flash',
    'skipGuiDirectLaunchActive',
    'window.decorView.alpha = 0f',
    'window.decorView.alpha = 1f',
    'revealLauncherAfterSkipGui(',
    'dialog?.dismiss()',
    'launcher_shader_preset_applied_v18_balanced_android_bloom'
)) {
    if (-not $main.Contains($needle)) {
        throw "MainActivity validation failed; missing: $needle"
    }
}

$skipCount = ([regex]::Matches($settings, 'android:key="pref_skip_gui"')).Count
if ($skipCount -ne 1) {
    throw "settings.xml validation failed for pref_skip_gui; expected one entry, found $skipCount."
}
if (-not $settings.Contains('android:title="Skip GUI (press ''Volume up'' during launch to show GUI again)"')) {
    throw 'Skip GUI exact label validation failed.'
}

$advancedStart = $settings.IndexOf('<PreferenceCategory android:title="@string/pref_advanced">')
$advancedEnd = $settings.IndexOf('</PreferenceCategory>', $advancedStart)
if ($advancedStart -lt 0 -or $advancedEnd -lt 0) {
    throw 'Advanced category validation failed.'
}
$advancedText = $settings.Substring($advancedStart, $advancedEnd - $advancedStart)
$keyMatches = [regex]::Matches($advancedText, 'android:key="([^"]+)"')
if ($keyMatches.Count -lt 1 -or $keyMatches[0].Groups[1].Value -ne 'pref_skip_gui') {
    throw 'Skip GUI is not the first keyed entry inside Advanced.'
}

Write-Utf8Lf $MainActivityPath $main
Write-Utf8Lf $SettingsXmlPath $settings

Write-Host ''
Write-Host 'OpenMW Android v14.4 launcher update: SUCCESS' -ForegroundColor Green
Write-Host '  - Skip GUI is the first Advanced option' -ForegroundColor Cyan
Write-Host "  - label: Skip GUI (press 'Volume up' during launch to show GUI again)"
Write-Host '  - launcher decor hidden before layout presentation while direct launch is armed'
Write-Host '  - Volume Up restores launcher; direct path suppresses Preparing for launch dialog'
Write-Host '  - validation/preparation errors restore launcher before showing dialogs'
Write-Host ''
Write-Host 'Launcher part requires only a normal Gradle rebuild.' -ForegroundColor Green
