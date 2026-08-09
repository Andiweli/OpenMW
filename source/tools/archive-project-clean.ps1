param(
    [string]$OutputZip
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Parent = Split-Path $ProjectRoot -Parent
$ProjectName = Split-Path $ProjectRoot -Leaf

if ([string]::IsNullOrWhiteSpace($OutputZip)) {
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputZip = Join-Path $Parent ($ProjectName + '-clean-backup-' + $Stamp + '.zip')
}
elseif (-not [IO.Path]::IsPathRooted($OutputZip)) {
    $OutputZip = Join-Path (Get-Location) $OutputZip
}

$StageRoot = Join-Path ([IO.Path]::GetTempPath()) ($ProjectName + '-archive-' + [Guid]::NewGuid().ToString('N'))
$Stage = Join-Path $StageRoot $ProjectName

$ExcludeDirs = @(
    (Join-Path $ProjectRoot '.gradle'),
    (Join-Path $ProjectRoot 'build'),
    (Join-Path $ProjectRoot 'app\build'),
    (Join-Path $ProjectRoot 'app\.cxx'),
    (Join-Path $ProjectRoot 'storagechooser\build'),
    (Join-Path $ProjectRoot 'buildscripts\build'),
    (Join-Path $ProjectRoot 'buildscripts\downloads'),
    (Join-Path $ProjectRoot 'buildscripts\prefix'),
    (Join-Path $ProjectRoot 'buildscripts\toolchain'),
    (Join-Path $ProjectRoot 'buildscripts\symbols')
)

Write-Host 'Creating clean OpenMW project backup...' -ForegroundColor Cyan
Write-Host "Source: $ProjectRoot"
Write-Host "ZIP:    $OutputZip"
Write-Host ''
Write-Host 'Generated native/Gradle caches are intentionally excluded.' -ForegroundColor DarkCyan
Write-Host 'app\src\main\jniLibs and app\src\main\assets are retained.' -ForegroundColor DarkCyan

New-Item -ItemType Directory -Force -Path $Stage | Out-Null

$RoboArgs = @(
    $ProjectRoot,
    $Stage,
    '/E',
    '/COPY:DAT',
    '/DCOPY:DAT',
    '/R:1',
    '/W:1',
    '/NFL',
    '/NDL',
    '/NJH',
    '/NJS',
    '/NP',
    '/XD'
) + $ExcludeDirs + @('/XF', '*.log')

try {
    & robocopy @RoboArgs | Out-Host
    $RoboCode = $LASTEXITCODE
    if ($RoboCode -ge 8) {
        throw "robocopy failed with exit code $RoboCode"
    }

    $OutputDir = Split-Path $OutputZip -Parent
    if ($OutputDir -and -not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }
    if (Test-Path $OutputZip) {
        Remove-Item $OutputZip -Force
    }

    Compress-Archive -Path $Stage -DestinationPath $OutputZip -CompressionLevel Optimal

    $Size = (Get-Item $OutputZip).Length
    Write-Host ''
    Write-Host 'Clean project backup created successfully.' -ForegroundColor Green
    Write-Host ("Size: {0:N1} MB" -f ($Size / 1MB))
    Write-Host $OutputZip
}
finally {
    Remove-Item $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
