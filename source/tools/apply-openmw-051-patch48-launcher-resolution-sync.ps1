param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'

if (-not (Test-Path -LiteralPath $MainActivity)) {
    throw "Patch 48 requires MainActivity.kt. Missing: $MainActivity"
}

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText(
        $Path,
        ($Text -replace "`r`n", "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$Text = Read-Lf $MainActivity
$Marker = 'OPENMW_ANDROID_051_SYNC_LAUNCHER_RESOLUTION_TO_SETTINGS'

if (-not $Text.Contains($Marker)) {
    $Anchor = @'
                configureDefaultsBin(mapOf(
                        "scaling factor" to "%.2f".format(Locale.ROOT, scaling),
'@

    $Replacement = @'
                // OPENMW_ANDROID_051_SYNC_LAUNCHER_RESOLUTION_TO_SETTINGS
                // defaults.bin provides Android defaults, but an existing user
                // settings.cfg has higher precedence. ChromeOS can therefore retain
                // a previously persisted physical display size (for example
                // 1920x1080) even when the launcher requests 640x360.
                //
                // Keep OpenMW's real [Video] settings synchronized with the
                // launcher-selected logical render size on every game start.
                // If no custom resolution is selected, displayWidth/displayHeight
                // already contain the physical/native size, so stale custom values
                // are also cleared correctly.
                updateSettingsSection(
                    File(Constants.USER_CONFIG, "settings.cfg"),
                    "Video",
                    linkedMapOf(
                        "resolution x" to displayWidth.toString(),
                        "resolution y" to displayHeight.toString()
                    )
                )

                Log.i(
                    TAG,
                    "OpenMW Android launcher resolution synced to settings.cfg: " +
                        "${displayWidth}x${displayHeight}"
                )

                configureDefaultsBin(mapOf(
                        "scaling factor" to "%.2f".format(Locale.ROOT, scaling),
'@

    if (-not $Text.Contains($Anchor)) {
        throw 'Patch 48: configureDefaultsBin anchor was not found. No file was modified.'
    }

    $Text = $Text.Replace($Anchor, $Replacement)
    Write-Utf8Lf $MainActivity $Text
}

# Verification
$Check = Read-Lf $MainActivity

$Required = @(
    'OPENMW_ANDROID_051_SYNC_LAUNCHER_RESOLUTION_TO_SETTINGS',
    'File(Constants.USER_CONFIG, "settings.cfg")',
    '"Video"',
    '"resolution x" to displayWidth.toString()',
    '"resolution y" to displayHeight.toString()',
    'OpenMW Android launcher resolution synced to settings.cfg:'
)

foreach ($Fragment in $Required) {
    if (-not $Check.Contains($Fragment)) {
        throw "Patch 48 verification failed: $Fragment"
    }
}

# Ensure synchronization happens before defaults.bin is generated.
$SyncPos = $Check.IndexOf('OPENMW_ANDROID_051_SYNC_LAUNCHER_RESOLUTION_TO_SETTINGS')
$DefaultsPos = $Check.IndexOf('configureDefaultsBin(mapOf(', $SyncPos)
if ($SyncPos -lt 0 -or $DefaultsPos -lt 0 -or $SyncPos -gt $DefaultsPos) {
    throw 'Patch 48 verification failed: settings.cfg sync is not before configureDefaultsBin.'
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 48 launcher resolution sync: PASS' -ForegroundColor Green
Write-Host 'settings.cfg [Video] resolution: synchronized with launcher'
Write-Host 'Custom resolution: preserved across Android/ChromeOS'
Write-Host 'No custom resolution: native display size restored'
Write-Host 'Native OpenMW library: unchanged'
Write-Host ''
Write-Host 'Build the APK normally and test 640x360 on ChromeOS.'
