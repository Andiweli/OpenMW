param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)
$ErrorActionPreference = "Stop"
function RF([string]$r) { $p=Join-Path $ProjectRoot $r; if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing Patch25 file: $r"}; return $p }
$main=RF "app/src/main/java/ui/activity/MainActivity.kt"
$gradle=RF "app/build.gradle"
$lens=RF "app/src/main/assets/android_omwfx/lensflare_android_051_h2f.omwfx"
$bloom=RF "app/src/main/assets/android_omwfx/gateh_bloom051.omwfx"
$lib=RF "app/src/main/jniLibs/arm64-v8a/libopenmw.so"
$libsha=RF "buildscripts/openmw-051-patch13-libopenmw.sha256"
$mt=Get-Content -LiteralPath $main -Raw
$gt=Get-Content -LiteralPath $gradle -Raw
foreach($n in @('OpenMW 0.51 Patch 25 Gate H2f runtime','"lensflare_android_051_h2f,gateh_bloom051"','transparentPostpass=launcher')){if(-not $mt.Contains($n)){throw "Patch25 MainActivity missing: $n"}}
foreach($n in @('"lensflare_android_051_occ.omwfx"','"lensflare_android_051_depthocc.omwfx"')){if(-not $mt.Contains($n)){throw "Patch25 cleanup missing: $n"}}
if(-not $gt.Contains('Patch 25') -or -not $gt.Contains('lensflare_android_051_h2f.omwfx')){throw 'Patch25 Gradle guard missing'}
$actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $lens).Hash.ToLowerInvariant()
$expected='d2daecbcf7248862323b221a24f94aaecb991367c92ffc7e16f4a2d9ce56b2df'
if($actual -ne $expected){throw "Patch25 lensflare is not exact Patch22 bytes. expected=$expected actual=$actual"}
$lt=Get-Content -LiteralPath $lens -Raw
foreach($bad in @('sunOcclusion(','sunOcclusion051(','omw_GetLinearDepth(','omw_GetDepth(','Disable_SunGlare')){if($lt.Contains($bad)){throw "Forbidden Patch23/24 token in H2f lensflare: $bad"}}
foreach($need in @('vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);','float visibility = omw.sunVis * edgeFade051(sunUv);','version = "2.0-051";')){if(-not $lt.Contains($need)){throw "Missing Patch22 token: $need"}}
$es=((Get-Content -LiteralPath $libsha -Raw).Trim() -split '\s+')[0].ToLowerInvariant(); $as=(Get-FileHash -Algorithm SHA256 -LiteralPath $lib).Hash.ToLowerInvariant(); if($es -ne $as){throw "libopenmw.so SHA mismatch expected=$es actual=$as"}
Write-Host 'OpenMW 0.51 Patch 25 Gate H2f validation: PASS'
Write-Host 'Native rebuild: NO'
Write-Host 'Lensflare: exact Patch22 bytes under fresh technique name'
Write-Host "Lensflare SHA256: $actual"
Write-Host 'Depth occlusion: DISABLED'
Write-Host 'Transparent postpass: LAUNCHER CONTROLLED'
Write-Host 'Runtime chain: lensflare_android_051_h2f,gateh_bloom051'
