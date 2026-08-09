#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at "
DEPTH_MARKER = "Android GLES post-processing depth fallback: sampling Tex_Depth directly"
WATER_MASK_MARKER = "Android WetWorld water alpha mask"

def die(msg: str) -> None:
    raise SystemExit("ERROR: " + msg)

def read(path: Path) -> str:
    if not path.is_file():
        die(f"required OpenMW 0.50 source file is missing: {path}")
    return path.read_text(encoding="utf-8")

def write(path: Path, text: str) -> None:
    path.write_text(text.replace("\r\n", "\n"), encoding="utf-8", newline="\n")

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        die(f"{label}: expected exactly one source anchor, found {count}")
    return text.replace(old, new, 1)

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        die(f"{label}: verification token missing: {token}")

def patch_header(path: Path) -> None:
    text = read(path)
    if "mAndroidPostProcessingCompletedDraws" in text and "signalAndroidPostProcessingStabilizeDraw" in text:
        require(text, "#include <atomic>", "postprocessor.hpp")
        require(text, "mAndroidPostProcessingStartupPending", "postprocessor.hpp")
        return

    text = replace_once(
        text,
        "#include <array>\n#include <string>",
        "#include <array>\n#include <atomic>\n#include <string>",
        "postprocessor.hpp atomic include",
    )

    text = replace_once(
        text,
        "        void loadChain();\n        void saveChain();\n\n    private:",
        """        void loadChain();
        void saveChain();

#ifdef ANDROID
        void signalAndroidPostProcessingWarmupDraw();
        void signalAndroidPostProcessingStabilizeDraw();
#endif

    private:""",
        "postprocessor.hpp Android signal methods",
    )

    text = replace_once(
        text,
        """        bool mTriggerShaderReload = false;
        bool mUsePostProcessing = false;

        bool mUBO = false;""",
        """        bool mTriggerShaderReload = false;
        bool mUsePostProcessing = false;

#ifdef ANDROID
        std::atomic_bool mAndroidPostProcessingStartupPending{ false };
        std::atomic_bool mAndroidPostProcessingWarmupDrawComplete{ false };
        std::atomic_bool mAndroidPostProcessingStabilizePending{ false };
        std::atomic_uint mAndroidPostProcessingCompletedDraws{ 0 };
#endif

        bool mUBO = false;""",
        "postprocessor.hpp Android startup state",
    )

    require(text, "mAndroidPostProcessingCompletedDraws", "postprocessor.hpp")
    write(path, text)

def patch_cpp(path: Path) -> None:
    text = read(path)
    if MARKER in text:
        for token in (
            "class AndroidPostProcessingStartupDrawCallback",
            "class AndroidPostProcessingStabilizeDrawCallback",
            "signalAndroidPostProcessingWarmupDraw",
            "signalAndroidPostProcessingStabilizeDraw",
            "Android post-processing startup: waiting for one completed GL draw",
        ):
            require(text, token, "postprocessor.cpp")
        return

    callbacks = """#ifdef ANDROID
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

"""
    text = replace_once(
        text,
        "    class HUDCullCallback : public SceneUtil::NodeCallback<HUDCullCallback, osg::Camera*, osgUtil::CullVisitor*>",
        callbacks + "    class HUDCullCallback : public SceneUtil::NodeCallback<HUDCullCallback, osg::Camera*, osgUtil::CullVisitor*>",
        "postprocessor.cpp Android draw callbacks",
    )

    text = replace_once(
        text,
        """        osg::GraphicsContext* gc = viewer->getCamera()->getGraphicsContext();
        osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();

        mWidth = gc->getTraits()->width;
        mHeight = gc->getTraits()->height;

        if (!ext->glDisablei && ext->glDisableIndexedEXT)""",
        "        if (!ext->glDisablei && ext->glDisableIndexedEXT)",
        "postprocessor.cpp move initial render-target size",
    )

    text = replace_once(
        text,
        """        , mDistortionCallback(new DistortionCallback)
    {
        auto& shaderManager""",
        """        , mDistortionCallback(new DistortionCallback)
    {
        // Android/GL4ES needs the real GraphicsContext dimensions before the
        // HUD/post-processing cameras and ping-pong FBOs are constructed.
        osg::GraphicsContext* gc = viewer->getCamera()->getGraphicsContext();
        osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();
        mWidth = gc->getTraits()->width;
        mHeight = gc->getTraits()->height;

        auto& shaderManager""",
        "postprocessor.cpp early render-target size",
    )

    startup = """#ifdef ANDROID
        if (mUsePostProcessing)
        {
            mAndroidPostProcessingStabilizePending.store(true, std::memory_order_release);
            mAndroidPostProcessingCompletedDraws.store(0, std::memory_order_release);
            mViewer->getCamera()->setFinalDrawCallback(new AndroidPostProcessingStabilizeDrawCallback(this));
            Log(Debug::Info) << "Android post-processing startup stabilization v14.0/OpenMW-0.50 armed";
        }

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
    text = replace_once(
        text,
        """        if (mUsePostProcessing)
            enable();""",
        startup,
        "postprocessor.cpp deferred Android startup",
    )

    text = replace_once(
        text,
        """    void PostProcessor::disable()
    {
        mUsePostProcessing = false;
        mRendering.getSkyManager()->setSunglare(true);
    }

    void PostProcessor::traverse""",
        """    void PostProcessor::disable()
    {
#ifdef ANDROID
        mAndroidPostProcessingStabilizePending.store(false, std::memory_order_release);
        mAndroidPostProcessingCompletedDraws.store(0, std::memory_order_release);
        mAndroidPostProcessingStartupPending.store(false, std::memory_order_release);
        mAndroidPostProcessingWarmupDrawComplete.store(false, std::memory_order_release);
#endif
        mUsePostProcessing = false;
        mRendering.getSkyManager()->setSunglare(true);
    }

#ifdef ANDROID
    void PostProcessor::signalAndroidPostProcessingWarmupDraw()
    {
        if (mAndroidPostProcessingStartupPending.load(std::memory_order_acquire))
            mAndroidPostProcessingWarmupDrawComplete.store(true, std::memory_order_release);
    }

    void PostProcessor::signalAndroidPostProcessingStabilizeDraw()
    {
        if (mAndroidPostProcessingStabilizePending.load(std::memory_order_acquire))
            mAndroidPostProcessingCompletedDraws.fetch_add(1, std::memory_order_acq_rel);
    }
#endif

    void PostProcessor::traverse""",
        "postprocessor.cpp disable/signal methods",
    )

    update_block = """        updateLiveReload();

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
            Log(Debug::Info)
                << "Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at "
                << mWidth << "x" << mHeight;
        }

        if (mAndroidPostProcessingStartupPending.load(std::memory_order_acquire)
            && mAndroidPostProcessingWarmupDrawComplete.exchange(false, std::memory_order_acq_rel))
        {
            if (const osg::Viewport* viewport = mViewer->getCamera()->getViewport())
            {
                const int width = static_cast<int>(viewport->width());
                const int height = static_cast<int>(viewport->height());
                if (width > 0 && height > 0)
                    setRenderTargetSize(width, height);
            }

            mAndroidPostProcessingStartupPending.store(false, std::memory_order_release);
            enable();
            Log(Debug::Info) << "Android post-processing startup: GL warm-up complete, rebuilding chain at "
                             << mWidth << "x" << mHeight;
        }
#endif

        reloadIfRequired();"""
    text = replace_once(
        text,
        """        updateLiveReload();

        reloadIfRequired();""",
        update_block,
        "postprocessor.cpp startup update path",
    )

    for token in (
        MARKER,
        "class AndroidPostProcessingStartupDrawCallback",
        "class AndroidPostProcessingStabilizeDrawCallback",
        "mWidth = gc->getTraits()->width;",
        "Android post-processing startup stabilization v14.0/OpenMW-0.50 armed",
    ):
        require(text, token, "postprocessor.cpp")

    write(path, text)


def patch_android_depth(path: Path) -> None:
    text = read(path)

    # OpenMW 0.50 normally exposes Tex_OpaqueDepth to post-processing.
    # On Android GLES/GL4ES the separate opaque-depth copy is unreliable.
    # The primary scene depth texture is sampleable and has been verified
    # on-device, so bind it directly for Android only.
    android_depth_block = """#ifdef ANDROID
        // Android GLES/GL4ES: use the primary sampleable scene depth texture.
        mCanvases[frameId]->setTextureDepth(getTexture(Tex_Depth, frameId));
#else
        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));
#endif"""

    direct_binding = "mCanvases[frameId]->setTextureDepth(getTexture(Tex_Depth, frameId));"

    if direct_binding not in text:
        text = replace_once(
            text,
            "        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));",
            android_depth_block,
            "postprocessor.cpp Android GLES depth binding",
        )

    if DEPTH_MARKER not in text:
        anchor = """#ifdef ANDROID
        ext->glDisablei = nullptr;
#endif
"""
        replacement = anchor + """
#ifdef ANDROID
        Log(Debug::Info) << "Android GLES post-processing depth fallback: sampling Tex_Depth directly";
#endif
"""
        text = replace_once(
            text,
            anchor,
            replacement,
            "postprocessor.cpp Android depth runtime marker",
        )

    require(text, direct_binding, "postprocessor.cpp")
    require(text, DEPTH_MARKER, "postprocessor.cpp")
    write(path, text)

def patch_water_alpha_mask(path: Path) -> None:
    text = read(path)

    # WetWorld runs after water has already been composed into the scene colour.
    # On Android the water surface does not provide a reliable per-pixel depth
    # identity, so mark visible water in the scene alpha channel instead.
    if WATER_MASK_MARKER in text:
        require(text, "#include <osg/BlendFunc>", "water.cpp")
        require(text, "osg::BlendFunc::ZERO, osg::BlendFunc::ZERO", "water.cpp")
        return

    text = replace_once(
        text,
        "#include <osg/ClipNode>\n#include <osg/Depth>",
        "#include <osg/BlendFunc>\n#include <osg/ClipNode>\n#include <osg/Depth>",
        "water.cpp BlendFunc include",
    )

    simple_anchor = """        osg::ref_ptr<osg::StateSet> stateset = SceneUtil::createSimpleWaterStateSet(alpha, MWRender::RenderBin_Water);

        node->setStateSet(stateset);"""
    simple_replacement = """        osg::ref_ptr<osg::StateSet> stateset = SceneUtil::createSimpleWaterStateSet(alpha, MWRender::RenderBin_Water);

#ifdef ANDROID
        // Android WetWorld water alpha mask: preserve normal RGB blending while
        // forcing visible water pixels to alpha 0 in the scene colour target.
        stateset->setAttributeAndModes(
            new osg::BlendFunc(osg::BlendFunc::SRC_ALPHA, osg::BlendFunc::ONE_MINUS_SRC_ALPHA,
                osg::BlendFunc::ZERO, osg::BlendFunc::ZERO),
            osg::StateAttribute::ON);
#endif

        node->setStateSet(stateset);"""
    text = replace_once(text, simple_anchor, simple_replacement, "water.cpp simple water alpha mask")

    shader_anchor = """            else
            {
                stateset->setMode(GL_BLEND, osg::StateAttribute::ON);
                stateset->setRenderBinDetails(MWRender::RenderBin_Water, "RenderBin");"""
    shader_replacement = """            else
            {
                stateset->setMode(GL_BLEND, osg::StateAttribute::ON);
#ifdef ANDROID
                // Android WetWorld water alpha mask: RGB keeps the standard
                // source-alpha blend, alpha is replaced with 0. Water shading and
                // rain ripples remain untouched.
                stateset->setAttributeAndModes(
                    new osg::BlendFunc(osg::BlendFunc::SRC_ALPHA, osg::BlendFunc::ONE_MINUS_SRC_ALPHA,
                        osg::BlendFunc::ZERO, osg::BlendFunc::ZERO),
                    osg::StateAttribute::ON);
#endif
                stateset->setRenderBinDetails(MWRender::RenderBin_Water, "RenderBin");"""
    text = replace_once(text, shader_anchor, shader_replacement, "water.cpp shader water alpha mask")

    define_anchor = """        defineMap["wobblyShores"] = Settings::water().mWobblyShores ? "1" : "0";

        Stereo::shaderStereoDefines(defineMap);"""
    define_replacement = """        defineMap["wobblyShores"] = Settings::water().mWobblyShores ? "1" : "0";
#ifdef ANDROID
        defineMap["wetWorldWaterMask"] = "1";
#else
        defineMap["wetWorldWaterMask"] = "0";
#endif

        Stereo::shaderStereoDefines(defineMap);"""
    text = replace_once(text, define_anchor, define_replacement, "water.cpp WetWorld shader define")

    require(text, WATER_MASK_MARKER, "water.cpp")
    require(text, "osg::BlendFunc::ZERO, osg::BlendFunc::ZERO", "water.cpp")
    write(path, text)


def patch_water_shader_alpha(path: Path) -> None:
    text = read(path)

    if WATER_MASK_MARKER in text:
        require(text, "#if @wetWorldWaterMask", "water.frag")
        require(text, "gl_FragData[0].a = 0.0;", "water.frag")
        return

    # With refraction enabled water is rendered without the transparent blend
    # branch, so mark those water pixels directly in alpha. RGB stays unchanged.
    text = replace_once(
        text,
        """    gl_FragData[0].rgb = mix(refraction, reflection, fresnel);
    gl_FragData[0].a = 1.0;""",
        """    gl_FragData[0].rgb = mix(refraction, reflection, fresnel);
#if @wetWorldWaterMask
    // Android WetWorld water alpha mask. Only alpha is used as a post-process
    // marker; RGB water shading, wave response and rain ripples are unchanged.
    gl_FragData[0].a = 0.0;
#else
    gl_FragData[0].a = 1.0;
#endif""",
        "water.frag refraction alpha marker",
    )

    require(text, WATER_MASK_MARKER, "water.frag")
    require(text, "#if @wetWorldWaterMask", "water.frag")
    require(text, "gl_FragData[0].a = 0.0;", "water.frag")
    write(path, text)


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: apply-postprocessing-final.py <OpenMW-source-dir>")

    root = Path(sys.argv[1]).resolve()
    patch_header(root / "apps/openmw/mwrender/postprocessor.hpp")
    cpp = root / "apps/openmw/mwrender/postprocessor.cpp"
    patch_cpp(cpp)
    patch_android_depth(cpp)
    patch_water_alpha_mask(root / "apps/openmw/mwrender/water.cpp")
    patch_water_shader_alpha(root / "files/shaders/compatibility/water.frag")

    print("OpenMW 0.50 Android post-processing final state: READY")
    print("  early FBO size initialization: applied")
    print("  one completed GL warm-up draw: applied")
    print("  four-draw final chain stabilization: applied")
    print("  Android GLES direct scene-depth binding: applied")
    print("  WetWorld exact water alpha marker: applied")

if __name__ == "__main__":
    main()
