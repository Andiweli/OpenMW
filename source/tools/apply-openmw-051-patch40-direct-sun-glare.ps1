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
            throw "Patch 40 validation failed for $Path. Missing: $Token"
        }
    }
}

function Assert-NotContains([string]$Path, [string[]]$ForbiddenTokens) {
    $Text = Read-Lf $Path
    foreach ($Token in $ForbiddenTokens) {
        if ($Text.Contains($Token)) {
            throw "Patch 40 validation failed for $Path. Forbidden: $Token"
        }
    }
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "Patch 40 refused a modified retained file: $Path expected=$Expected actual=$Actual"
    }
}

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$Patch39Sha = Join-Path $ProjectRoot 'buildscripts\openmw-051-patch39-libopenmw.sha256'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$OmwfxAssetDir = Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx'
$Bloom = Join-Path $OmwfxAssetDir 'gateh_bloom051.omwfx'
$Godrays = Join-Path $OmwfxAssetDir 'godrays_android_051_depthfixed_vivid.omwfx'
$Lensflare = Join-Path $OmwfxAssetDir 'lensflare_android_051_rayocc.omwfx'
$RainLens = Join-Path $OmwfxAssetDir 'rainlens_android_051_v12_dense.omwfx'
$WetWorld = Join-Path $OmwfxAssetDir 'wetworld_android_051_weather.omwfx'

foreach ($Required in @(
    $MarkerFile,
    $JniLib,
    $Patch39Sha,
    $RuntimePatcher,
    $BuildGradle,
    $MainActivity,
    $Bloom,
    $Godrays,
    $Lensflare,
    $RainLens,
    $WetWorld
)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Patch 40 requires the completed Patch-39 project plus the extracted Patch-40 files. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 40 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $Patch39Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 40 requires the verified Patch-39 native library. expected=$ExpectedNativeSha actual=$ActualNativeSha"
}

# The final native patcher and every unaffected OMWFX effect must stay exact.
Assert-Sha256 $RuntimePatcher 'bfe41f81bde350fe586bf24a758281a944a7e3cde502e7ce1319b18588902deb'
Assert-Sha256 $Bloom '61297e5cfa7fee016d7bdaedc7c3147f7e37babe41bb6bf613eef3819a4c4c53'
Assert-Sha256 $Lensflare '785a017542ea1add0fb8caf63de48a31998e8451bdcb1defa045401de6053ca4'
Assert-Sha256 $RainLens '1e17bd665ac1b445372f6a016bf9baa4e4bc65ee5ff80d36c1c36db4050d5446'
Assert-Sha256 $WetWorld '4d1c205e9514e9d489dd325ccee80bb97e2776dc59bffe7e2577a014d5958c57'

Assert-ContainsAll $Godrays @(
    'uniform_float ray_strength {',
    'default = 0.60;',
    'uniform_float sun_glow_strength {',
    'default = 0.65;',
    'uniform_float direct_glare_strength {',
    'default = 0.48;',
    'for (int i = 0; i < 16; i += 1)',
    'light += warmColor * shaftIntensity * 0.78;',
    'light += sunColor * broadGlow * sun_glow_strength * 0.42 * glowVisibility;',
    'light += warmColor * innerGlow * sun_glow_strength * 0.34 * glowVisibility;',
    'light += sunColor * directSun * direct_glare_strength * 0.60 * glowVisibility;',
    'version = "3.4-051-depthfixed-vivid-softglare";'
)
Assert-NotContains $Godrays @(
    'direct_glare_strength * 0.80 * glowVisibility;',
    'version = "3.3-051-depthfixed-vivid";'
)

Assert-ContainsAll $MainActivity @(
    'OMWFX_RECOMMENDED_CHAIN.joinToString(",")',
    'light += sunColor * directSun * direct_glare_strength * 0.60 * glowVisibility;',
    'version = \"3.4-051-depthfixed-vivid-softglare\";'
)
Assert-NotContains $MainActivity @(
    'version = \"3.3-051-depthfixed-vivid\";'
)

$ExpectedChainBlock = @'
        private val OMWFX_RECOMMENDED_CHAIN = listOf(
            "wetworld_android_051_weather",
            "godrays_android_051_depthfixed_vivid",
            "lensflare_android_051_rayocc",
            "gateh_bloom051",
            "rainlens_android_051_v12_dense"
        )
'@
if (-not (Read-Lf $MainActivity).Contains($ExpectedChainBlock)) {
    throw 'Patch 40 refused a changed OMWFX chain or pass order.'
}

Assert-ContainsAll $BuildGradle @(
    'openmw-051-patch39-libopenmw.sha256',
    'light += sunColor * directSun * direct_glare_strength * 0.60 * glowVisibility;',
    'version = "3.4-051-depthfixed-vivid-softglare";',
    'uniform_float uStrength {\n    default = 0.35;',
    'uniform_float sun_glow_strength {\n    default = 0.65;',
    'light += warmColor * shaftIntensity * 0.78;'
)
Assert-NotContains $BuildGradle @(
    'version = "3.3-051-depthfixed-vivid";'
)

Write-Host 'OpenMW 0.51 Patch 40 direct-sun glare calibration: PASS'
Write-Host 'Direct full-screen sun glare: 75 percent of Patch 39'
Write-Host 'General Bloom, Sun Glow, Godrays and Lensflare: unchanged'
Write-Host 'Native rebuild: NO'
Write-Host 'Normal APK build: YES'
