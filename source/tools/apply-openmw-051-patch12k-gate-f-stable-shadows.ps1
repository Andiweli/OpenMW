param(
    [ValidateRange(1, 32)]
    [int]$Jobs = 6
)

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

function Replace-Exact-OrAlready([string]$Path, [string]$Label, [string]$Old, [string]$New) {
    $Text = Read-Lf $Path
    if ($Text.Contains($Old)) {
        $Count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
        if ($Count -ne 1) {
            throw "${Label}: expected exactly one old block in $Path, found $Count"
        }
        Write-Utf8Lf $Path ($Text.Replace($Old, $New))
        Write-Host "Applied $Label."
        return
    }
    if ($Text.Contains($New)) {
        Write-Host "$Label already clean."
        return
    }
    throw "${Label}: neither diagnostic nor clean block found in $Path"
}

function Quote-Bash([string]$Value) {
    return "'" + ($Value -replace "'", "'\''") + "'"
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

$MarkerFile = Join-Path $ProjectRoot 'app\src\main\assets\libopenmw\openmw\openmw-engine-version.txt'
$JniLib = Join-Path $ProjectRoot 'app\src\main\jniLibs\arm64-v8a\libopenmw.so'
$SymbolLib = Join-Path $ProjectRoot 'buildscripts\symbols\arm64-v8a\libopenmw.so'
$SourceRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw'
$BuildRoot = Join-Path $ProjectRoot 'buildscripts\build\arm64\openmw-prefix\src\openmw-build'
$ShadowsBinHpp = Join-Path $SourceRoot 'components\sceneutil\shadowsbin.hpp'
$ShadowsBinCpp = Join-Path $SourceRoot 'components\sceneutil\shadowsbin.cpp'
$MwShadowTechnique = Join-Path $SourceRoot 'components\sceneutil\mwshadowtechnique.cpp'
$ShadowCpp = Join-Path $SourceRoot 'components\sceneutil\shadow.cpp'
$ShadowReceiver = Join-Path $SourceRoot 'files\shaders\compatibility\shadows_fragment.glsl'
$ShadowCaster = Join-Path $SourceRoot 'files\shaders\compatibility\shadowcasting.vert'
$RuntimePatcher = Join-Path $ProjectRoot 'buildscripts\patches\openmw051-final\apply-android-runtime-baseline.py'
$MainActivity = Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'

foreach ($Required in @($MarkerFile, $JniLib, $SourceRoot, $BuildRoot, $ShadowsBinHpp, $ShadowsBinCpp, $MwShadowTechnique, $ShadowCpp, $ShadowReceiver, $ShadowCaster, $RuntimePatcher, $MainActivity)) {
    if (-not (Test-Path $Required)) {
        throw "Patch 12k requires the working Patch-12j OpenMW 0.51 tree. Missing: $Required"
    }
}

$ExpectedMarker = "OpenMW 0.51.0 Final`ncommit=$FinalCommit"
if ((Read-Lf $MarkerFile).Trim() -ne $ExpectedMarker) {
    throw 'Patch 12k refused a non-0.51-Final runtime payload.'
}

# Require the complete known-good Patch-12j functional stack before removing
# diagnostics. This prevents the cleanup patch from being applied to an older
# shadow experiment by accident.
$MwShadowText = Read-Lf $MwShadowTechnique
$ShadowCppText = Read-Lf $ShadowCpp
$ReceiverText = Read-Lf $ShadowReceiver
$CasterText = Read-Lf $ShadowCaster
$PatcherText = Read-Lf $RuntimePatcher

foreach ($Marker in @(
    'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS',
    'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING',
    'OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME',
    'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP',
    'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS'
)) {
    if (-not $MwShadowText.Contains($Marker)) {
        throw "Patch 12k requires Patch-12j functional marker: $Marker"
    }
    if (-not $PatcherText.Contains($Marker)) {
        throw "Patch 12k requires permanent runtime-patcher marker: $Marker"
    }
}
if (-not $ShadowCppText.Contains('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP')) {
    throw 'Patch 12k requires Patch 12c orthographic shadows.'
}
if (-not $CasterText.Contains('OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING')) {
    throw 'Patch 12k requires Patch 12d native GLES2 shadow clipping.'
}
if (-not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE') -or
    -not $ReceiverText.Contains('OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS')) {
    throw 'Patch 12k requires the Patch-12/12b GLES2 receiver baseline.'
}

# ---------------------------------------------------------------------------
# Remove Patch-12f diagnostic instrumentation only.
# No shadow matrix, projection, caster/receiver, quality, distance or fade
# behaviour is changed here.
# ---------------------------------------------------------------------------

$DiagnosticHeader = @'
        void sortImplementation() override;
#ifdef ANDROID
        // OPENMW_ANDROID_051_SHADOW_GL_DIAG
        // Diagnostic-only: isolate GL errors inside the shadow caster RenderBin.
        void drawImplementation(osg::RenderInfo& renderInfo, osgUtil::RenderLeaf*& previous) override;
#endif
'@.TrimEnd([char[]]"`r`n")

$CleanHeader = @'
        void sortImplementation() override;
'@.TrimEnd([char[]]"`r`n")

Replace-Exact-OrAlready $ShadowsBinHpp 'Patch 12k remove ShadowsBin diagnostic declaration' $DiagnosticHeader $CleanHeader

$DiagnosticIncludes = @'
#include <osgUtil/StateGraph>
#include <unordered_set>

#ifdef ANDROID
#include <osg/FrameStamp>
#include <osg/RenderInfo>
#endif
'@.TrimEnd([char[]]"`r`n")

$CleanIncludes = @'
#include <osgUtil/StateGraph>
#include <unordered_set>
'@.TrimEnd([char[]]"`r`n")

Replace-Exact-OrAlready $ShadowsBinCpp 'Patch 12k remove diagnostic-only includes' $DiagnosticIncludes $CleanIncludes

$DiagnosticHelpers = @'
namespace
{
#ifdef ANDROID
    // OPENMW_ANDROID_051_SHADOW_GL_DIAG
    // glGetError is deliberately sampled inside the shadow caster RenderBin.
    // This lets us distinguish an inherited FBO/state error from a GL error
    // generated by one particular RenderLeaf. The diagnostic consumes errors,
    // so OSG's later generic "after RenderBin::draw" warning may disappear.
    const char* shadowGlErrorName(GLenum error)
    {
        switch (error)
        {
            case GL_INVALID_ENUM: return "GL_INVALID_ENUM";
            case GL_INVALID_VALUE: return "GL_INVALID_VALUE";
            case GL_INVALID_OPERATION: return "GL_INVALID_OPERATION";
            case GL_OUT_OF_MEMORY: return "GL_OUT_OF_MEMORY";
            default: return "GL_UNKNOWN_ERROR";
        }
    }

    unsigned int shadowDiagFrame(const osg::RenderInfo& renderInfo)
    {
        const osg::State* state = renderInfo.getState();
        const osg::FrameStamp* fs = state ? state->getFrameStamp() : nullptr;
        return fs ? fs->getFrameNumber() : 0u;
    }

    bool drainShadowGlErrors(const char* phase, osg::RenderInfo& renderInfo,
        const osgUtil::RenderLeaf* leaf = nullptr, std::size_t leafIndex = 0)
    {
        bool found = false;
        for (unsigned int errorIndex = 0; errorIndex < 16; ++errorIndex)
        {
            const GLenum error = glGetError();
            if (error == GL_NO_ERROR)
                break;

            found = true;
            OSG_WARN << "OPENMW_SHADOW_GL_DIAG frame=" << shadowDiagFrame(renderInfo)
                     << " phase=" << phase
                     << " error=" << shadowGlErrorName(error)
                     << "(0x" << std::hex << error << std::dec << ")"
                     << " leafIndex=" << leafIndex;

            if (leaf && leaf->getDrawable())
            {
                const osg::Drawable* drawable = leaf->getDrawable();
                OSG_WARN << " drawableClass=" << drawable->className();
                if (!drawable->getName().empty())
                    OSG_WARN << " drawableName=\"" << drawable->getName() << "\"";
            }
            else
                OSG_WARN << " drawable=<none>";

            OSG_WARN << std::endl;
        }
        return found;
    }
#endif

    template <typename T>
'@.TrimEnd([char[]]"`r`n")

$CleanHelpers = @'
namespace
{
    template <typename T>
'@.TrimEnd([char[]]"`r`n")

Replace-Exact-OrAlready $ShadowsBinCpp 'Patch 12k remove diagnostic GL helpers' $DiagnosticHelpers $CleanHelpers

$DiagnosticConstructor = @'
    ShadowsBin::ShadowsBin(const CastingPrograms& castingPrograms)
    {
#ifdef ANDROID
        static bool sShadowGlDiagAnnounced = false;
        if (!sShadowGlDiagAnnounced)
        {
            OSG_WARN << "OPENMW_SHADOW_GL_DIAG Patch 12f active: probing GL errors inside shadow caster RenderBin" << std::endl;
            sShadowGlDiagAnnounced = true;
        }
#endif
        mNoTestStateSet = new osg::StateSet;
'@.TrimEnd([char[]]"`r`n")

$CleanConstructor = @'
    ShadowsBin::ShadowsBin(const CastingPrograms& castingPrograms)
    {
        mNoTestStateSet = new osg::StateSet;
'@.TrimEnd([char[]]"`r`n")

Replace-Exact-OrAlready $ShadowsBinCpp 'Patch 12k remove diagnostic activation log' $DiagnosticConstructor $CleanConstructor

$DiagnosticDraw = @'
#ifdef ANDROID
    void ShadowsBin::drawImplementation(osg::RenderInfo& renderInfo, osgUtil::RenderLeaf*& previous)
    {
        osg::State& state = *renderInfo.getState();

        // Anything already pending here happened after the shadow RenderStage
        // bound/applied its render target but before this custom caster bin drew.
        drainShadowGlErrors("shadow-bin-entry", renderInfo);

        unsigned int numToPop = (previous ? StateGraph::numToPop(previous->_parent) : 0);
        if (numToPop > 1)
            --numToPop;
        unsigned int insertStateSetPosition = state.getStateSetStackSize() - numToPop;

        if (_stateset.valid())
            state.insertStateSet(insertStateSetPosition, _stateset.get());

        RenderBinList::iterator rbitr;
        std::size_t childIndex = 0;
        for (rbitr = _bins.begin(); rbitr != _bins.end() && rbitr->first < 0; ++rbitr, ++childIndex)
        {
            rbitr->second->draw(renderInfo, previous);
            drainShadowGlErrors("after-negative-child-bin", renderInfo, nullptr, childIndex);
        }

        std::size_t leafIndex = 0;
        for (RenderLeafList::iterator rlitr = _renderLeafList.begin(); rlitr != _renderLeafList.end(); ++rlitr, ++leafIndex)
        {
            RenderLeaf* rl = *rlitr;
            // If this fires, the previous operation generated the error; it is
            // intentionally separated from the following leaf's result.
            drainShadowGlErrors("before-fine-leaf", renderInfo, rl, leafIndex);
            rl->render(renderInfo, previous);
            previous = rl;
            drainShadowGlErrors("after-fine-leaf", renderInfo, rl, leafIndex);
        }

        std::size_t stateGraphIndex = 0;
        for (StateGraphList::iterator oitr = _stateGraphList.begin(); oitr != _stateGraphList.end(); ++oitr, ++stateGraphIndex)
        {
            std::size_t stateLeafIndex = 0;
            for (StateGraph::LeafList::iterator dw_itr = (*oitr)->_leaves.begin(); dw_itr != (*oitr)->_leaves.end(); ++dw_itr, ++stateLeafIndex)
            {
                RenderLeaf* rl = dw_itr->get();
                // Pack stateGraphIndex into the high half so repeated local
                // leaf indices are still distinguishable in Logcat.
                const std::size_t diagnosticIndex = (stateGraphIndex << 16) | stateLeafIndex;
                drainShadowGlErrors("before-stategraph-leaf", renderInfo, rl, diagnosticIndex);
                rl->render(renderInfo, previous);
                previous = rl;
                drainShadowGlErrors("after-stategraph-leaf", renderInfo, rl, diagnosticIndex);
            }
        }

        for (; rbitr != _bins.end(); ++rbitr, ++childIndex)
        {
            rbitr->second->draw(renderInfo, previous);
            drainShadowGlErrors("after-post-child-bin", renderInfo, nullptr, childIndex);
        }

        if (_stateset.valid())
            state.removeStateSet(insertStateSetPosition);

        drainShadowGlErrors("shadow-bin-exit", renderInfo);
    }
#endif

    void ShadowsBin::sortImplementation()
    {
'@.TrimEnd([char[]]"`r`n")

$CleanDraw = @'
    void ShadowsBin::sortImplementation()
    {
'@.TrimEnd([char[]]"`r`n")

Replace-Exact-OrAlready $ShadowsBinCpp 'Patch 12k remove per-RenderLeaf glGetError draw override' $DiagnosticDraw $CleanDraw

# Production runtime naming. These replacements are intentionally tolerant of
# repeated execution.
$Main = Read-Lf $MainActivity
$Main = $Main.Replace(
    'Synced OpenMW 0.51 Patch 12j corrected all-path frustum-crop bypass over Patch 12i; post processing remains disabled',
    'Synced OpenMW 0.51 Gate F stable Android GLES2 shadows; post processing remains disabled'
)
$Main = $Main.Replace(
    'OpenMW 0.51 Patch 12j runtime gate: shadows=launcher-controlled, postProcessing=false, omwfx=false',
    'OpenMW 0.51 Gate F stable runtime: shadows=launcher-controlled, postProcessing=false, omwfx=false'
)
Write-Utf8Lf $MainActivity $Main

# Pre-build verification: diagnostics must be gone, known-good behaviour must
# still be structurally present.
$HppText = Read-Lf $ShadowsBinHpp
$BinCppText = Read-Lf $ShadowsBinCpp
$MwShadowText = Read-Lf $MwShadowTechnique
$MainText = Read-Lf $MainActivity
if ($HppText.Contains('OPENMW_ANDROID_051_SHADOW_GL_DIAG') -or
    $BinCppText.Contains('OPENMW_SHADOW_GL_DIAG') -or
    $BinCppText.Contains('drainShadowGlErrors')) {
    throw 'Patch 12k cleanup verification failed: Patch-12f diagnostic source remains.'
}
foreach ($Marker in @(
    'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS',
    'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING',
    'OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME',
    'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS'
)) {
    if (-not $MwShadowText.Contains($Marker)) {
        throw "Patch 12k functional verification failed: missing $Marker"
    }
}
if (-not $MainText.Contains('OpenMW 0.51 Gate F stable Android GLES2 shadows')) {
    throw 'Patch 12k production Logcat marker update failed.'
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'WSL is required for the existing OpenMW Android native build tree.'
}

$WslProject = Convert-WindowsPathToWsl $ProjectRoot
$WindowsHelper = Join-Path $ProjectRoot 'tools\.openmw-051-patch12k-gate-f-stable-shadows.sh'
$WslHelper = "$WslProject/tools/.openmw-051-patch12k-gate-f-stable-shadows.sh"

$ShellScript = @'
#!/usr/bin/env bash
set -euo pipefail

PROJECT=__PROJECT__
JOBS=__JOBS__
SOURCE="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw"
BUILD="$PROJECT/buildscripts/build/arm64/openmw-prefix/src/openmw-build"
PATCHER="$PROJECT/buildscripts/patches/openmw051-final/apply-android-runtime-baseline.py"
JNI="$PROJECT/app/src/main/jniLibs/arm64-v8a/libopenmw.so"
SYMBOLS="$PROJECT/buildscripts/symbols/arm64-v8a/libopenmw.so"
MARKER="$PROJECT/app/src/main/assets/libopenmw/openmw/openmw-engine-version.txt"
STRIP="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF="$PROJECT/buildscripts/toolchain/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
MWST="$SOURCE/components/sceneutil/mwshadowtechnique.cpp"
SHADOW_CPP="$SOURCE/components/sceneutil/shadow.cpp"
SHADOW_FRAG="$SOURCE/files/shaders/compatibility/shadows_fragment.glsl"
SHADOW_CAST="$SOURCE/files/shaders/compatibility/shadowcasting.vert"
SHADOWS_BIN_HPP="$SOURCE/components/sceneutil/shadowsbin.hpp"
SHADOWS_BIN_CPP="$SOURCE/components/sceneutil/shadowsbin.cpp"

EXPECTED_MARKER=$'OpenMW 0.51.0 Final\ncommit=f4bec41444214a7903bebd178389ca22ca13f646'
if [[ "$(cat "$MARKER")" != "$EXPECTED_MARKER" ]]; then
    echo 'ERROR: OpenMW 0.51 Final marker mismatch.' >&2
    exit 20
fi

# Re-run the permanent Android 0.51 semantic patcher. Patch-12f diagnostics
# were intentionally never part of this patcher; the stable functional shadow
# stack must remain reproducible from a clean 0.51 source checkout.
python3 "$PATCHER" "$SOURCE"

for marker in \
    OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS \
    OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING \
    OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME \
    OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP \
    OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS; do
    if ! grep -Fq "$marker" "$MWST"; then
        echo "ERROR: missing stable shadow marker after permanent patcher: $marker" >&2
        exit 21
    fi
done
if ! grep -Fq 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP' "$SHADOW_CPP"; then
    echo 'ERROR: orthographic Android shadow projection was lost.' >&2
    exit 22
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING' "$SHADOW_CAST"; then
    echo 'ERROR: native GLES2 shadow clipping was lost.' >&2
    exit 23
fi
if ! grep -Fq 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE' "$SHADOW_FRAG" || \
   ! grep -Fq 'OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS' "$SHADOW_FRAG"; then
    echo 'ERROR: GLES2 shadow receiver compatibility was lost.' >&2
    exit 24
fi
if grep -Fq 'OPENMW_ANDROID_051_SHADOW_GL_DIAG' "$SHADOWS_BIN_HPP" || \
   grep -Fq 'OPENMW_SHADOW_GL_DIAG' "$SHADOWS_BIN_CPP" || \
   grep -Fq 'drainShadowGlErrors' "$SHADOWS_BIN_CPP"; then
    echo 'ERROR: Patch-12f diagnostic source is still present after cleanup.' >&2
    exit 25
fi
if [ ! -x "$STRIP" ] || [ ! -x "$READELF" ]; then
    echo 'ERROR: pinned NDK llvm-strip/llvm-readelf is missing.' >&2
    exit 26
fi

echo
echo 'OpenMW 0.51 Gate F stable shadow source: READY'
echo '  Device-tested Patch-12j rendering behaviour retained'
echo '  Exactly 1 shadow map; orthographic Android/GLES2 path retained'
echo '  All-path main-frustum crop bypass retained'
echo '  Patch-12f per-leaf GL diagnostics removed'
echo '  Post Processing / OMWFX remain OFF'
echo
echo "Incrementally rebuilding OpenMW only (parallelism=$JOBS) ..."
cmake --build "$BUILD" --target openmw --parallel "$JOBS"

mapfile -t BUILT_LIBS < <(find "$BUILD" -type f -name 'libopenmw.so' -print)
if [ "${#BUILT_LIBS[@]}" -eq 0 ]; then
    echo "ERROR: rebuilt libopenmw.so not found under $BUILD" >&2
    exit 27
fi
if [ "${#BUILT_LIBS[@]}" -gt 1 ]; then
    printf 'ERROR: multiple rebuilt libopenmw.so candidates found:\n' >&2
    printf '  %s\n' "${BUILT_LIBS[@]}" >&2
    exit 28
fi
BUILT_LIB="${BUILT_LIBS[0]}"

mkdir -p "$(dirname "$SYMBOLS")" "$(dirname "$JNI")"
cp -f "$BUILT_LIB" "$SYMBOLS"
cp -f "$BUILT_LIB" "$JNI"
"$STRIP" --strip-unneeded "$JNI"

if ! grep -aFq 'OpenMW 0.51.0' "$SYMBOLS" || ! grep -aFq 'OpenMW 0.51.0' "$JNI"; then
    echo 'ERROR: rebuilt library does not identify as OpenMW 0.51.0.' >&2
    exit 29
fi
if grep -aFq 'OPENMW_SHADOW_GL_DIAG' "$SYMBOLS" || grep -aFq 'OPENMW_SHADOW_GL_DIAG' "$JNI"; then
    echo 'ERROR: rebuilt library still contains Patch-12f diagnostic marker.' >&2
    exit 30
fi

SYMBOL_SIZE=$(stat -c %s "$SYMBOLS")
JNI_SIZE=$(stat -c %s "$JNI")
if [ "$JNI_SIZE" -ge "$SYMBOL_SIZE" ]; then
    echo "ERROR: packaged library was not stripped (packaged=$JNI_SIZE symbols=$SYMBOL_SIZE)." >&2
    exit 31
fi
if "$READELF" -S "$JNI" 2>/dev/null | grep -Eq '\.debug_(info|line|str|abbrev)'; then
    echo 'ERROR: packaged libopenmw.so still contains DWARF debug sections.' >&2
    exit 32
fi

JNI_SHA=$(sha256sum "$JNI" | awk '{print $1}')
SYMBOL_SHA=$(sha256sum "$SYMBOLS" | awk '{print $1}')
printf '%s  %s\n' "$JNI_SHA" "$JNI" > "$PROJECT/buildscripts/openmw-051-patch12k-libopenmw.sha256"

echo
echo 'OpenMW 0.51 Patch 12k Gate-F stable shadow consolidation: SUCCESS'
printf 'Packaged/stripped lib: %s (%s bytes)\n' "$JNI" "$JNI_SIZE"
printf 'Symbol/unstripped lib: %s (%s bytes)\n' "$SYMBOLS" "$SYMBOL_SIZE"
printf 'Packaged SHA-256: %s\n' "$JNI_SHA"
printf 'Symbol SHA-256:   %s\n' "$SYMBOL_SHA"
echo 'Next: rebuild/reinstall the APK normally and run the final Gate-F regression checklist.'
'@

$ShellScript = $ShellScript.Replace('__PROJECT__', (Quote-Bash $WslProject))
$ShellScript = $ShellScript.Replace('__JOBS__', $Jobs.ToString())
$ShellScript = $ShellScript -replace "`r`n", "`n"
[IO.File]::WriteAllText($WindowsHelper, $ShellScript, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'OpenMW 0.51 Patch 12k - Gate F Stable Shadow Consolidation' -ForegroundColor Cyan
Write-Host 'Preserving the device-tested Patch-12j shadow behaviour.' -ForegroundColor Green
Write-Host 'Removing only the Patch-12f per-leaf GL diagnostic instrumentation.' -ForegroundColor Yellow
Write-Host "Only the existing OpenMW native target is rebuilt (Jobs=$Jobs)." -ForegroundColor Yellow
Write-Host 'Post Processing / OMWFX remain OFF.' -ForegroundColor DarkGray

try {
    & wsl.exe --exec bash $WslHelper
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Remove-Item $WindowsHelper -Force -ErrorAction SilentlyContinue
}

# Windows-side final verification.
$HppText = Read-Lf $ShadowsBinHpp
$BinCppText = Read-Lf $ShadowsBinCpp
$MainText = Read-Lf $MainActivity
if ($HppText.Contains('OPENMW_ANDROID_051_SHADOW_GL_DIAG') -or
    $BinCppText.Contains('OPENMW_SHADOW_GL_DIAG') -or
    $BinCppText.Contains('drainShadowGlErrors')) {
    throw 'Patch 12k final verification failed: diagnostic source remains.'
}
if (-not $MainText.Contains('Synced OpenMW 0.51 Gate F stable Android GLES2 shadows')) {
    throw 'Patch 12k final Logcat marker verification failed.'
}
if (-not (Test-Path $SymbolLib)) {
    throw 'Patch 12k symbol library is missing after rebuild.'
}
$JniSize = (Get-Item $JniLib).Length
$SymbolSize = (Get-Item $SymbolLib).Length
if ($JniSize -ge $SymbolSize) {
    throw "Patch 12k strip verification failed: packaged=$JniSize symbols=$SymbolSize"
}

Write-Host ''
Write-Host 'Patch 12k is ready for APK assembly.' -ForegroundColor Green
Write-Host 'After the final Gate-F regression test, this is the shadow baseline to carry into Gate G.' -ForegroundColor Green
