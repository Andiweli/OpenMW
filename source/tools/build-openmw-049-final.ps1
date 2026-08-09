param(
    [switch]$NoLto,
    [switch]$SkipPrepare
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $SkipPrepare) {
    # prepare-openmw-049-final.ps1 is another PowerShell script, not an external
    # process. $LASTEXITCODE is therefore the wrong status indicator here and
    # may still be $null or contain the exit code of an older native command.
    # With $ErrorActionPreference='Stop', a failing prepare script already
    # throws and aborts this wrapper automatically.
    & (Join-Path $PSScriptRoot 'prepare-openmw-049-final.ps1')
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required by the existing CaveBros native build scripts. Install/enable WSL with a Linux distribution, or run buildscripts/build.sh from Linux.'
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\\''") + "'"
}

function Convert-WindowsPathToWsl([string]$WindowsPath) {
    # The CaveBros build runs from a normal Windows drive mounted by WSL.
    # Do not call `wslpath E:`: inside Linux, bare `E:` is a relative filename
    # and can resolve below the current working directory. Convert the normal
    # drive-letter form deterministically instead.
    if ($WindowsPath -notmatch '^([A-Za-z]):(?:\\(.*))?$') {
        throw "Unsupported project path for this WSL build wrapper: $WindowsPath. Use a normal Windows drive path such as E:\Development\OpenMW."
    }

    $DriveLetter = $Matches[1].ToLowerInvariant()
    $RelativePart = $Matches[2]
    $DriveRoot = "/mnt/$DriveLetter"

    if ([string]::IsNullOrWhiteSpace($RelativePart)) {
        return $DriveRoot
    }

    $UnixRelative = $RelativePart -replace '\\', '/'
    return ($DriveRoot + '/' + $UnixRelative.TrimStart('/'))
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
Write-Host "WSL project path: $WslProject" -ForegroundColor DarkCyan

$BashProject = Quote-Bash $WslProject
& wsl.exe bash -lc "test -d $BashProject"
if ($LASTEXITCODE -ne 0) {
    throw "The translated project path does not exist inside WSL: $WslProject"
}

$BuildDir = "$WslProject/buildscripts"
$LtoArg = if ($NoLto) { '' } else { '--lto' }
$BashBuildDir = Quote-Bash $BuildDir

# Do NOT pass the native build as a multiline `bash -lc` argument.
# PowerShell -> wsl.exe -> bash command-line quoting is too fragile for nested
# command substitutions, awk programs and quoted error messages.
#
# Instead write a real LF-only shell script into the project and execute that
# file directly through `wsl.exe --exec`. This removes an entire quoting layer.
$WindowsBuildScript = Join-Path $ProjectRoot 'tools\.openmw-049-final-build.sh'
$WslBuildScript = "$WslProject/tools/.openmw-049-final-build.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

cd __BUILD_DIR__

CMAKE_VERSION="$(cmake --version | head -n1 | awk '{print $3}')"
if [ "$(printf '%s\n' 3.16 "$CMAKE_VERSION" | sort -V | head -n1)" != "3.16" ]; then
    echo "ERROR: OpenMW 0.49 Final requires CMake >= 3.16; found $CMAKE_VERSION" >&2
    exit 2
fi

echo "CMake $CMAKE_VERSION OK"

# Force only the OpenMW ExternalProject to refresh. Existing dependency
# prefixes/stamps stay available. Successfully completed dependencies (ICU,
# SDL, etc.) remain cached across retries.
rm -rf build/arm64/openmw-prefix

BUILD_LOG="$PWD/openmw-049-final-native-build.log"
rm -f "$BUILD_LOG"

echo "Native build log: $BUILD_LOG"

# build.sh/CMake may run multiple ExternalProject targets in parallel. The last
# top-level `make: *** Error 2` is therefore usually only a summary. Preserve
# the complete interleaved output and then show likely root-cause lines.
set +e
./build.sh --arch arm64 __LTO_ARG__ 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [ "$BUILD_RC" -ne 0 ]; then
    echo
    echo "============================================================"
    echo "OpenMW native build FAILED (exit $BUILD_RC)"
    echo "Full log: $BUILD_LOG"
    echo "Likely root-cause lines:"
    echo "============================================================"

    grep -n -E -i \
        '(^|[^a-z])(fatal error:|error:|cmake error|undefined reference|cannot find|could not find|no rule to make target|FAILED:|ninja: build stopped|collect2: error|ld: error|make\[[0-9]+\]: \*\*\*)' \
        "$BUILD_LOG" | tail -n 120 || true

    echo
    echo "============================================================"
    echo "Context around the first strong error marker:"
    echo "============================================================"

    FIRST_ERROR_LINE="$(
        grep -n -E -i \
            '(fatal error:|cmake error|undefined reference|cannot find|could not find|no rule to make target|FAILED:|collect2: error|ld: error)' \
            "$BUILD_LOG" | head -n 1 | cut -d: -f1
    )"

    if [ -n "${FIRST_ERROR_LINE:-}" ]; then
        START=$(( FIRST_ERROR_LINE > 25 ? FIRST_ERROR_LINE - 25 : 1 ))
        END=$(( FIRST_ERROR_LINE + 45 ))
        sed -n "${START},${END}p" "$BUILD_LOG"
    else
        echo "No strong error marker was found automatically."
        echo "Last 160 lines of the full build log:"
        tail -n 160 "$BUILD_LOG"
    fi

    exit "$BUILD_RC"
fi
'@

$ShellScript = $ShellScript.Replace('__BUILD_DIR__', $BashBuildDir)
$ShellScript = $ShellScript.Replace('__LTO_ARG__', $LtoArg)

# Ensure bash receives plain UTF-8 without BOM and Unix LF line endings.
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText(
    $WindowsBuildScript,
    $ShellScript,
    [Text.UTF8Encoding]::new($false)
)

Write-Host ''
Write-Host 'Building OpenMW 0.49.0 Final for arm64-v8a through WSL...' -ForegroundColor Cyan
Write-Host "WSL build script: $WslBuildScript" -ForegroundColor DarkCyan

$NativeExitCode = 1
try {
    & wsl.exe --exec bash $WslBuildScript
    $NativeExitCode = $LASTEXITCODE
}
finally {
    Remove-Item $WindowsBuildScript -Force -ErrorAction SilentlyContinue
}

if ($NativeExitCode -ne 0) { exit $NativeExitCode }

$Marker = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
if (-not (Test-Path $Marker)) {
    throw 'Native build completed without the v13 engine marker.'
}
$MarkerText = [IO.File]::ReadAllText($Marker)
if (-not $MarkerText.Contains('675146bd8bce6245d78889f543b5c02a1e3936fe')) {
    throw 'Native build produced an unexpected OpenMW engine marker.'
}

Write-Host ''
Write-Host 'OpenMW 0.49.0 Final native payload built successfully.' -ForegroundColor Green
Write-Host 'Next: gradlew.bat clean ; gradlew.bat :app:assembleMainlineDebug'
