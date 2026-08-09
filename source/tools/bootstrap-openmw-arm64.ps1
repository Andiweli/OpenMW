param(
    [switch]$NoLto
)

# Phase 2 v13: the old CaveBros 0.3.5 APK bootstrap is intentionally retired.
# Re-extracting it would silently restore the 2024 development libopenmw.so.
$Builder = Join-Path $PSScriptRoot 'build-openmw-049-final.ps1'
& $Builder -NoLto:$NoLto
exit $LASTEXITCODE
