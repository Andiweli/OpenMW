param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$ValuesRoot = Join-Path $ProjectRoot 'app\src\main\res'

if (-not (Test-Path -LiteralPath $BuildGradle)) {
    throw "Patch 46 requires the completed OpenMW 0.51 project. Missing: $BuildGradle"
}
if (-not (Test-Path -LiteralPath $ValuesRoot)) {
    throw "Patch 46 requires launcher resources. Missing: $ValuesRoot"
}

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Android release identity: 0.51.0-04 / versionCode 5104
# Keep the bundled OpenMW engine resource itself at upstream 0.51.0.
# ---------------------------------------------------------------------------

$Gradle = Read-Lf $BuildGradle

$CodePattern = '(?m)^def openMwVersionCode = \d+\s*$'
if (-not [regex]::IsMatch($Gradle, $CodePattern)) {
    throw 'Patch 46: openMwVersionCode definition was not found in app/build.gradle.'
}
$Gradle = [regex]::Replace(
    $Gradle,
    $CodePattern,
    'def openMwVersionCode = 5104',
    1
)

$NamePattern = "(?m)^def openMwAndroidVersionName = '[^']*'\s*$"
if ([regex]::IsMatch($Gradle, $NamePattern)) {
    $Gradle = [regex]::Replace(
        $Gradle,
        $NamePattern,
        "def openMwAndroidVersionName = '0.51.0-04'",
        1
    )
}
else {
    $CodeLine = 'def openMwVersionCode = 5104'
    if (-not $Gradle.Contains($CodeLine)) {
        throw 'Patch 46: updated versionCode anchor is missing.'
    }
    $Gradle = $Gradle.Replace(
        $CodeLine,
        $CodeLine + "`n" + "def openMwAndroidVersionName = '0.51.0-04'"
    )
}

# calculateVersion() remains tied to the presence of the real 0.51.0 engine
# payload, but returns the Android release identity for BuildConfig.VERSION_NAME.
$ReleaseReturn = "return engineVersion == '0.51.0' ? openMwAndroidVersionName : engineVersion"

if ($Gradle.Contains('return engineVersion')) {
    $Gradle = $Gradle.Replace('return engineVersion', $ReleaseReturn)
}
elseif (-not $Gradle.Contains($ReleaseReturn)) {
    # Accept an already-suffixed local calculateVersion() and normalize it.
    $OldReturnPattern = "(?m)^\s*return\s+engineVersion\s*==\s*'0\.51\.0'\s*\?.*$"
    if ([regex]::IsMatch($Gradle, $OldReturnPattern)) {
        $Gradle = [regex]::Replace(
            $Gradle,
            $OldReturnPattern,
            '    ' + $ReleaseReturn,
            1
        )
    }
    else {
        throw 'Patch 46: calculateVersion() return anchor was not found.'
    }
}

# Update the release verification gate so assembleRelease accepts 0.51.0-04.
$GatePattern = "if \(openMwVersionCode != \d+ \|\| calculateVersion\(\) != '[^']+'\)"
if (-not [regex]::IsMatch($Gradle, $GatePattern)) {
    throw 'Patch 46: final release identity verification gate was not found.'
}
$Gradle = [regex]::Replace(
    $Gradle,
    $GatePattern,
    "if (openMwVersionCode != 5104 || calculateVersion() != '0.51.0-04')",
    1
)

$GateMessagePattern = "OpenMW Android final release identity must be versionName [^']+ and versionCode \d+\."
if ([regex]::IsMatch($Gradle, $GateMessagePattern)) {
    $Gradle = [regex]::Replace(
        $Gradle,
        $GateMessagePattern,
        'OpenMW Android final release identity must be versionName 0.51.0-04 and versionCode 5104.',
        1
    )
}

Write-Utf8Lf $BuildGradle $Gradle

# ---------------------------------------------------------------------------
# About popup: use straight single apostrophes around Andiweli in every locale.
# MainActivity already displays BuildConfig.VERSION_NAME above about_port_info.
# ---------------------------------------------------------------------------

$StringFiles = Get-ChildItem -LiteralPath $ValuesRoot -Directory |
    Where-Object { $_.Name -eq 'values' -or $_.Name -like 'values-*' } |
    ForEach-Object { Join-Path $_.FullName 'strings.xml' } |
    Where-Object { Test-Path -LiteralPath $_ }

if (-not $StringFiles -or $StringFiles.Count -eq 0) {
    throw 'Patch 46: no launcher strings.xml files were found.'
}

$AboutFiles = @()

foreach ($StringFile in $StringFiles) {
    $Text = Read-Lf $StringFile

    if (-not $Text.Contains('name="about_port_info"')) {
        continue
    }

    $AboutFiles += $StringFile

    # Common XML/text quote forms used by the translations.
    $Text = $Text.Replace('&quot;Andiweli&quot;', "'Andiweli'")
    $Text = $Text.Replace('„Andiweli“', "'Andiweli'")
    $Text = $Text.Replace('„Andiweli”', "'Andiweli'")
    $Text = $Text.Replace('“Andiweli”', "'Andiweli'")
    $Text = $Text.Replace('"Andiweli"', "'Andiweli'")
    $Text = $Text.Replace('«Andiweli»', "'Andiweli'")
    $Text = $Text.Replace('‹Andiweli›', "'Andiweli'")
    $Text = $Text.Replace('‘Andiweli’', "'Andiweli'")
    $Text = $Text.Replace('’Andiweli’', "'Andiweli'")

    # If a translation used another punctuation pair, normalize only the
    # immediate characters around the literal nickname.
    $Text = [regex]::Replace(
        $Text,
        '[“”„"«»‹›‘’]{1,2}Andiweli[“”„"«»‹›‘’]{1,2}',
        "'Andiweli'"
    )

    Write-Utf8Lf $StringFile $Text
}

if ($AboutFiles.Count -eq 0) {
    throw 'Patch 46: about_port_info was not found in any launcher locale.'
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

$GradleCheck = Read-Lf $BuildGradle

$RequiredGradleFragments = @(
    'def openMwVersionCode = 5104',
    "def openMwAndroidVersionName = '0.51.0-04'",
    "return engineVersion == '0.51.0' ? openMwAndroidVersionName : engineVersion",
    "if (openMwVersionCode != 5104 || calculateVersion() != '0.51.0-04')",
    'OpenMW Android final release identity must be versionName 0.51.0-04 and versionCode 5104.'
)

foreach ($Fragment in $RequiredGradleFragments) {
    if (-not $GradleCheck.Contains($Fragment)) {
        throw "Patch 46 verification failed in app/build.gradle: $Fragment"
    }
}

foreach ($StringFile in $AboutFiles) {
    $Text = Read-Lf $StringFile
    $AboutMatch = [regex]::Match(
        $Text,
        '<string\s+name="about_port_info">(?<value>.*?)</string>',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )

    if (-not $AboutMatch.Success) {
        throw "Patch 46 verification failed: about_port_info missing in $StringFile"
    }

    $AboutValue = $AboutMatch.Groups['value'].Value
    if (-not $AboutValue.Contains("'Andiweli'")) {
        throw "Patch 46 verification failed: straight apostrophes missing in $StringFile"
    }

    if ($AboutValue -match '[“”„"«»‹›‘’]Andiweli|Andiweli[“”„"«»‹›‘’]') {
        throw "Patch 46 verification failed: old quote style remains around Andiweli in $StringFile"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 46 final release identity: PASS' -ForegroundColor Green
Write-Host 'Version name: 0.51.0-04'
Write-Host 'Version code: 5104'
Write-Host "About nickname: 'Andiweli'"
Write-Host "Localized about strings updated: $($AboutFiles.Count)"
Write-Host 'Native OpenMW library: unchanged'
Write-Host ''
Write-Host 'Build the release APK normally.'
