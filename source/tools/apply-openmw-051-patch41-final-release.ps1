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
            throw "Patch 41 validation failed for $Path. Missing: $Token"
        }
    }
}

function Assert-NotContains([string]$Path, [string[]]$ForbiddenTokens) {
    $Text = Read-Lf $Path
    foreach ($Token in $ForbiddenTokens) {
        if ($Text.Contains($Token)) {
            throw "Patch 41 validation failed for $Path. Forbidden: $Token"
        }
    }
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "Patch 41 refused a modified retained file: $Path expected=$Expected actual=$Actual"
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
        throw "Patch 41 requires the completed Patch-40 project plus the extracted Patch-41 files. Missing: $Required"
    }
}

if ((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit") {
    throw 'Patch 41 refused a non-0.51.0-Final runtime payload.'
}

$ExpectedNativeSha = ((Get-Content -LiteralPath $Patch39Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$ActualNativeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant()
if ($ExpectedNativeSha -ne $ActualNativeSha) {
    throw "Patch 41 requires the verified Patch-39 native library. expected=$ExpectedNativeSha actual=$ActualNativeSha"
}

# Freeze the final native patcher and all calibrated effects byte-for-byte.
Assert-Sha256 $RuntimePatcher 'bfe41f81bde350fe586bf24a758281a944a7e3cde502e7ce1319b18588902deb'
Assert-Sha256 $Bloom '61297e5cfa7fee016d7bdaedc7c3147f7e37babe41bb6bf613eef3819a4c4c53'
Assert-Sha256 $Godrays '445f20a155c681bcf4c90bc902b66f8d9239f07c2e417768f8c9ffc19377e84d'
Assert-Sha256 $Lensflare '785a017542ea1add0fb8caf63de48a31998e8451bdcb1defa045401de6053ca4'
Assert-Sha256 $RainLens '1e17bd665ac1b445372f6a016bf9baa4e4bc65ee5ff80d36c1c36db4050d5446'
Assert-Sha256 $WetWorld '4d1c205e9514e9d489dd325ccee80bb97e2776dc59bffe7e2577a014d5958c57'

Assert-ContainsAll $BuildGradle @(
    'OpenMW 0.51.0 Android final release baseline',
    'def openMwVersionCode = 5100',
    'return engineVersion',
    "calculateVersion() != '0.51.0'",
    'versionCode openMwVersionCode',
    'versionName calculateVersion()',
    'applicationId "com.ast.openmw"',
    'abiFilters "arm64-v8a"',
    'targetSdk 29',
    'light += sunColor * directSun * direct_glare_strength * 0.60 * glowVisibility;',
    'version = "3.4-051-depthfixed-vivid-softglare";'
)
Assert-NotContains $BuildGradle @(
    'release-candidate',
    'proof-of-life',
    'return "${engineVersion}-${openMwVersionCode}"'
)

Assert-ContainsAll $MainActivity @(
    'text = "ARM64 \u2022 v${BuildConfig.VERSION_NAME}"',
    'Enabled OMWFX OpenMW 0.51 preset',
    'OMWFX_RECOMMENDED_CHAIN.joinToString(",")',
    'launcher_shader_preset_applied_v35_openmw051_gate_h5a',
    'light += sunColor * directSun * direct_glare_strength * 0.60 * glowVisibility;',
    'version = \"3.4-051-depthfixed-vivid-softglare\";'
)
Assert-NotContains $MainActivity @(
    'Enabled staged OMWFX'
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
    throw 'Patch 41 refused a changed OMWFX chain or pass order.'
}

Write-Host 'OpenMW Android 0.51.0 Patch 41 final release gate: PASS'
Write-Host 'VersionName: 0.51.0'
Write-Host 'VersionCode: 5100'
Write-Host 'Package: com.ast.openmw'
Write-Host 'ABI: arm64-v8a'
Write-Host 'Native rebuild: NO'
Write-Host 'Normal signed release APK build: YES'
