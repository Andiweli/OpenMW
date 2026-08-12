param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FinalCommit = 'f4bec41444214a7903bebd178389ca22ca13f646'

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Fix-FragmentHeader([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    $Text = Read-Lf $Path
    if (-not $Text.Contains('OPENMW_ANDROID_051_GL4ES_CORE_INLINE')) {
        throw "Patch 4 refused unexpected core fragment header: $Path"
    }

    $Bad = 'OpenMW 0.51 @link path creates helper-only shader objects'
    $Good = 'OpenMW 0.51 helper-link path creates helper-only shader objects'
    if ($Text.Contains($Bad)) {
        $Text = $Text.Replace($Bad, $Good)
        Write-Utf8Lf $Path $Text
    }

    $Verify = Read-Lf $Path
    if ($Verify.Contains('@link')) {
        throw "Patch 4 verification failed: literal @link token remains in inlined fragment header: $Path"
    }
    return $true
}

function Remove-SpecifyMe([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $Text = Read-Lf $Path
    $Lines = @($Text -split "`n" | Where-Object { $_.Trim() -ne 'data="specify-me!"' })
    $NewText = (($Lines -join "`n").TrimEnd() + "`n")
    if ($NewText -ne $Text) {
        Write-Utf8Lf $Path $NewText
    }
}

$AssetRoot = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw'
$Marker = Join-Path $AssetRoot 'openmw\openmw-engine-version.txt'
if (-not (Test-Path $Marker)) {
    throw "Patch 4 requires the successful Patch-2/3 OpenMW 0.51 runtime payload. Missing: $Marker"
}
$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit`n"
if ((Read-Lf $Marker) -ne $ExpectedMarker) {
    throw "Patch 4 refused a non-0.51 payload: $Marker"
}

$RelativeFragment = 'shaders\lib\core\fragment.h.glsl'
$Targets = @(
    (Join-Path $AssetRoot ('resources\' + $RelativeFragment)),
    (Join-Path $ProjectRoot ('buildscripts\build\arm64\openmw-prefix\src\openmw\files\' + $RelativeFragment)),
    (Join-Path $ProjectRoot ('buildscripts\build\arm64\openmw-prefix\src\openmw-build\resources\' + $RelativeFragment))
)

$Fixed = 0
foreach ($Target in $Targets) {
    if (Fix-FragmentHeader $Target) { $Fixed++ }
}
if ($Fixed -lt 1) {
    throw 'Patch 4 did not find any OpenMW 0.51 fragment header to verify.'
}

# Remove the obsolete CaveBros data placeholder from both future and current
# packaged config templates. MainActivity Patch 4 also filters a stale private
# copy, so an unchanged VERSION_CODE cannot keep this warning alive.
Remove-SpecifyMe (Join-Path $ProjectRoot 'app\openmw.base.cfg')
Remove-SpecifyMe (Join-Path $AssetRoot 'openmw\openmw.base.cfg')

# Guard the patch sources themselves against reintroducing the parser-triggering
# token if Patch 3 or a future native rebuild is run again.
foreach ($Rel in @(
    'buildscripts\patches\openmw051-final\apply-android-gl4es-core-inline.py',
    'tools\apply-openmw-051-patch3-runtime-fix.ps1'
)) {
    $Path = Join-Path $ProjectRoot $Rel
    if (Test-Path $Path) {
        $Text = Read-Lf $Path
        $Text = $Text.Replace(
            'OpenMW 0.51 @link path creates helper-only shader objects',
            'OpenMW 0.51 helper-link path creates helper-only shader objects'
        )
        Write-Utf8Lf $Path $Text
    }
}

$AssetFragment = Join-Path $AssetRoot ('resources\' + $RelativeFragment)
if ((Read-Lf $AssetFragment).Contains('@link')) {
    throw 'Patch 4 verification failed: APK fragment header still contains a literal @link token.'
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 4 shader-parser hotfix: SUCCESS' -ForegroundColor Green
Write-Host 'Native libopenmw.so was NOT rebuilt and was NOT modified.' -ForegroundColor Green
Write-Host 'Fixed: accidental @link parser token in fragment.h.glsl comment.'
Write-Host 'Also removed the obsolete data="specify-me!" CaveBros placeholder.'
Write-Host 'Next: rebuild/reinstall the APK normally in Android Studio.' -ForegroundColor Cyan
