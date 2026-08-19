param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$ValuesRoot = Join-Path $ProjectRoot 'app\src\main\res'

if (-not (Test-Path -LiteralPath $BuildGradle)) {
    throw "Patch 46 v3 requires the completed OpenMW 0.51 project. Missing: $BuildGradle"
}
if (-not (Test-Path -LiteralPath $ValuesRoot)) {
    throw "Patch 46 v3 requires launcher resources. Missing: $ValuesRoot"
}

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Release identity: normalize idempotently to 0.51.0-04 / 5104.
# ---------------------------------------------------------------------------

$Gradle = Read-Lf $BuildGradle

$CodePattern = '(?m)^def openMwVersionCode = \d+\s*$'
if (-not [regex]::IsMatch($Gradle, $CodePattern)) {
    throw 'Patch 46 v3: openMwVersionCode definition not found.'
}
$Gradle = [regex]::Replace($Gradle, $CodePattern, 'def openMwVersionCode = 5104', 1)

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
    $Anchor = 'def openMwVersionCode = 5104'
    if (-not $Gradle.Contains($Anchor)) {
        throw 'Patch 46 v3: versionCode anchor missing after normalization.'
    }
    $Gradle = $Gradle.Replace(
        $Anchor,
        $Anchor + "`n" + "def openMwAndroidVersionName = '0.51.0-04'"
    )
}

# Normalize calculateVersion return without depending on what v1/v2 left behind.
$CalcPattern = "(?ms)(def calculateVersion = \{.*?)(^\s*return\s+.+?$)(.*?^\})"
$CalcMatch = [regex]::Match($Gradle, $CalcPattern)
if (-not $CalcMatch.Success) {
    throw 'Patch 46 v3: calculateVersion block not found.'
}

$WantedReturn = "    return engineVersion == '0.51.0' ? openMwAndroidVersionName : engineVersion"
$Gradle = $Gradle.Substring(0, $CalcMatch.Index) +
    $CalcMatch.Groups[1].Value +
    $WantedReturn +
    $CalcMatch.Groups[3].Value +
    $Gradle.Substring($CalcMatch.Index + $CalcMatch.Length)

$GatePattern = "if \(openMwVersionCode != \d+ \|\| calculateVersion\(\) != '[^']+'\)"
if (-not [regex]::IsMatch($Gradle, $GatePattern)) {
    throw 'Patch 46 v3: release identity verification gate not found.'
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
# About popup nickname.
#
# Robust strategy:
# Find only the about_port_info value.
# Inside that value replace the complete non-whitespace token containing
# "Andiweli" with Android-safe escaped straight apostrophes:
#     \'Andiweli\'
#
# This works regardless of whether prior attempts left:
#   „Andiweli“
#   "Andiweli"
#   'Andiweli'
#   \'Andiweli\'
#   &quot;Andiweli&quot;
#   &apos;Andiweli&apos;
#   or another quote/punctuation combination without spaces.
# ---------------------------------------------------------------------------

$StringFiles = Get-ChildItem -LiteralPath $ValuesRoot -Directory |
    Where-Object { $_.Name -eq 'values' -or $_.Name -like 'values-*' } |
    ForEach-Object { Join-Path $_.FullName 'strings.xml' } |
    Where-Object { Test-Path -LiteralPath $_ }

$AboutFiles = @()

foreach ($StringFile in $StringFiles) {
    $Text = Read-Lf $StringFile

    $Match = [regex]::Match(
        $Text,
        '<string\s+name="about_port_info">(?<value>.*?)</string>',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )

    if (-not $Match.Success) {
        continue
    }

    $AboutFiles += $StringFile
    $Value = $Match.Groups['value'].Value

    if (-not $Value.Contains('Andiweli')) {
        throw "Patch 46 v3: about_port_info contains no Andiweli token in $StringFile"
    }

    # Replace exactly one non-whitespace token that contains Andiweli.
    # Example:
    #   Andreas „Andiweli“ Stürmer
    # becomes:
    #   Andreas \'Andiweli\' Stürmer
    $TokenPattern = '\S*Andiweli\S*'
    $Matches = [regex]::Matches($Value, $TokenPattern)

    if ($Matches.Count -ne 1) {
        throw "Patch 46 v3: expected exactly one Andiweli token in $StringFile, found $($Matches.Count)"
    }

    $NormalizedValue = [regex]::Replace(
        $Value,
        $TokenPattern,
        { param($m) "\'Andiweli\'" },
        1
    )

    $NewElement = '<string name="about_port_info">' + $NormalizedValue + '</string>'
    $Text = $Text.Substring(0, $Match.Index) +
        $NewElement +
        $Text.Substring($Match.Index + $Match.Length)

    Write-Utf8Lf $StringFile $Text
}

if ($AboutFiles.Count -eq 0) {
    throw 'Patch 46 v3: about_port_info not found in any launcher locale.'
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
        throw "Patch 46 v3 verification failed in app/build.gradle: $Fragment"
    }
}

foreach ($StringFile in $AboutFiles) {
    $Text = Read-Lf $StringFile

    $Match = [regex]::Match(
        $Text,
        '<string\s+name="about_port_info">(?<value>.*?)</string>',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )

    if (-not $Match.Success) {
        throw "Patch 46 v3 verification failed: about_port_info missing in $StringFile"
    }

    $RawValue = $Match.Groups['value'].Value

    # Verify exactly the raw Android-resource representation we wrote.
    $ExpectedRawToken = "\'Andiweli\'"
    if (-not $RawValue.Contains($ExpectedRawToken)) {
        throw "Patch 46 v3 verification failed: expected raw token $ExpectedRawToken in $StringFile"
    }

    # Ensure Andiweli occurs once and no stale neighboring quote token remains.
    if ([regex]::Matches($RawValue, 'Andiweli').Count -ne 1) {
        throw "Patch 46 v3 verification failed: Andiweli occurrence count is not 1 in $StringFile"
    }

    $Rendered = $RawValue.Replace("\'", "'")
    if (-not $Rendered.Contains("'Andiweli'")) {
        throw "Patch 46 v3 verification failed: popup would not render 'Andiweli' in $StringFile"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 46 v3 final release identity: PASS' -ForegroundColor Green
Write-Host 'Version name: 0.51.0-04'
Write-Host 'Version code: 5104'
Write-Host "About nickname shown as: 'Andiweli'"
Write-Host "Localized about strings normalized: $($AboutFiles.Count)"
Write-Host 'Native OpenMW library: unchanged'
Write-Host ''
Write-Host 'Build the release APK normally.'
