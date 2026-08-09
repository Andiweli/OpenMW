#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-openmw-049-postprocessing-stabilize.py <openmw-source-dir>')

root = Path(sys.argv[1])
cpp_path = root / 'apps/openmw/mwrender/postprocessor.cpp'
hpp_path = root / 'apps/openmw/mwrender/postprocessor.hpp'
for p in (cpp_path, hpp_path):
    if not p.is_file():
        raise SystemExit(f'missing source file: {p}')

cpp = cpp_path.read_text(encoding='utf-8').replace('\r\n', '\n')
hpp = hpp_path.read_text(encoding='utf-8').replace('\r\n', '\n')

DONE = 'Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at '
if DONE in cpp and 'mAndroidPostProcessingCompletedDraws' in hpp:
    print('0010 Android post-processing late stabilization is already applied (semantic marker).')
    raise SystemExit(0)

# 0010 intentionally layers on top of 0009. The rebuild script applies/migrates
# 0009 first, so these markers also protect against modifying an unknown tree.
required_0009_cpp = [
    'class AndroidPostProcessingStartupDrawCallback',
    'mAndroidPostProcessingStartupPending',
    'void PostProcessor::signalAndroidPostProcessingWarmupDraw()',
]
required_0009_hpp = ['mAndroidPostProcessingWarmupDrawComplete']
for marker in required_0009_cpp:
    if marker not in cpp:
        raise SystemExit(f'0010 migration requires 0009 first; missing cpp marker: {marker}')
for marker in required_0009_hpp:
    if marker not in hpp:
        raise SystemExit(f'0010 migration requires 0009 first; missing hpp marker: {marker}')


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"0010 semantic migration failed at '{label}': expected 1 match, found {count}.")
    return text.replace(old, new, 1)

# Separate main-camera completion callback. 0009 uses the HUD camera, so these
# two lifecycle barriers do not overwrite one another.
if 'class AndroidPostProcessingStabilizeDrawCallback' not in cpp:
    anchor = '''#endif

    class HUDCullCallback'''
    insert = '''#endif

#ifdef ANDROID
    class AndroidPostProcessingStabilizeDrawCallback : public osg::Camera::DrawCallback
    {
    public:
        explicit AndroidPostProcessingStabilizeDrawCallback(MWRender::PostProcessor* postProcessor)
            : mPostProcessor(postProcessor)
        {
        }

        void operator()(osg::RenderInfo&) const override
        {
            mPostProcessor->signalAndroidPostProcessingStabilizeDraw();
        }

    private:
        MWRender::PostProcessor* mPostProcessor;
    };
#endif

    class HUDCullCallback'''
    # Anchor must be the #endif immediately after the 0009 callback, not any
    # arbitrary conditional. Use the nearby class marker as an extra guard.
    marker = 'class AndroidPostProcessingStartupDrawCallback'
    pos = cpp.find(marker)
    if pos < 0:
        raise SystemExit('0010 callback insertion: 0009 callback not found')
    anchor_pos = cpp.find(anchor, pos)
    if anchor_pos < 0:
        raise SystemExit('0010 callback insertion: guarded HUD anchor not found')
    cpp = cpp[:anchor_pos] + cpp[anchor_pos:].replace(anchor, insert, 1)

# Arm the late stabilizer while mUsePostProcessing still reflects the persisted
# setting. This is immediately before 0009 can temporarily set it false.
arm_marker = 'Android post-processing startup stabilization v13.23 armed'
if arm_marker not in cpp:
    anchor = '''        setCullCallback(mStateUpdater);

#ifdef ANDROID
        // A valid cull viewport is not enough on Android/GL4ES:'''
    replacement = '''        setCullCallback(mStateUpdater);

#ifdef ANDROID
        if (mUsePostProcessing)
        {
            mAndroidPostProcessingStabilizePending.store(true, std::memory_order_release);
            mAndroidPostProcessingCompletedDraws.store(0, std::memory_order_release);
            mViewer->getCamera()->setFinalDrawCallback(new AndroidPostProcessingStabilizeDrawCallback(this));
            Log(Debug::Info) << "Android post-processing startup stabilization v13.23 armed";
        }
#endif

#ifdef ANDROID
        // A valid cull viewport is not enough on Android/GL4ES:'''
    cpp = replace_once(cpp, anchor, replacement, 'constructor arming')

# Explicit user disable cancels any pending automatic late rebuild.
if 'mAndroidPostProcessingStabilizePending.store(false' not in cpp:
    anchor = '''    void PostProcessor::disable()
    {
#ifdef ANDROID
        mAndroidPostProcessingStartupPending.store(false, std::memory_order_release);'''
    replacement = '''    void PostProcessor::disable()
    {
#ifdef ANDROID
        mAndroidPostProcessingStabilizePending.store(false, std::memory_order_release);
        mAndroidPostProcessingCompletedDraws.store(0, std::memory_order_release);
        mAndroidPostProcessingStartupPending.store(false, std::memory_order_release);'''
    cpp = replace_once(cpp, anchor, replacement, 'disable cancellation')

# Render-thread signal method.
if 'void PostProcessor::signalAndroidPostProcessingStabilizeDraw()' not in cpp:
    anchor = '''#endif

    void PostProcessor::traverse(osg::NodeVisitor& nv)'''
    pos = cpp.find('void PostProcessor::signalAndroidPostProcessingWarmupDraw()')
    if pos < 0:
        raise SystemExit('0010 signal insertion: warm-up signal not found')
    anchor_pos = cpp.find(anchor, pos)
    if anchor_pos < 0:
        raise SystemExit('0010 signal insertion: traverse anchor not found')
    insert = '''#endif

#ifdef ANDROID
    void PostProcessor::signalAndroidPostProcessingStabilizeDraw()
    {
        if (mAndroidPostProcessingStabilizePending.load(std::memory_order_acquire))
            mAndroidPostProcessingCompletedDraws.fetch_add(1, std::memory_order_acq_rel);
    }
#endif

    void PostProcessor::traverse(osg::NodeVisitor& nv)'''
    cpp = cpp[:anchor_pos] + cpp[anchor_pos:].replace(anchor, insert, 1)

# Schedule one final normal OpenMW reload after four actually completed main
# camera draws. In a 0009 build, the first may be the disabled warm-up draw,
# leaving three live PP draws before this runs; without that distinction the
# extra draw is harmless and still deterministic.
if DONE not in cpp:
    anchor = '''        updateLiveReload();

#ifdef ANDROID
        if (mAndroidPostProcessingStartupPending.load(std::memory_order_acquire)'''
    block = '''        updateLiveReload();

#ifdef ANDROID
        if (mUsePostProcessing && mAndroidPostProcessingStabilizePending.load(std::memory_order_acquire)
            && mAndroidPostProcessingCompletedDraws.load(std::memory_order_acquire) >= 4)
        {
            mAndroidPostProcessingStabilizePending.store(false, std::memory_order_release);
            mAndroidPostProcessingCompletedDraws.store(0, std::memory_order_release);

            if (const osg::Viewport* viewport = mViewer->getCamera()->getViewport())
            {
                const int width = static_cast<int>(viewport->width());
                const int height = static_cast<int>(viewport->height());
                if (width > 0 && height > 0)
                    setRenderTargetSize(width, height);
            }

            mReload = true;
            Log(Debug::Info) << "Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at "
                             << mWidth << "x" << mHeight;
        }
#endif

#ifdef ANDROID
        if (mAndroidPostProcessingStartupPending.load(std::memory_order_acquire)'''
    cpp = replace_once(cpp, anchor, block, 'late reload scheduling')

# Public callback signal declaration.
if 'void signalAndroidPostProcessingStabilizeDraw();' not in hpp:
    anchor = '''#ifdef ANDROID
        void signalAndroidPostProcessingWarmupDraw();
#endif

    private:'''
    replacement = '''#ifdef ANDROID
        void signalAndroidPostProcessingWarmupDraw();
#endif

#ifdef ANDROID
        void signalAndroidPostProcessingStabilizeDraw();
#endif

    private:'''
    hpp = replace_once(hpp, anchor, replacement, 'signal declaration')

# Atomic state shared with the main-camera render callback.
if 'mAndroidPostProcessingCompletedDraws' not in hpp:
    anchor = '''#ifdef ANDROID
        std::atomic_bool mAndroidPostProcessingStartupPending{ false };
        std::atomic_bool mAndroidPostProcessingWarmupDrawComplete{ false };
#endif

        bool mUBO = false;'''
    replacement = '''#ifdef ANDROID
        std::atomic_bool mAndroidPostProcessingStartupPending{ false };
        std::atomic_bool mAndroidPostProcessingWarmupDrawComplete{ false };
#endif
#ifdef ANDROID
        std::atomic_bool mAndroidPostProcessingStabilizePending{ false };
        std::atomic_uint mAndroidPostProcessingCompletedDraws{ 0 };
#endif

        bool mUBO = false;'''
    hpp = replace_once(hpp, anchor, replacement, 'stabilizer members')

required_cpp = [
    'class AndroidPostProcessingStabilizeDrawCallback',
    arm_marker,
    'void PostProcessor::signalAndroidPostProcessingStabilizeDraw()',
    DONE,
]
required_hpp = ['void signalAndroidPostProcessingStabilizeDraw();', 'mAndroidPostProcessingCompletedDraws']
for marker in required_cpp:
    if marker not in cpp:
        raise SystemExit(f'0010 migration consistency check failed (cpp): {marker}')
for marker in required_hpp:
    if marker not in hpp:
        raise SystemExit(f'0010 migration consistency check failed (hpp): {marker}')

cpp_path.write_text(cpp, encoding='utf-8', newline='\n')
hpp_path.write_text(hpp, encoding='utf-8', newline='\n')
print('Applied 0010 Android post-processing late stabilization via guarded semantic migration.')
