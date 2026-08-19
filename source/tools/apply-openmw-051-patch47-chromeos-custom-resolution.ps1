param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SdlActivity = Join-Path $ProjectRoot 'app\src\main\java\org\libsdl\app\SDLActivity.java'

if (-not (Test-Path -LiteralPath $SdlActivity)) {
    throw "Patch 47 requires SDLActivity.java. Missing: $SdlActivity"
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

$Text = Read-Lf $SdlActivity

$Marker = 'OPENMW_CHROMEOS_CUSTOM_RESOLUTION_V1'

if (-not $Text.Contains($Marker)) {
    $Old = @'
        Log.v("SDL", "Window size: " + width + "x" + height);
        Log.v("SDL", "Device size: " + nDeviceWidth + "x" + nDeviceHeight);
        SDLActivity.nativeSetScreenResolution(width, height, nDeviceWidth, nDeviceHeight, mDisplay.getRefreshRate());
        SDLActivity.onNativeResize();
'@

    $New = @'
        Log.v("SDL", "Window size: " + width + "x" + height);
        Log.v("SDL", "Device size: " + nDeviceWidth + "x" + nDeviceHeight);

        // OPENMW_CHROMEOS_CUSTOM_RESOLUTION_V1
        // ARC/ChromeOS may resize the Android SurfaceView back to the physical
        // display size even though OpenMW-Android requested a fixed custom
        // rendering size through SurfaceHolder.setFixedSize().  Keep the real
        // device dimensions for SDL's display information, but preserve the
        // launcher-selected logical window size passed to native SDL/OpenMW.
        //
        // Normal Android devices retain the original path unchanged.
        int nWindowWidth = width;
        int nWindowHeight = height;
        if (SDLActivity.isChromebook() && fixedWidth > 0 && fixedHeight > 0) {
            nWindowWidth = fixedWidth;
            nWindowHeight = fixedHeight;
        }

        SDLActivity.nativeSetScreenResolution(
                nWindowWidth,
                nWindowHeight,
                nDeviceWidth,
                nDeviceHeight,
                mDisplay.getRefreshRate());
        SDLActivity.onNativeResize();
'@

    if (-not $Text.Contains($Old)) {
        throw 'Patch 47: SDL surfaceChanged resolution anchor was not found. No file was modified.'
    }

    $Text = $Text.Replace($Old, $New)
    Write-Utf8Lf $SdlActivity $Text
}

# Verification
$Check = Read-Lf $SdlActivity

$Required = @(
    'OPENMW_CHROMEOS_CUSTOM_RESOLUTION_V1',
    'int nWindowWidth = width;',
    'int nWindowHeight = height;',
    'if (SDLActivity.isChromebook() && fixedWidth > 0 && fixedHeight > 0)',
    'nWindowWidth = fixedWidth;',
    'nWindowHeight = fixedHeight;',
    'SDLActivity.nativeSetScreenResolution(',
    'nWindowWidth,',
    'nWindowHeight,',
    'nDeviceWidth,',
    'nDeviceHeight,'
)

foreach ($Fragment in $Required) {
    if (-not $Check.Contains($Fragment)) {
        throw "Patch 47 verification failed: $Fragment"
    }
}

# Ensure the old direct physical/window call is gone from surfaceChanged.
$OldDirectCall = 'SDLActivity.nativeSetScreenResolution(width, height, nDeviceWidth, nDeviceHeight, mDisplay.getRefreshRate());'
if ($Check.Contains($OldDirectCall)) {
    throw 'Patch 47 verification failed: old direct nativeSetScreenResolution call still exists.'
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 47 ChromeOS custom resolution: PASS' -ForegroundColor Green
Write-Host 'ChromeOS + custom resolution: launcher logical size preserved'
Write-Host 'Normal Android: unchanged'
Write-Host 'Native OpenMW library: unchanged'
Write-Host 'ChromeOS relative mouse path: unchanged'
Write-Host ''
Write-Host 'Build the APK normally and test 640x360 on ChromeOS.'
