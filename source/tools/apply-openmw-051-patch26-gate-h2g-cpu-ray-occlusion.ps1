param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'
function Read-Lf([string]$Path) { return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n") }
function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') { throw "Unsupported project path for WSL: $WindowsPath" }
    $DriveLetter=$Matches[1].ToLowerInvariant(); $RelativePart=$Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\','/').TrimStart('/'))
}
$MarkerFile=Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib=Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SourceRoot=Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot=Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$RuntimePatcher=Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity=Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$BuildGradle=Join-Path $ProjectRoot 'app\build.gradle'
$Lens=Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\lensflare_android_051_rayocc.omwfx'
$Bloom=Join-Path $ProjectRoot 'app\src\main\assets\android_omwfx\gateh_bloom051.omwfx'
$Patch26Sha=Join-Path $ProjectRoot 'buildscripts\openmw-051-patch26-libopenmw.sha256'
foreach($Required in @($MarkerFile,$JniLib,$SourceRoot,$BuildRoot,$RuntimePatcher,$MainActivity,$BuildGradle,$Lens,$Bloom)){if(-not(Test-Path -LiteralPath $Required)){throw "Patch 26 requires the existing Patch-25 build tree. Missing: $Required"}}
if((Read-Lf $MarkerFile).Trim() -ne "OpenMW 0.51.0 Final`ncommit=$FinalCommit"){throw 'Patch 26 refused a non-0.51.0-Final runtime payload.'}
$PatcherText=Read-Lf $RuntimePatcher; $MainText=Read-Lf $MainActivity; $GradleText=Read-Lf $BuildGradle; $LensText=Read-Lf $Lens
foreach($Need in @('OPENMW_ANDROID_051_CPU_SUN_OCCLUSION','const RayResult hit = castRay(origin, dest, true, false);','OpenMW 0.51 Android sun-occlusion ray:')){if(-not $PatcherText.Contains($Need)){throw "Patch26 native patcher missing: $Need"}}
foreach($Need in @('OpenMW 0.51 Patch 26 Gate H2g runtime','"lensflare_android_051_rayocc,gateh_bloom051"','transparentPostpass=launcher')){if(-not $MainText.Contains($Need)){throw "Patch26 MainActivity missing: $Need"}}
if(-not $GradleText.Contains('openmw-051-patch26-libopenmw.sha256')){throw 'Patch26 Gradle SHA gate missing'}
foreach($Need in @('omw.sunOcclusion','vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);','version = "2.1-051-rayocc";')){if(-not $LensText.Contains($Need)){throw "Patch26 lens missing: $Need"}}
foreach($Bad in @('omw_GetLinearDepth(','omw_GetDepth(','sunOcclusion(','sunOcclusion051(','Disable_SunGlare')){if($LensText.Contains($Bad)){throw "Patch26 forbidden PP-depth token: $Bad"}}
if(-not(Get-Command wsl.exe -ErrorAction SilentlyContinue)){throw 'WSL is required for the existing OpenMW Android native build tree.'}
$WslProject=Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper=Join-Path $ProjectRoot 'tools\.openmw-051-patch26-cpu-ray.sh'; $WslHelper="$WslProject/tools/.openmw-051-patch26-cpu-ray.sh"
$ShellScript=@'
#!/usr/bin/env bash
set -euo pipefail
PROJECT="${OPENMW_PATCH26_PROJECT:?OPENMW_PATCH26_PROJECT is required}"
JOBS="${OPENMW_PATCH26_JOBS:?OPENMW_PATCH26_JOBS is required}"
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
RMCPP="$SOURCE/apps/openmw/mwrender/renderingmanager.cpp"; RMHPP="$SOURCE/apps/openmw/mwrender/renderingmanager.hpp"; FXHPP="$SOURCE/components/fx/stateupdater.hpp"
MWST="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"; SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"; SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"; SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"
EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
[[ "$(cat "$MARKER")" == "$EXPECTED_MARKER" ]] || { echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2; exit 60; }
[[ -x "$STRIP" && -x "$READELF" ]] || { echo 'ERROR: pinned NDK tools missing.' >&2; exit 61; }
python3 "$PATCHER" "$SOURCE"
for f in "$RMCPP" "$RMHPP" "$FXHPP"; do grep -Fq 'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION' "$f" || { echo "ERROR: CPU-ray marker missing: $f" >&2; exit 62; }; done
grep -Fq 'const RayResult hit = castRay(origin, dest, true, false);' "$RMCPP" || exit 63
grep -Fq 'OpenMW 0.51 Android sun-occlusion ray:' "$RMCPP" || exit 64
grep -Fq 'sName = "sunOcclusion"' "$FXHPP" || exit 65
python3 - "$RMCPP" <<'PY26CHECK'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
cam=s.index('mCamera->update(dt, paused);'); occ=s.index('updateAndroidSunOcclusion(dt);',cam); under=s.index('bool isUnderwater =',cam)
if not cam < occ < under: raise SystemExit('CPU sun occlusion ordering invalid')
PY26CHECK
for marker in OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS; do grep -Fq "$marker" "$MWST" || { echo "ERROR: stable shadow marker lost: $marker" >&2; exit 66; }; done
grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP" || exit 67
grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || exit 68
grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST" || exit 69
echo 'Patch 26 source validation: PASS'
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"
mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print); [[ ${#BUILT_LIBS[@]} -eq 1 ]] || { echo "ERROR: expected one libopenmw.so, found ${#BUILT_LIBS[@]}" >&2; exit 70; }
BUILT_LIB="${BUILT_LIBS[0]}"; mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"; cp -f "$BUILT_LIB" "$SYMBOLS"; cp -f "$BUILT_LIB" "$JNI"; "$STRIP" --strip-unneeded "$JNI"
for lib in "$SYMBOLS" "$JNI"; do grep -aFq 'OpenMW 0.51.0' "$lib" || exit 71; grep -aFq 'OpenMW 0.51 Android Gate G PP init:' "$lib" || exit 72; grep -aFq 'OpenMW 0.51 Android sun-occlusion ray:' "$lib" || exit 73; done
[[ $(stat -c %s "$JNI") -lt $(stat -c %s "$SYMBOLS") ]] || { echo 'ERROR: JNI lib not stripped.' >&2; exit 74; }
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then echo 'ERROR: JNI lib contains DWARF.' >&2; exit 75; fi
JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}'); printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch26-libopenmw.sha256"; printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch13-libopenmw.sha256"
echo "Patch 26 native rebuild SUCCESS — SHA256 $JNI_SHA"
'@
[IO.File]::WriteAllText($WindowsHelper,($ShellScript -replace "`r`n","`n"),(New-Object Text.UTF8Encoding($false)))
try{& wsl.exe env "OPENMW_PATCH26_PROJECT=$WslProject" "OPENMW_PATCH26_JOBS=$Jobs" bash $WslHelper;if($LASTEXITCODE -ne 0){throw "WSL Patch26 rebuild failed with exit code $LASTEXITCODE"}}finally{Remove-Item -LiteralPath $WindowsHelper -Force -ErrorAction SilentlyContinue}
foreach($Old in @('lensflare_android_051_h2f.omwfx','lensflare_android_051_occ.omwfx','lensflare_android_051_depthocc.omwfx','lensflare_android_051.omwfx')){$OldPath=Join-Path $ProjectRoot ('app\src\main\assets\android_omwfx\'+$Old);if(Test-Path -LiteralPath $OldPath){Remove-Item -LiteralPath $OldPath -Force}}
$ExpectedSha=((Get-Content -LiteralPath $Patch26Sha -Raw).Trim() -split '\s+')[0].ToLowerInvariant();$ActualSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $JniLib).Hash.ToLowerInvariant();if($ExpectedSha -ne $ActualSha){throw "Patch26 SHA mismatch expected=$ExpectedSha actual=$ActualSha"}
Write-Host 'OpenMW 0.51 Patch 26 Gate H2g validation: PASS';Write-Host 'Native rebuild: YES — openmw target only';Write-Host 'Runtime chain: lensflare_android_051_rayocc,gateh_bloom051';Write-Host 'Expected device ray logs: CLEAR / BLOCKED'
