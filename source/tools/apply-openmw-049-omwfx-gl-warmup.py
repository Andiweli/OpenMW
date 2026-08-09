#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-openmw-049-omwfx-gl-warmup.py <openmw-source-dir>')

root = Path(sys.argv[1])
cpp_path = root / 'apps/openmw/mwrender/postprocessor.cpp'
hpp_path = root / 'apps/openmw/mwrender/postprocessor.hpp'

for p in (cpp_path, hpp_path):
    if not p.is_file():
        raise SystemExit(f'missing source file: {p}')

cpp = cpp_path.read_text(encoding='utf-8').replace('\r\n', '\n')
hpp = hpp_path.read_text(encoding='utf-8').replace('\r\n', '\n')

DONE_CPP = 'Android post-processing startup: GL warm-up complete, rebuilding chain at '
DONE_HPP = 'mAndroidPostProcessingWarmupDrawComplete'
if DONE_CPP in cpp and DONE_HPP in hpp:
    print('0009 Android post-processing GL-draw warm-up is already applied (semantic marker).')
    raise SystemExit(0)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"0009 semantic migration failed at '{label}': expected 1 match, found {count}.")
    return text.replace(old, new, 1)

# Draw-completion callback. This anchor is unchanged in OpenMW 0.49 Final and
# lies outside the v13.16/v13.17 modifications.
callback_anchor = """        MWRender::PostProcessor* mPostProcessor;
    };

    class HUDCullCallback"""
callback_replacement = """        MWRender::PostProcessor* mPostProcessor;
    };

#ifdef ANDROID
    class AndroidPostProcessingStartupDrawCallback : public osg::Camera::DrawCallback
    {
    public:
        explicit AndroidPostProcessingStartupDrawCallback(MWRender::PostProcessor* postProcessor)
            : mPostProcessor(postProcessor)
        {
        }

        void operator()(osg::RenderInfo&) const override
        {
            mPostProcessor->signalAndroidPostProcessingWarmupDraw();
        }

    private:
        MWRender::PostProcessor* mPostProcessor;
    };
#endif

    class HUDCullCallback"""
if 'class AndroidPostProcessingStartupDrawCallback' not in cpp:
    cpp = replace_once(cpp, callback_anchor, callback_replacement, 'draw callback insertion')

# Replace the Android startup conditional containing the unique v13.17 marker.
# We delimit by preprocessor bounds instead of comments so harmless local
# comment/context changes do not make an existing build tree unpatchable.
new_start = """#ifdef ANDROID
        // A valid cull viewport is not enough on Android/GL4ES: the graphics
        // context can already have its final size while the first post-process
        // GL objects are still being realized. A normal in-game OFF -> ON cycle
        // works because at least one real draw completes with post-processing
        // disabled before the chain is rebuilt. Reproduce that lifecycle
        // deterministically without changing the persisted setting.
        if (mUsePostProcessing)
        {
            mReload = false;
            mUsePostProcessing = false;
            mAndroidPostProcessingStartupPending.store(true, std::memory_order_release);
            mAndroidPostProcessingWarmupDrawComplete.store(false, std::memory_order_release);
            mHUDCamera->setFinalDrawCallback(new AndroidPostProcessingStartupDrawCallback(this));
            Log(Debug::Info) << "Android post-processing startup: waiting for one completed GL draw";
        }
#else
        if (mUsePostProcessing)
            enable();
#endif"""
if 'mAndroidPostProcessingStartupPending.store(true' not in cpp:
    marker_pos = cpp.find('mDeferredAndroidPostProcessingEnable = true;')
    if marker_pos < 0:
        raise SystemExit("0009 semantic migration failed at 'v13.17 startup block': marker not found.")
    block_start = cpp.rfind('#ifdef ANDROID', 0, marker_pos)
    block_end = cpp.find('#endif', marker_pos)
    if block_start < 0 or block_end < 0:
        raise SystemExit("0009 semantic migration failed at 'v13.17 startup block': preprocessor bounds not found.")
    block_end += len('#endif')
    old_block = cpp[block_start:block_end]
    if 'if (mUsePostProcessing)' not in old_block or '#else' not in old_block:
        raise SystemExit("0009 semantic migration failed at 'v13.17 startup block': unexpected conditional shape.")
    cpp = cpp[:block_start] + new_start + cpp[block_end:]

# Convert the v13.17 disable-cancellation marker without replacing the rest
# of disable(), so unrelated local edits to that function are preserved.
if 'mAndroidPostProcessingStartupPending.store(false' not in cpp:
    marker_pos = cpp.find('mDeferredAndroidPostProcessingEnable = false;')
    if marker_pos < 0:
        raise SystemExit("0009 semantic migration failed at 'disable cancellation': marker not found.")
    block_start = cpp.rfind('#ifdef ANDROID', 0, marker_pos)
    block_end = cpp.find('#endif', marker_pos)
    if block_start < 0 or block_end < 0:
        raise SystemExit("0009 semantic migration failed at 'disable cancellation': preprocessor bounds not found.")
    block_end += len('#endif')
    new_cancel = """#ifdef ANDROID
        mAndroidPostProcessingStartupPending.store(false, std::memory_order_release);
        mAndroidPostProcessingWarmupDrawComplete.store(false, std::memory_order_release);
#endif"""
    cpp = cpp[:block_start] + new_cancel + cpp[block_end:]

# Add the draw-thread signal method immediately before traverse().
if 'void PostProcessor::signalAndroidPostProcessingWarmupDraw()' not in cpp:
    traverse_anchor = '    void PostProcessor::traverse(osg::NodeVisitor& nv)\n'
    signal_method = """#ifdef ANDROID
    void PostProcessor::signalAndroidPostProcessingWarmupDraw()
    {
        if (mAndroidPostProcessingStartupPending.load(std::memory_order_acquire))
            mAndroidPostProcessingWarmupDrawComplete.store(true, std::memory_order_release);
    }
#endif

"""
    cpp = replace_once(cpp, traverse_anchor, signal_method + traverse_anchor, 'warm-up signal method insertion')

# Remove the cull-time v13.17 enable. After startup/disable conversion the only
# remaining deferred marker in the cpp must belong to the old cull gate.
if 'mDeferredAndroidPostProcessingEnable' in cpp:
    marker_pos = cpp.find('mDeferredAndroidPostProcessingEnable')
    block_start = cpp.rfind('#ifdef ANDROID', 0, marker_pos)
    block_end = cpp.find('#endif', marker_pos)
    if block_start < 0 or block_end < 0:
        raise SystemExit("0009 semantic migration failed at 'remove v13.17 cull gate': preprocessor bounds not found.")
    block_end += len('#endif')
    old_block = cpp[block_start:block_end]
    if 'cv->getViewport()' not in old_block or 'enable();' not in old_block:
        raise SystemExit("0009 semantic migration failed at 'remove v13.17 cull gate': unexpected block shape.")
    cpp = cpp[:block_start] + cpp[block_end:]

# Gate the initial reload on an actually completed draw, and do the rebuild on
# UPDATE traversal where OpenMW normally handles reloadIfRequired().
warmup_update = """#ifdef ANDROID
        if (mAndroidPostProcessingStartupPending.load(std::memory_order_acquire)
            && mAndroidPostProcessingWarmupDrawComplete.exchange(false, std::memory_order_acq_rel))
        {
            // The final-draw callback proves that OSG/GL4ES has completed an
            // actual render pass on the live context. Use the camera viewport
            // now, not the early GraphicsContext traits from construction.
            if (const osg::Viewport* viewport = mViewer->getCamera()->getViewport())
            {
                const int width = static_cast<int>(viewport->width());
                const int height = static_cast<int>(viewport->height());
                if (width > 0 && height > 0)
                    setRenderTargetSize(width, height);
            }

            mAndroidPostProcessingStartupPending.store(false, std::memory_order_release);

            // From here on use the exact same OpenMW path as a successful
            // manual re-enable: enable() -> reloadIfRequired() -> loadChain()
            // -> resize(), but only after the first completed GL draw.
            enable();
            Log(Debug::Info) << "Android post-processing startup: GL warm-up complete, rebuilding chain at "
                             << mWidth << "x" << mHeight;
        }
#endif
"""
if DONE_CPP not in cpp:
    update_anchor = """        updateLiveReload();

        reloadIfRequired();"""
    update_replacement = """        updateLiveReload();

""" + warmup_update + """
        reloadIfRequired();"""
    cpp = replace_once(cpp, update_anchor, update_replacement, 'update traversal warm-up gate')

# Header changes.
if '#include <atomic>' not in hpp:
    hpp = replace_once(hpp, '#include <array>\n', '#include <array>\n#include <atomic>\n', 'atomic include')

method_decl = """#ifdef ANDROID
        void signalAndroidPostProcessingWarmupDraw();
#endif

"""
if 'void signalAndroidPostProcessingWarmupDraw();' not in hpp:
    hpp = replace_once(
        hpp,
        """        void loadChain();
        void saveChain();

    private:""",
        """        void loadChain();
        void saveChain();

""" + method_decl + """    private:""",
        'warm-up signal declaration')

new_member = """#ifdef ANDROID
        std::atomic_bool mAndroidPostProcessingStartupPending{ false };
        std::atomic_bool mAndroidPostProcessingWarmupDrawComplete{ false };
#endif"""
if DONE_HPP not in hpp:
    marker_pos = hpp.find('mDeferredAndroidPostProcessingEnable = false;')
    if marker_pos < 0:
        raise SystemExit("0009 semantic migration failed at 'warm-up state members': marker not found.")
    block_start = hpp.rfind('#ifdef ANDROID', 0, marker_pos)
    block_end = hpp.find('#endif', marker_pos)
    if block_start < 0 or block_end < 0:
        raise SystemExit("0009 semantic migration failed at 'warm-up state members': preprocessor bounds not found.")
    block_end += len('#endif')
    hpp = hpp[:block_start] + new_member + hpp[block_end:]

# Final consistency checks happen before either source file is written.
required_cpp = [
    'class AndroidPostProcessingStartupDrawCallback',
    'mAndroidPostProcessingStartupPending.store(true',
    'void PostProcessor::signalAndroidPostProcessingWarmupDraw()',
    DONE_CPP,
]
required_hpp = ['#include <atomic>', 'void signalAndroidPostProcessingWarmupDraw();', DONE_HPP]
for marker in required_cpp:
    if marker not in cpp:
        raise SystemExit(f'0009 semantic migration consistency check failed (cpp): {marker}')
for marker in required_hpp:
    if marker not in hpp:
        raise SystemExit(f'0009 semantic migration consistency check failed (hpp): {marker}')
if 'mDeferredAndroidPostProcessingEnable' in cpp or 'mDeferredAndroidPostProcessingEnable' in hpp:
    raise SystemExit('0009 semantic migration consistency check failed: v13.17 deferred-cull state remains.')

cpp_path.write_text(cpp, encoding='utf-8', newline='\n')
hpp_path.write_text(hpp, encoding='utf-8', newline='\n')
print('Applied 0009 Android post-processing GL-draw warm-up via semantic v13.17 migration.')
