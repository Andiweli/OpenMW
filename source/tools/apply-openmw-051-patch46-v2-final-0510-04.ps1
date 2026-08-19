param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$BuildGradle = Join-Path $ProjectRoot 'app\build.gradle'
$ValuesRoot = Join-Path $ProjectRoot 'app\src\main\res'

if (-not (Test-Path -LiteralPath $BuildGradle)) {
    throw "Patch 46 v2 requires the completed OpenMW 0.51 project. Missing: $BuildGradle"
}
if (-not (Test-Path -LiteralPath $ValuesRoot)) {
    throw "Patch 46 v2 requires launcher resources. Missing: $ValuesRoot"
}

function Read-Lf([string]$Path) {
    return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------------------
# Android release identity: 0.51.0-04 / versionCode 5104.
# This section is intentionally idempotent and repairs a partially applied v1.
# ---------------------------------------------------------------------------

$Gradle = Read-Lf $BuildGradle

$CodePattern = '(?m)^def openMwVersionCode = \d+\s*$'
if (-not [regex]::IsMatch($Gradle, $CodePattern)) {
    throw 'Patch 46 v2: openMwVersionCode definition was not found in app/build.gradle.'
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
    $Gradle = $Gradle.Replace(
        $CodeLine,
        $CodeLine + "`n" + "def openMwAndroidVersionName = '0.51.0-04'"
    )
}

$WantedReturn = "return engineVersion == '0.51.0' ? openMwAndroidVersionName : engineVersion"

# Normalize the single return statement in calculateVersion().
$CalcPattern = "(?ms)(def calculateVersion = \{.*?)(^\s*return\s+.+?$)(.*?^\})"
$CalcMatch = [regex]::Match($Gradle, $CalcPattern)
if (-not $CalcMatch.Success) {
    throw 'Patch 46 v2: calculateVersion() block/return statement was not found.'
}
$Gradle = $Gradle.Substring(0, $CalcMatch.Index) +
    $CalcMatch.Groups[1].Value +
    '    ' + $WantedReturn +
    $CalcMatch.Groups[3].Value +
    $Gradle.Substring($CalcMatch.Index + $CalcMatch.Length)

$GatePattern = "if \(openMwVersionCode != \d+ \|\| calculateVersion\(\) != '[^']+'\)"
if (-not [regex]::IsMatch($Gradle, $GatePattern)) {
    throw 'Patch 46 v2: final release identity verification gate was not found.'
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
# About popup.
#
# Android resource strings render \' as a normal straight apostrophe.
# Store the nickname as \'Andiweli\' in XML so the UI shows exactly:
#     'Andiweli'
# ---------------------------------------------------------------------------

$StringFiles = Get-ChildItem -LiteralPath $ValuesRoot -Directory |
    Where-Object { $_.Name -eq 'values' -or $_.Name -like 'values-*' } |
    ForEach-Object { Join-Path $_.FullName 'strings.xml' } |
    Where-Object { Test-Path -LiteralPath $_ }

$AboutFiles = @()

foreach ($StringFile in $StringFiles) {
    $Text = Read-Lf $StringFile
    if (-not $Text.Contains('name="about_port_info"')) {
        continue
    }

    $AboutFiles += $StringFile

    $Match = [regex]::Match(
        $Text,
        '<string\s+name="about_port_info">(?<value>.*?)</string>',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $Match.Success) {
        throw "Patch 46 v2: malformed about_port_info in $StringFile"
    }

    $Value = $Match.Groups['value'].Value

    # Normalize every known raw/escaped/entity/typographic quote form around
    # the literal nickname to Android's escaped straight apostrophes.
    $Normalized = $Value

    $Forms = @(
        '&quot;Andiweli&quot;',
        '&apos;Andiweli&apos;',
        '„Andiweli“',
        '„Andiweli”',
        '“Andiweli”',
        '"Andiweli"',
        '«Andiweli»',
        '‹Andiweli›',
        '‘Andiweli’',
        '’Andiweli’',
        "'Andiweli'",
        "\'Andiweli\'"
    )

    foreach ($Form in $Forms) {
        $Normalized = $Normalized.Replace($Form, "\'Andiweli\'")
    }

    # Last-resort normalization if the nickname is present but surrounded by
    # any of the usual quote glyphs.
    $Normalized = [regex]::Replace(
        $Normalized,
        '(?:\\?[''"]|[“”„«»‹›‘’]|&quot;|&apos;)+Andiweli(?:\\?[''"]|[“”„«»‹›‘’]|&quot;|&apos;)+',
        "\'Andiweli\'"
    )

    if (-not $Normalized.Contains("\'Andiweli\'")) {
        throw "Patch 46 v2: could not normalize Andiweli quote style in $StringFile"
    }

    $NewElement = '<string name="about_port_info">' + $Normalized + '</string>'
    $Text = $Text.Substring(0, $Match.Index) +
        $NewElement +
        $Text.Substring($Match.Index + $Match.Length)

    Write-Utf8Lf $StringFile $Text
}

if ($AboutFiles.Count -eq 0) {
    throw 'Patch 46 v2: about_port_info was not found in any launcher locale.'
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
        throw "Patch 46 v2 verification failed in app/build.gradle: $Fragment"
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
        throw "Patch 46 v2 verification failed: about_port_info missing in $StringFile"
    }

    $RawValue = $AboutMatch.Groups['value'].Value

    # Raw XML must use Android-safe escaped apostrophes.
    if (-not $RawValue.Contains("\'Andiweli\'")) {
        throw "Patch 46 v2 verification failed: escaped straight apostrophes missing in $StringFile"
    }

    # Simulate the displayed Android string for this specific escape.
    $DisplayedValue = $RawValue.Replace("\'", "'")
    if (-not $DisplayedValue.Contains("'Andiweli'")) {
        throw "Patch 46 v2 verification failed: rendered nickname would not be 'Andiweli' in $StringFile"
    }

    if ($DisplayedValue -match '[“”„"«»‹›‘’]Andiweli|Andiweli[“”„"«»‹›‘’]') {
        throw "Patch 46 v2 verification failed: typographic/old quote style remains in $StringFile"
    }
}

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 46 v2 final release identity: PASS' -ForegroundColor Green
Write-Host 'Version name: 0.51.0-04'
Write-Host 'Version code: 5104'
Write-Host "About nickname shown as: 'Andiweli'"
Write-Host "Localized about strings normalized: $($AboutFiles.Count)"
Write-Host 'Native OpenMW library: unchanged'
Write-Host ''
Write-Host 'Build the release APK normally.'
