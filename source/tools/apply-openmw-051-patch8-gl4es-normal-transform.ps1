param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for WSL: $WindowsPath"
    }
    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($RelativePart)) { return "/mnt/$DriveLetter" }
    return "/mnt/$DriveLetter/" + (($RelativePart -replace '\\', '/').TrimStart('/'))
}

$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildResourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build\resources'
$AssetResourceRoot = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\resources'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'

foreach ($Required in @($Marker, $RuntimePatcher, $SourceRoot, $AssetResourceRoot, $MainActivity, $JniLib)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 8 requires the existing successful OpenMW 0.51 Patch-7 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $Marker) -ne $ExpectedMarker) {
    throw 'Patch 8 refused a non-0.51-Final runtime payload.'
}

$PatcherText = Read-Lf $RuntimePatcher
if (-not $PatcherText.Contains('normal_transform_replacements') -or
    -not $PatcherText.Contains('normalToView(normalize(passNormal))')) {
    throw 'Patch 8 package is incomplete: GL4ES normal-transform patcher rules are missing.'
}

$MainText = Read-Lf $MainActivity
if (-not $MainText.Contains('OpenMW 0.51 Patch 8 GL4ES normal-transform + core/fog shaders')) {
    throw 'Patch 8 package is incomplete: MainActivity does not sync/verify the Patch-8 shaders.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android source tree.'
}

$BeforeJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
$BeforeSymbolHash = if (Test-Path $SymbolLib) { (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch8-normal-transform.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch8-normal-transform.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
ASSET_ROOT="$PROJECT/app/src/main/assets/libopenmw/resources"
BUILD_RESOURCE_ROOT="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build/resources"

python3 "$PATCHER" "$SOURCE"

paths=(
  'shaders/compatibility/objects.vert'
  'shaders/compatibility/objects.frag'
  'shaders/compatibility/terrain.vert'
  'shaders/compatibility/terrain.frag'
  'shaders/compatibility/groundcover.vert'
  'shaders/compatibility/bs/default.vert'
  'shaders/compatibility/bs/default.frag'
  'shaders/compatibility/bs/nolighting.vert'
)

for rel in "${paths[@]}"; do
    src="$SOURCE/files/$rel"
    dst="$ASSET_ROOT/$rel"
    if [ ! -f "$src" ]; then
        echo "ERROR: patched source shader missing: $src" >&2
        exit 40
    fi
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    if ! cmp -s "$src" "$dst"; then
        echo "ERROR: APK shader asset mismatch after copy: $rel" >&2
        exit 41
    fi
    if [ -d "$BUILD_RESOURCE_ROOT" ]; then
        bdst="$BUILD_RESOURCE_ROOT/$rel"
        mkdir -p "$(dirname "$bdst")"
        cp -f "$src" "$bdst"
    fi
done

objv="$SOURCE/files/shaders/compatibility/objects.vert"
objf="$SOURCE/files/shaders/compatibility/objects.frag"
terv="$SOURCE/files/shaders/compatibility/terrain.vert"
terf="$SOURCE/files/shaders/compatibility/terrain.frag"
gcv="$SOURCE/files/shaders/compatibility/groundcover.vert"
bdv="$SOURCE/files/shaders/compatibility/bs/default.vert"
bdf="$SOURCE/files/shaders/compatibility/bs/default.frag"
bnv="$SOURCE/files/shaders/compatibility/bs/nolighting.vert"

grep -Fq 'vec3 viewNormal = normalToView(passNormal);' "$objv"
grep -Fq 'vec3 viewNormal = normalToView(normalize(passNormal));' "$objf"
grep -Fq 'vec3 viewNormal = normalToView(passNormal);' "$terv"
grep -Fq 'vec3 viewNormal = normalToView(normalize(passNormal));' "$terf"
grep -Fq 'vec3 viewNormal = normalToView(passNormal);' "$gcv"
grep -Fq 'vec3 viewNormal = normalToView(passNormal);' "$bdv"
grep -Fq 'vec3 viewNormal = normalToView(normalize(passNormal));' "$bdf"
grep -Fq 'vec3 viewNormal = normalize((gl_NormalMatrix * gl_Normal).xyz);' "$bnv"

if grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$objv" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$objf" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$terv" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$terf" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$gcv" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$bdv" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$bdf" ||
   grep -Fq 'vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);' "$bnv"; then
    echo 'ERROR: at least one Patch-8 direct passNormal normal-matrix path remains.' >&2
    exit 42
fi

echo
echo 'OpenMW 0.51 Patch 8 shader payload: READY'
echo 'Ported only the proven OpenMW-0.50 Android/GL4ES normal-transform substitutions.'
echo 'Native libopenmw.so was NOT rebuilt.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 8 - GL4ES normal-transform compatibility' -ForegroundColor Cyan
Write-Host 'Ports only the already proven 0.50 Android normalToView substitutions.' -ForegroundColor Cyan
Write-Host 'No native rebuild; libopenmw.so must remain byte-identical.' -ForegroundColor Yellow

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

$AfterJniHash = (Get-FileHash $JniLib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($AfterJniHash -ne $BeforeJniHash) {
    throw "Patch 8 unexpectedly modified packaged libopenmw.so: before=$BeforeJniHash after=$AfterJniHash"
}
if ($BeforeSymbolHash -ne $null) {
    $AfterSymbolHash = (Get-FileHash $SymbolLib -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($AfterSymbolHash -ne $BeforeSymbolHash) {
        throw "Patch 8 unexpectedly modified symbol libopenmw.so: before=$BeforeSymbolHash after=$AfterSymbolHash"
    }
}

$Affected = @(
    'shaders\compatibility\objects.vert',
    'shaders\compatibility\objects.frag',
    'shaders\compatibility\terrain.vert',
    'shaders\compatibility\terrain.frag',
    'shaders\compatibility\groundcover.vert',
    'shaders\compatibility\bs\default.vert',
    'shaders\compatibility\bs\default.frag',
    'shaders\compatibility\bs\nolighting.vert'
)
foreach ($Rel in $Affected) {
    $Asset = Join-Path $AssetResourceRoot $Rel
    if (-not (Test-Path $Asset)) { throw "Patch 8 shader asset missing: $Asset" }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 8: SUCCESS' -ForegroundColor Green
Write-Host "libopenmw.so unchanged SHA-256: $AfterJniHash"
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio. Do NOT run a native OpenMW rebuild for this test.'
