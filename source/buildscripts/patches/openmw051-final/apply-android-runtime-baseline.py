#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-android-runtime-baseline.py <openmw-source-dir>')

root = Path(sys.argv[1])
engine = root / 'apps' / 'openmw' / 'engine.cpp'
androidmain = root / 'apps' / 'openmw' / 'androidmain.cpp'
loading = root / 'apps' / 'openmw' / 'mwgui' / 'loadingscreen.cpp'
windowmanager = root / 'apps' / 'openmw' / 'mwgui' / 'windowmanagerimp.cpp'
nifloader = root / 'components' / 'nifosg' / 'nifloader.cpp'
stateupdater = root / 'components' / 'sceneutil' / 'stateupdater.cpp'
objects_frag = root / 'files' / 'shaders' / 'compatibility' / 'objects.frag'
fog_glsl = root / 'files' / 'shaders' / 'compatibility' / 'fog.glsl'
shadow_fragment = root / 'files' / 'shaders' / 'compatibility' / 'shadows_fragment.glsl'
shadow_casting = root / 'files' / 'shaders' / 'compatibility' / 'shadowcasting.vert'
mwshadowtechnique = root / 'components' / 'sceneutil' / 'mwshadowtechnique.cpp'
shadow_manager = root / 'components' / 'sceneutil' / 'shadow.cpp'
postprocessor = root / 'apps' / 'openmw' / 'mwrender' / 'postprocessor.cpp'
postprocessor_hpp = root / 'apps' / 'openmw' / 'mwrender' / 'postprocessor.hpp'
renderingmanager = root / 'apps' / 'openmw' / 'mwrender' / 'renderingmanager.cpp'
renderingmanager_hpp = root / 'apps' / 'openmw' / 'mwrender' / 'renderingmanager.hpp'
fx_stateupdater_hpp = root / 'components' / 'fx' / 'stateupdater.hpp'
water_cpp = root / 'apps' / 'openmw' / 'mwrender' / 'water.cpp'
water_frag = root / 'files' / 'shaders' / 'compatibility' / 'water.frag'

for path in (engine, androidmain, loading, windowmanager, nifloader, stateupdater, objects_frag, fog_glsl,
             shadow_fragment, shadow_casting, mwshadowtechnique, shadow_manager, postprocessor, postprocessor_hpp,
             renderingmanager, renderingmanager_hpp, fx_stateupdater_hpp, water_cpp, water_frag):
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.51 source file: {path}')

RUNTIME_MARKER = 'OPENMW_ANDROID_051_RUNTIME_BASELINE'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)

# ---------------------------------------------------------------------------
# Android Surface lifecycle bridge
# ---------------------------------------------------------------------------
text = engine.read_text(encoding='utf-8')
if RUNTIME_MARKER not in text:
    text = replace_once(
        text,
        'void OMW::Engine::createWindow()\n{',
        '''#ifdef ANDROID\n// OPENMW_ANDROID_051_RUNTIME_BASELINE\n// Shared with androidmain.cpp. Android can destroy/recreate the Surface while\n// the native OpenMW process and viewer remain alive.\nosg::ref_ptr<osgViewer::Viewer> g_viewer;\nbool g_androidWindowManagerReady = false;\n#endif\n\nvoid OMW::Engine::createWindow()\n{''',
        'engine/createWindow marker',
    )

    text = replace_once(
        text,
        '''    mViewer->getEventQueue()->getCurrentEventState()->setWindowRectangle(\n        0, 0, graphicsWindow->getTraits()->width, graphicsWindow->getTraits()->height);\n}''',
        '''    mViewer->getEventQueue()->getCurrentEventState()->setWindowRectangle(\n        0, 0, graphicsWindow->getTraits()->width, graphicsWindow->getTraits()->height);\n\n#ifdef ANDROID\n    // Keep a strong viewer reference for the Java Surface lifecycle bridge.\n    g_viewer = mViewer;\n#endif\n}''',
        'engine/viewer assignment',
    )

    text = replace_once(
        text,
        '''    mEnvironment.setWindowManager(*mWindowManager);\n\n    mInputManager = std::make_unique<MWInput::InputManager>''',
        '''    mEnvironment.setWindowManager(*mWindowManager);\n#ifdef ANDROID\n    g_androidWindowManagerReady = true;\n#endif\n\n    mInputManager = std::make_unique<MWInput::InputManager>''',
        'engine/window manager ready',
    )

    text = replace_once(
        text,
        '''    mLuaWorker->join();\n\n    // Save user settings''',
        '''    mLuaWorker->join();\n\n#ifdef ANDROID\n    g_androidWindowManagerReady = false;\n    g_viewer.release();\n#endif\n\n    // Save user settings''',
        'engine/viewer release',
    )

    engine.write_text(text, encoding='utf-8', newline='\n')
    print('Applied OpenMW 0.51 Android Surface lifecycle bridge.')
else:
    print('OpenMW 0.51 Android Surface lifecycle bridge is already applied.')

text = androidmain.read_text(encoding='utf-8')
if RUNTIME_MARKER not in text:
    text = replace_once(
        text,
        '#include "SDL_main.h"\n',
        '''#include "SDL_main.h"\n#include "mwbase/environment.hpp"\n#include "mwbase/windowmanager.hpp"\n''',
        'androidmain/OpenMW includes',
    )
    text = replace_once(
        text,
        '#include <SDL_gamecontroller.h>\n#include <SDL_mouse.h>\n',
        '''#include <SDL_gamecontroller.h>\n#include <SDL_hints.h>\n#include <SDL_mouse.h>\n\n#include <osg/GraphicsContext>\n#include <osg/OperationThread>\n#include <osgViewer/Viewer>\n''',
        'androidmain/SDL+OSG includes',
    )
    text = replace_once(
        text,
        '''        "righttrigger:a4,rightx:a2,righty:a3,start:b11,x:b3,y:b4");\n\n    return 0;\n}\n''',
        '''        "righttrigger:a4,rightx:a2,righty:a3,start:b11,x:b3,y:b4");\n\n    // OPENMW_ANDROID_051_RUNTIME_BASELINE\n    // Do not stall the SDL thread while Android is paused. Surface ownership is\n    // coordinated explicitly below with OSG's GraphicsContext operation queue.\n    SDL_SetHint(SDL_HINT_ANDROID_BLOCK_ON_PAUSE, "0");\n    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");\n\n    return 0;\n}\n\nextern osg::ref_ptr<osgViewer::Viewer> g_viewer;\nextern bool g_androidWindowManagerReady;\nstatic osg::GraphicsContext* g_androidContext = nullptr;\n\nclass CtxReleaseOperation : public osg::Operation\n{\npublic:\n    CtxReleaseOperation()\n        : osg::Operation("OpenMW Android release GL context", false)\n    {\n    }\n\n    void operator()(osg::Object*) override\n    {\n        if (g_androidContext)\n            g_androidContext->releaseContext();\n    }\n};\n\nclass CtxAcquireOperation : public osg::Operation\n{\npublic:\n    CtxAcquireOperation()\n        : osg::Operation("OpenMW Android acquire GL context", false)\n    {\n    }\n\n    void operator()(osg::Object*) override\n    {\n        if (g_androidContext)\n            g_androidContext->makeCurrent();\n    }\n};\n\nextern "C" void Java_org_libsdl_app_SDLActivity_omwSurfaceDestroyed(JNIEnv*, jclass)\n{\n    if (!g_viewer)\n        return;\n\n    g_androidContext = g_viewer->getCamera()->getGraphicsContext();\n    if (g_androidContext)\n        g_androidContext->add(new CtxReleaseOperation());\n\n    if (g_androidWindowManagerReady)\n        MWBase::Environment::get().getWindowManager()->windowVisibilityChange(false);\n}\n\nextern "C" void Java_org_libsdl_app_SDLActivity_omwSurfaceRecreated(JNIEnv*, jclass)\n{\n    if (!g_viewer)\n        return;\n\n    g_androidContext = g_viewer->getCamera()->getGraphicsContext();\n    if (g_androidContext)\n        g_androidContext->add(new CtxAcquireOperation());\n\n    if (g_androidWindowManagerReady)\n        MWBase::Environment::get().getWindowManager()->windowVisibilityChange(true);\n}\n''',
        'androidmain/runtime bridge',
    )
    androidmain.write_text(text, encoding='utf-8', newline='\n')
    print('Applied OpenMW 0.51 Android JNI lifecycle hooks and SDL hints.')
else:
    print('OpenMW 0.51 Android JNI lifecycle hooks are already applied.')

# ---------------------------------------------------------------------------
# Initialize the native OpenMW 0.51 post-processing render
# size before any HUD viewport, texture, or FBO objects are created.
#
# Upstream 0.51 assigns mWidth/mHeight only after createObjectsForFrame(0/1).
# On Android/GL4ES this can create startup render targets from indeterminate
# dimensions. Keep desktop behaviour unchanged and move only the Android size
# acquisition to the beginning of the constructor. Header defaults add a safe
# zero baseline for all platforms without altering normal runtime dimensions.
# ---------------------------------------------------------------------------
pp_init_marker = 'OPENMW_ANDROID_051_GATE_G_PP_INIT'
text = postprocessor_hpp.read_text(encoding='utf-8')
if pp_init_marker not in text:
    text = replace_once(
        text,
        '''        int mGLSLVersion;
        int mWidth;
        int mHeight;
        int mSamples;''',
        '''        int mGLSLVersion;
        // OPENMW_ANDROID_051_GATE_G_PP_INIT
#ifdef ANDROID
        // Safe defaults; Android assigns the live GraphicsContext size before
        // the first PP viewport/textures/FBOs are constructed.
        int mWidth = 0;
        int mHeight = 0;
#else
        int mWidth;
        int mHeight;
#endif
        int mSamples;''',
        'postprocessor.hpp/safe render-size defaults',
    )
    postprocessor_hpp.write_text(text, encoding='utf-8', newline='\n')
    print('Applied safe OpenMW 0.51 post-processing render-size defaults.')
else:
    print('OpenMW 0.51 post-processing render-size defaults are already applied.')

text = postprocessor.read_text(encoding='utf-8')
if pp_init_marker not in text:
    text = replace_once(
        text,
        '#include <thread>\n',
        '#include <thread>\n#include <stdexcept>\n',
        'postprocessor.cpp/stdexcept include',
    )
    text = replace_once(
        text,
        '''    {
        auto& shaderManager = mRendering.getResourceSystem()->getSceneManager()->getShaderManager();''',
        '''    {
#ifdef ANDROID
        // OPENMW_ANDROID_051_GATE_G_PP_INIT
        // Establish the actual Android render size before setViewport()
        // and before createObjectsForFrame() allocates PP textures/FBOs.
        osg::GraphicsContext* gc = viewer->getCamera()->getGraphicsContext();
        if (!gc || !gc->getTraits())
            throw std::runtime_error("OpenMW Android: missing GraphicsContext traits for post-processing");
        mWidth = gc->getTraits()->width;
        mHeight = gc->getTraits()->height;
        Log(Debug::Info) << "OpenMW 0.51 Android renderer: " << mWidth << "x" << mHeight
                         << ", Tex_Depth scene binding";
#endif

        auto& shaderManager = mRendering.getResourceSystem()->getSceneManager()->getShaderManager();''',
        'postprocessor.cpp/early Android render size',
    )
    text = replace_once(
        text,
        '''        osg::GraphicsContext* gc = viewer->getCamera()->getGraphicsContext();
        osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();

        mWidth = gc->getTraits()->width;
        mHeight = gc->getTraits()->height;''',
        '''#ifndef ANDROID
        osg::GraphicsContext* gc = viewer->getCamera()->getGraphicsContext();
        mWidth = gc->getTraits()->width;
        mHeight = gc->getTraits()->height;
#endif
        osg::GLExtensions* ext = gc->getState()->get<osg::GLExtensions>();''',
        'postprocessor.cpp/reuse early Android GraphicsContext',
    )
    postprocessor.write_text(text, encoding='utf-8', newline='\n')
    print('Applied early Android OpenMW 0.51 post-processing render-size initialization.')
else:
    print('OpenMW 0.51 early post-processing render-size initialization is already applied.')

# ---------------------------------------------------------------------------
# Android GLES/GL4ES post-processing scene depth.
#
# The OpenMW 0.50 Android runtime deliberately exposed Tex_Depth to OMWFX.
# Tex_OpaqueDepth relies on a depth-copy path which is not reliable on the
# GLES2/GL4ES backend. Without this routing, depth-shaped Godrays compile but
# receive an empty/stale mask and therefore evaluate to zero on device.
# Keep the upstream opaque-depth source on every non-Android platform.
# ---------------------------------------------------------------------------
pp_scene_depth_marker = 'OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH'
text = postprocessor.read_text(encoding='utf-8')
if pp_scene_depth_marker not in text:
    text = replace_once(
        text,
        '        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));',
        '''#ifdef ANDROID
        // OPENMW_ANDROID_051_POSTPROCESSING_SCENE_DEPTH
        // The primary scene depth texture is directly sampleable on GLES2.
        // Tex_OpaqueDepth depends on an unreliable GL4ES depth copy/blit.
        mCanvases[frameId]->setTextureDepth(getTexture(Tex_Depth, frameId));
#else
        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));
#endif''',
        'postprocessor.cpp/Android OMWFX scene-depth binding',
    )
    postprocessor.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android OpenMW 0.51 direct scene-depth binding for OMWFX.')
else:
    print('Android OpenMW 0.51 OMWFX scene-depth binding is already applied.')

# ---------------------------------------------------------------------------
# Exact water exclusion for WetWorld.
#
# WetWorld reconstructs upward-facing surfaces from the scene depth texture.
# Transparent water does not own a reliable sampleable depth identity on the
# GLES2/GL4ES path, so reserve scene alpha 0 as an exact water marker. Normal
# RGB water shading, reflection/refraction and native rain ripples are kept.
# ---------------------------------------------------------------------------
wetworld_water_marker = 'OPENMW_ANDROID_051_WETWORLD_WATER_MASK'
text = water_cpp.read_text(encoding='utf-8')
if wetworld_water_marker not in text:
    text = replace_once(
        text,
        '#include <osg/ClipNode>\n#include <osg/Depth>',
        '#include <osg/BlendFunc>\n#include <osg/ClipNode>\n#include <osg/Depth>',
        'water.cpp/WetWorld BlendFunc include',
    )
    text = replace_once(
        text,
        '''        osg::ref_ptr<osg::StateSet> stateset = SceneUtil::createSimpleWaterStateSet(alpha, MWRender::RenderBin_Water);

        node->setStateSet(stateset);''',
        '''        osg::ref_ptr<osg::StateSet> stateset = SceneUtil::createSimpleWaterStateSet(alpha, MWRender::RenderBin_Water);

#ifdef ANDROID
        // OPENMW_ANDROID_051_WETWORLD_WATER_MASK
        // Preserve normal RGB blending and force only scene alpha to zero.
        stateset->setAttributeAndModes(
            new osg::BlendFunc(osg::BlendFunc::SRC_ALPHA, osg::BlendFunc::ONE_MINUS_SRC_ALPHA,
                osg::BlendFunc::ZERO, osg::BlendFunc::ZERO),
            osg::StateAttribute::ON);
#endif

        node->setStateSet(stateset);''',
        'water.cpp/simple-water alpha marker',
    )
    text = replace_once(
        text,
        '''            else
            {
                stateset->setMode(GL_BLEND, osg::StateAttribute::ON);
                stateset->setRenderBinDetails(MWRender::RenderBin_Water, "RenderBin");''',
        '''            else
            {
                stateset->setMode(GL_BLEND, osg::StateAttribute::ON);
#ifdef ANDROID
                // OPENMW_ANDROID_051_WETWORLD_WATER_MASK
                // Preserve source-alpha RGB while reserving scene alpha 0.
                stateset->setAttributeAndModes(
                    new osg::BlendFunc(osg::BlendFunc::SRC_ALPHA, osg::BlendFunc::ONE_MINUS_SRC_ALPHA,
                        osg::BlendFunc::ZERO, osg::BlendFunc::ZERO),
                    osg::StateAttribute::ON);
#endif
                stateset->setRenderBinDetails(MWRender::RenderBin_Water, "RenderBin");''',
        'water.cpp/shader-water alpha marker',
    )
    text = replace_once(
        text,
        '''        defineMap["wobblyShores"] = Settings::water().mWobblyShores ? "1" : "0";

        Stereo::shaderStereoDefines(defineMap);''',
        '''        defineMap["wobblyShores"] = Settings::water().mWobblyShores ? "1" : "0";
#ifdef ANDROID
        defineMap["wetWorldWaterMask"] = "1";
#else
        defineMap["wetWorldWaterMask"] = "0";
#endif

        Stereo::shaderStereoDefines(defineMap);''',
        'water.cpp/WetWorld shader define',
    )
    water_cpp.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android OpenMW 0.51 WetWorld water-alpha exclusion.')
else:
    print('Android OpenMW 0.51 WetWorld water-alpha exclusion already applied.')

text = water_frag.read_text(encoding='utf-8')
if wetworld_water_marker not in text:
    text = replace_once(
        text,
        '''    gl_FragData[0].rgb = mix(refraction, reflection, fresnel);
    gl_FragData[0].a = 1.0;''',
        '''    gl_FragData[0].rgb = mix(refraction, reflection, fresnel);
#if @wetWorldWaterMask
    // OPENMW_ANDROID_051_WETWORLD_WATER_MASK
    // Alpha is reserved as an exact post-processing water marker on Android.
    // RGB shading and native rain-ripple lighting remain unchanged.
    gl_FragData[0].a = 0.0;
#else
    gl_FragData[0].a = 1.0;
#endif''',
        'water.frag/refraction alpha marker',
    )
    water_frag.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android OpenMW 0.51 WetWorld marker to water.frag.')
else:
    print('Android OpenMW 0.51 water.frag WetWorld marker already applied.')

# ---------------------------------------------------------------------------
# Loading screen: framebuffer copy is unreliable on Android/GL4ES. Keep the
# upstream implementation untouched on every non-Android platform.
# ---------------------------------------------------------------------------
text = loading.read_text(encoding='utf-8')
loading_marker = 'OPENMW_ANDROID_051_LOADINGSCREEN_NO_FB_COPY'
if loading_marker not in text:
    text = replace_once(
        text,
        '''    void LoadingScreen::setupCopyFramebufferToTextureCallback()\n    {\n        // Copy the current framebuffer onto a texture and display that texture as the background image''',
        '''    void LoadingScreen::setupCopyFramebufferToTextureCallback()\n    {\n#ifdef ANDROID\n        // OPENMW_ANDROID_051_LOADINGSCREEN_NO_FB_COPY\n        // glCopyTexImage2D from the live default framebuffer is unreliable on\n        // the Android GL4ES path during loading transitions. Keep the normal\n        // loading UI but skip only this scene-background capture.\n        return;\n#endif\n\n        // Copy the current framebuffer onto a texture and display that texture as the background image''',
        'loadingscreen/framebuffer copy',
    )
    loading.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android-only OpenMW 0.51 loading-screen framebuffer-copy workaround.')
else:
    print('OpenMW 0.51 loading-screen framebuffer-copy workaround is already applied.')

# ---------------------------------------------------------------------------
# Android menu cursor / absolute-touch compatibility.
#
# CaveBros' SDLSurface deliberately accepts a new touchscreen gesture only while
# SDL reports the mouse cursor as shown. OpenMW normally combines mCursorVisible
# with mCursorActive. Controller-menu navigation sets mCursorActive=false, which
# makes SDL hide the cursor and prevents absolute touch from waking the menu
# cursor again. The established 0.50 Android patch intentionally ignored only
# mCursorActive for this query. Preserve that behavior on Android while leaving
# every desktop platform on the upstream 0.51 semantics.
# ---------------------------------------------------------------------------
text = windowmanager.read_text(encoding='utf-8')
cursor_marker = 'OPENMW_ANDROID_051_ABSOLUTE_TOUCH_CURSOR'
if cursor_marker not in text:
    text = replace_once(
        text,
        '''    bool WindowManager::getCursorVisible()
    {
        return mCursorVisible && mCursorActive;
    }''',
        '''    bool WindowManager::getCursorVisible()
    {
#ifdef ANDROID
        // OPENMW_ANDROID_051_ABSOLUTE_TOUCH_CURSOR
        // Keep SDL's menu cursor logically visible even while controller-menu
        // navigation marks the MyGUI cursor inactive. The Android absolute-touch
        // bridge uses SDL_ShowCursor(SDL_QUERY) to decide whether a finger-down
        // may start a menu interaction.
        return mCursorVisible;
#else
        return mCursorVisible && mCursorActive;
#endif
    }''',
        'windowmanager/Android absolute-touch cursor visibility',
    )
    windowmanager.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android-only OpenMW 0.51 absolute-touch menu cursor compatibility.')
else:
    print('OpenMW 0.51 absolute-touch menu cursor compatibility is already applied.')

# ---------------------------------------------------------------------------
# Patch 7: retire the negative Patch-6 NiFogProperty diagnostic and preserve
# upstream 0.51 NIF fog semantics. The device log showed no FogDiag hits for
# the affected exterior objects, so the diagnostic hypothesis was rejected.
# ---------------------------------------------------------------------------
text = nifloader.read_text(encoding='utf-8')
fog_diag_marker = 'OPENMW_ANDROID_051_FOG_DIAG_INHERIT_DISABLED_NIF_FOG'
fog_diag_block = '''#ifdef ANDROID
                    if (!fogprop->enabled())
                    {
                        // OPENMW_ANDROID_051_FOG_DIAG_INHERIT_DISABLED_NIF_FOG
                        // Diagnostic A/B: do not install OpenMW's local no-fog
                        // override for an explicitly disabled NiFogProperty.
                        // With no local attribute installed, the node inherits
                        // the global world/view-distance fog from the scene root.
                        Log(Debug::Info)
                            << "[Android FogDiag] Inheriting global fog instead of disabled NiFogProperty: "
                            << mFilename;
                        break;
                    }
#endif
                    '''
if fog_diag_marker in text:
    text = replace_once(text, fog_diag_block, '', 'nifloader/remove Patch-6 fog diagnostic')
    nifloader.write_text(text, encoding='utf-8', newline='\n')
    print('Removed rejected Patch-6 NiFogProperty diagnostic; restored upstream 0.51 behavior.')
else:
    print('Patch-6 NiFogProperty diagnostic is not present (expected for clean 0.51 source).')

# ---------------------------------------------------------------------------
# Patch 7: explicit Android/GL4ES object-fog uniforms.
#
# OpenMW 0.51 removed the exclusive FFP path, so ordinary NIFs now use the
# objects shader. On the GL4ES compatibility path, terrain fog is correct while
# objects can retain stale/incorrect gl_Fog built-ins. StateUpdater already owns
# the authoritative fog color/start/end values. Mirror those values into normal
# GLSL uniforms on Android and let ONLY objects.frag opt into them. Terrain stays
# on upstream gl_Fog as an A/B control.
# ---------------------------------------------------------------------------
fog_uniform_marker = 'OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG_UNIFORMS'
text = stateupdater.read_text(encoding='utf-8')
if fog_uniform_marker not in text:
    text = replace_once(
        text,
        '''        stateset->setAttributeAndModes(fog, osg::StateAttribute::ON);
        if (mWireframe)''',
        '''        stateset->setAttributeAndModes(fog, osg::StateAttribute::ON);
#ifdef ANDROID
        // OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG_UNIFORMS
        // GL4ES does not reliably propagate compatibility gl_Fog built-ins to
        // every OpenMW 0.51 objects-program variant. Expose the same authoritative
        // StateUpdater values as ordinary uniforms; only objects.frag consumes them.
        stateset->addUniform(new osg::Uniform("omwFogColor", osg::Vec4f{}));
        stateset->addUniform(new osg::Uniform("omwFogStart", 0.f));
        stateset->addUniform(new osg::Uniform("omwFogEnd", 0.f));
#endif
        if (mWireframe)''',
        'stateupdater/explicit Android object-fog uniform defaults',
    )
    text = replace_once(
        text,
        '''        fog->setColor(mFogColor);
        fog->setStart(mFogStart);
        fog->setEnd(mFogEnd);
    }''',
        '''        fog->setColor(mFogColor);
        fog->setStart(mFogStart);
        fog->setEnd(mFogEnd);
#ifdef ANDROID
        stateset->getUniform("omwFogColor")->set(mFogColor);
        stateset->getUniform("omwFogStart")->set(mFogStart);
        stateset->getUniform("omwFogEnd")->set(mFogEnd);
#endif
    }''',
        'stateupdater/explicit Android object-fog uniform updates',
    )
    stateupdater.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android/GL4ES explicit object-fog uniforms to StateUpdater.')
else:
    print('Android/GL4ES explicit object-fog uniforms are already applied.')

object_fog_marker = 'OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG'
text = fog_glsl.read_text(encoding='utf-8')
if object_fog_marker not in text:
    # Rewrite only the upstream fog-function body first, then prepend fallback
    # macros. This deliberately leaves the fallback gl_Fog references intact.
    text = text.replace('gl_Fog.start/2.0', 'OPENMW_FOG_START/2.0')
    text = text.replace('gl_Fog.end - OPENMW_FOG_START/2.0', 'OPENMW_FOG_END - OPENMW_FOG_START/2.0')
    text = text.replace('gl_Fog.start', 'OPENMW_FOG_START')
    text = text.replace('gl_Fog.scale', 'OPENMW_FOG_SCALE')
    text = text.replace('gl_Fog.color', 'OPENMW_FOG_COLOR')
    text = '''// OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG
#ifdef OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG
uniform vec4 omwFogColor;
uniform float omwFogStart;
uniform float omwFogEnd;
#define OPENMW_FOG_START omwFogStart
#define OPENMW_FOG_END omwFogEnd
#define OPENMW_FOG_SCALE (1.0 / max(omwFogEnd - omwFogStart, 0.0001))
#define OPENMW_FOG_COLOR omwFogColor
#else
#define OPENMW_FOG_START gl_Fog.start
#define OPENMW_FOG_END gl_Fog.end
#define OPENMW_FOG_SCALE gl_Fog.scale
#define OPENMW_FOG_COLOR gl_Fog.color
#endif

''' + text
    fog_glsl.write_text(text, encoding='utf-8', newline='\n')
    print('Added explicit-fog compatibility path to fog.glsl; upstream path remains fallback.')
else:
    print('Explicit-fog compatibility path is already present in fog.glsl.')

text = objects_frag.read_text(encoding='utf-8')
objects_fog_define = '#define OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG\n#include "fog.glsl"'
if objects_fog_define not in text:
    text = replace_once(
        text,
        '#include "fog.glsl"',
        '''// Android/GL4ES Patch 7: use authoritative OpenMW fog uniforms instead of
// compatibility gl_Fog built-ins for ordinary NIF/object shaders only.
#define OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG
#include "fog.glsl"''',
        'objects.frag/enable explicit Android object fog',
    )
    objects_frag.write_text(text, encoding='utf-8', newline='\n')
    print('Enabled explicit Android/GL4ES fog path for objects.frag only.')
else:
    print('objects.frag already enables explicit Android/GL4ES fog.')

# ---------------------------------------------------------------------------
# Minimal GL4ES syntax compatibility only. Do NOT port the large 0.50 GL4ES
# shader rewrite here: 0.51 changed its shader architecture. These four default
# uniform initializers are independently known to be problematic on GLES/GL4ES.
# ---------------------------------------------------------------------------
shader_replacements = {
    root / 'files' / 'shaders' / 'compatibility' / 'fullscreen_tri.vert': [
        ('uniform vec2 scaling = vec2(1.0, 1.0);', 'uniform vec2 scaling;'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'shadowcasting.vert': [
        ('uniform bool useDiffuseMapForShadowAlpha = true;', 'uniform bool useDiffuseMapForShadowAlpha;'),
        ('uniform bool alphaTestShadows = true;', 'uniform bool alphaTestShadows;'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'debug.vert': [
        ('uniform bool useAdvancedShader = false;', 'uniform bool useAdvancedShader;'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'debug.frag': [
        ('uniform bool useAdvancedShader = false;', 'uniform bool useAdvancedShader;'),
    ],
}

for path, replacements in shader_replacements.items():
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.51 shader: {path}')
    text = path.read_text(encoding='utf-8')
    changed = False
    for old, new in replacements:
        if old in text:
            text = text.replace(old, new)
            changed = True
        elif new not in text:
            raise SystemExit(f'unexpected OpenMW 0.51 shader content in {path}: missing {old!r}')
    if changed:
        path.write_text(text, encoding='utf-8', newline='\n')
        print(f'Removed GL4ES-hostile uniform initializer(s): {path.relative_to(root)}')

# ---------------------------------------------------------------------------
# Patch 8: proven OpenMW-0.50 Android/GL4ES normal-transform compatibility.
#
# The 0.51 compatibility shaders still directly evaluate gl_NormalMatrix in
# stages where GL4ES/Adreno has historically produced unreliable results. Each
# affected shader already carries OpenMW's normalToViewMatrix varying. Reuse
# that path exactly as the stable 0.50 Android patch did. These substitutions
# are mathematically equivalent on desktop GL and intentionally do not change
# fog, texture sampling, material equations, object paging, or post processing.
# ---------------------------------------------------------------------------
normal_transform_replacements = {
    root / 'files' / 'shaders' / 'compatibility' / 'objects.vert': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(passNormal);'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'objects.frag': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(normalize(passNormal));'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'terrain.vert': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(passNormal);'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'terrain.frag': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(normalize(passNormal));'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'groundcover.vert': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(passNormal);'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'bs' / 'default.vert': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(passNormal);'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'bs' / 'default.frag': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalToView(normalize(passNormal));'),
    ],
    root / 'files' / 'shaders' / 'compatibility' / 'bs' / 'nolighting.vert': [
        ('vec3 viewNormal = normalize(gl_NormalMatrix * passNormal);',
         'vec3 viewNormal = normalize((gl_NormalMatrix * gl_Normal).xyz);'),
    ],
}

for path, replacements in normal_transform_replacements.items():
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.51 normal-transform shader: {path}')
    text = path.read_text(encoding='utf-8')
    changed = False
    for old, new in replacements:
        if old in text:
            if text.count(old) != 1:
                raise SystemExit(f'unexpected duplicate normal-transform anchor in {path}: {old!r}')
            text = text.replace(old, new, 1)
            changed = True
        elif new not in text:
            raise SystemExit(f'unexpected OpenMW 0.51 normal-transform shader content in {path}: missing {old!r}')
    if changed:
        path.write_text(text, encoding='utf-8', newline='\n')
        print(f'Applied Android/GL4ES normal-transform compatibility: {path.relative_to(root)}')

# ---------------------------------------------------------------------------
# Patch 11: proven Android/GL4ES additive-fog compatibility.
#
# On the GLES2 wrapper, defining ADDITIVE_BLENDING for ordinary object shaders
# makes the fog helper multiply RGB toward black instead of blending toward the
# scene fog colour. The stable 0.50 Android shader patch deliberately omitted
# this define, and the 0.51 device A/B test confirmed it fixes black distant
# trees/rocks at every viewing distance. Preserve the proven behaviour here.
# ---------------------------------------------------------------------------
additive_fog_marker = 'OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG'
text = objects_frag.read_text(encoding='utf-8')
if additive_fog_marker not in text:
    text = replace_once(
        text,
        '''#if @additiveBlending
#define ADDITIVE_BLENDING
#endif''',
        '''// OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG
// Android/GL4ES compatibility: do not select compatibility/fog.glsl's
// additive branch for ordinary objects; it fades object RGB toward black.
// This matches the proven OpenMW 0.50 Android GL4ES behaviour.''',
        'objects.frag/disable additive fog branch on Android compatibility path',
    )
    objects_frag.write_text(text, encoding='utf-8', newline='\n')
    print('Applied proven Patch-11 Android/GL4ES additive-fog compatibility.')
elif '#define ADDITIVE_BLENDING' in text:
    raise SystemExit('Patch-11 additive-fog marker exists but ADDITIVE_BLENDING is still defined')
else:
    print('Patch-11 Android/GL4ES additive-fog compatibility is already applied.')

# ---------------------------------------------------------------------------
# Patch 12 / Gate F: Android GLES2 shadow compatibility.
#
# GL4ES exposes OES_depth_texture on the GLES2 backend but not the desktop
# shadow-sampler path OpenMW 0.51 expects. The proven 0.50 Android solution uses
# raw sampler2D depth textures plus an explicit LEQUAL comparison. Android also
# lacks GL_DEPTH_CLAMP / ARB_clip_control. Android deliberately uses normal
# GLES2 clip-volume clipping for shadow casters; desktop retains depth clamp.
# ---------------------------------------------------------------------------
shadow_compare_marker = 'OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE'
shadow_pcf_marker = 'OPENMW_ANDROID_051_GLES2_QUALITY_PCF'
native_clip_marker = 'OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING'

shadow_pcf_header = '''#define SHADOWS @shadows_enabled

// OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE
// GLES2/GL4ES: sample OES depth textures through sampler2D and perform
// the LEQUAL test explicitly; EXT_shadow_samplers is not available.
//
// OPENMW_ANDROID_051_GLES2_QUALITY_PCF
// The launcher specializes these two compile-time constants before each game
// start. Keeping the kernel compile-time avoids dynamic loops/branches on GLES2.
// Level 0 = legacy 1 tap, level 1 = 2x2 / 4 taps (Low),
// level 2 = 3x3 / 9 taps (Medium), level 3 = 4x4 / 16 taps (High).
#define OPENMW_ANDROID_SHADOW_PCF_LEVEL 2
#define OPENMW_ANDROID_SHADOW_MAP_RESOLUTION 4096.0
'''

shadow_pcf_compare = '''// OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS
                // Raw GLES2 depth sampling must never compare receivers outside
                // the valid projected shadow depth volume. Otherwise z > 1 can
                // become a view-dependent full-shadow patch with CLAMP_TO_EDGE.
                if (shadowSpaceCoords@shadow_texture_unit_index.w > 0.0 && shadowXYZ.z > 0.0 && shadowXYZ.z < 1.0)
                {
                    vec2 shadowTexel = vec2(1.0 / OPENMW_ANDROID_SHADOW_MAP_RESOLUTION);
                    // OPENMW_ANDROID_051_GLES2_RECEIVER_DEPTH_BIAS
                    // Tiny manual receiver bias for the raw GLES2 depth compare.
                    // Normal offset removes the coarse terrain acne; this small
                    // residual bias moves only the comparison threshold enough
                    // to suppress the remaining fine hatch without visibly
                    // detaching shadows from their casters.
                    float receiverDepth = max(shadowXYZ.z - 0.00005, 0.0);
#if OPENMW_ANDROID_SHADOW_PCF_LEVEL == 0
                    // Legacy fallback: preserve the original single-tap GLES2 comparison.
                    shadowing = min(step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);
#elif OPENMW_ANDROID_SHADOW_PCF_LEVEL == 1
                    // Low: 2x2 PCF. Four neighbouring depth comparisons
                    // provide the previous Medium profile at modest mobile GPU cost.
                    vec2 shadowUv = clamp(shadowXYZ.xy, shadowTexel, vec2(1.0) - shadowTexel);
                    float pcfShadow = 0.0;
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-0.5, -0.5)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.5, -0.5)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-0.5,  0.5)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.5,  0.5)).r);
                    shadowing = min(pcfShadow * 0.25, shadowing);
#elif OPENMW_ANDROID_SHADOW_PCF_LEVEL == 2
                    // Medium: full 3x3 PCF. Nine independent nearest-depth
                    // comparisons retain the previous High profile quality
                    // without re-enabling unstable multi-map cascades.
                    vec2 shadowUv = clamp(shadowXYZ.xy, shadowTexel, vec2(1.0) - shadowTexel);
                    float pcfShadow = 0.0;
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.0, -1.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.0, -1.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.0, -1.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.0,  0.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.0,  0.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.0,  1.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.0,  1.0)).r);
                    pcfShadow += step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.0,  1.0)).r);
                    shadowing = min(pcfShadow * (1.0 / 9.0), shadowing);
#else
                    // High: weighted 4x4 tent PCF at 4096. A regular box filter
                    // can reveal its sampling grid on gently sloped terrain.
                    // The separable 1-3-3-1 weights keep all 16 depth samples,
                    // favour the centre, and suppress visible hatch/banding.
                    // OPENMW_ANDROID_051_GLES2_TENT_PCF
                    vec2 shadowMargin = shadowTexel * 2.0;
                    vec2 shadowUv = clamp(shadowXYZ.xy, shadowMargin, vec2(1.0) - shadowMargin);
                    float pcfShadow = 0.0;
                    pcfShadow += 1.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.5, -1.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-0.5, -1.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.5, -1.5)).r);
                    pcfShadow += 1.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.5, -1.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.5, -0.5)).r);
                    pcfShadow += 9.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-0.5, -0.5)).r);
                    pcfShadow += 9.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.5, -0.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.5, -0.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.5,  0.5)).r);
                    pcfShadow += 9.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-0.5,  0.5)).r);
                    pcfShadow += 9.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.5,  0.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.5,  0.5)).r);
                    pcfShadow += 1.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-1.5,  1.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2(-0.5,  1.5)).r);
                    pcfShadow += 3.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 0.5,  1.5)).r);
                    pcfShadow += 1.0 * step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowUv + shadowTexel * vec2( 1.5,  1.5)).r);
                    shadowing = min(pcfShadow * (1.0 / 64.0), shadowing);
#endif
                }'''

text = shadow_fragment.read_text(encoding='utf-8')
shadow_text_changed = False
if shadow_compare_marker not in text:
    text = replace_once(
        text,
        '#define SHADOWS @shadows_enabled\n',
        shadow_pcf_header,
        'shadows_fragment/manual compare + quality PCF header',
    )
    text = replace_once(
        text,
        'uniform sampler2DShadow shadowTexture@shadow_texture_unit_index;',
        'uniform sampler2D shadowTexture@shadow_texture_unit_index;',
        'shadows_fragment/sampler2DShadow',
    )
    text = replace_once(
        text,
        'shadowing = min(shadow2DProj(shadowTexture@shadow_texture_unit_index, shadowSpaceCoords@shadow_texture_unit_index).r, shadowing);',
        shadow_pcf_compare,
        'shadows_fragment/manual LEQUAL + quality PCF',
    )
    shadow_text_changed = True
elif shadow_pcf_marker not in text:
    # Upgrade an already-patched Patch-12 receiver without disturbing the
    # later orthographic/stability work in the same source tree.
    old_header = '''#define SHADOWS @shadows_enabled

// OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE
// GLES2/GL4ES: sample OES depth textures through sampler2D and perform
// the LEQUAL test explicitly; EXT_shadow_samplers is not available.
'''
    old_compare = '''// OPENMW_ANDROID_051_GLES2_SHADOW_COORD_BOUNDS
                // Raw GLES2 depth sampling must never compare receivers outside
                // the valid projected shadow depth volume. Otherwise z > 1 can
                // become a view-dependent full-shadow patch with CLAMP_TO_EDGE.
                if (shadowSpaceCoords@shadow_texture_unit_index.w > 0.0 && shadowXYZ.z > 0.0 && shadowXYZ.z < 1.0)
                    shadowing = min(step(receiverDepth, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);'''
    text = replace_once(
        text,
        old_header,
        shadow_pcf_header,
        'shadows_fragment/upgrade quality PCF header',
    )
    text = replace_once(
        text,
        old_compare,
        shadow_pcf_compare,
        'shadows_fragment/upgrade quality PCF compare',
    )
    shadow_text_changed = True

if shadow_text_changed:
    shadow_fragment.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android GLES2 manual shadow comparison with quality-dependent PCF.')
elif shadow_pcf_marker in text:
    print('Android GLES2 quality-dependent PCF shadow receiver is already applied.')

text = shadow_casting.read_text(encoding='utf-8')
if native_clip_marker not in text:
    text = replace_once(
        text,
        '    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n',
        '''    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;

    // OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING
    // GL_DEPTH_CLAMP/ARB_clip_control are unavailable through the GLES2 backend.
    // Deliberately use normal GLES2 near/far clipping here. Per-vertex Z
    // clamping can collapse off-volume caster vertices onto a clip plane and
    // produce large view-dependent triangular shadow projections.
''',
        'shadowcasting.vert/native GLES2 clipping marker',
    )
    shadow_casting.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android GLES2 native shadow-caster clipping marker.')

text = mwshadowtechnique.read_text(encoding='utf-8')
if shadow_compare_marker not in text:
    # Internal OSG fallback shaders must compile on the same GLES2 path.
    text = text.replace('sampler2DShadow', 'sampler2D')
    text = text.replace(
        'shadow2DProj( shadowTexture, gl_TexCoord[1] ).r',
        'step(gl_TexCoord[1].z / gl_TexCoord[1].w, texture2D(shadowTexture, gl_TexCoord[1].xy / gl_TexCoord[1].w).r)',
    )
    text = text.replace(
        'shadow2DProj( shadowTexture0, gl_TexCoord[shadowTextureUnit0] ).r',
        'step(gl_TexCoord[shadowTextureUnit0].z / gl_TexCoord[shadowTextureUnit0].w, texture2D(shadowTexture0, gl_TexCoord[shadowTextureUnit0].xy / gl_TexCoord[shadowTextureUnit0].w).r)',
    )
    text = text.replace(
        'shadow2DProj( shadowTexture1, gl_TexCoord[shadowTextureUnit1] ).r',
        'step(gl_TexCoord[shadowTextureUnit1].z / gl_TexCoord[shadowTextureUnit1].w, texture2D(shadowTexture1, gl_TexCoord[shadowTextureUnit1].xy / gl_TexCoord[shadowTextureUnit1].w).r)',
    )

    text = replace_once(
        text,
        '''        _texture->setInternalFormat(GL_DEPTH_COMPONENT);
        _texture->setShadowComparison(true);
        _texture->setShadowTextureMode(osg::Texture2D::LUMINANCE);
    }

    _texture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::LINEAR);
    _texture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::LINEAR);''',
        '''        _texture->setInternalFormat(GL_DEPTH_COMPONENT);
#ifdef ANDROID
        // OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE
        // Keep the depth texture in raw-sampling mode; receiver shaders perform
        // the LEQUAL comparison explicitly. NEAREST avoids interpolating depth.
        _texture->setShadowComparison(false);
#else
        _texture->setShadowComparison(true);
        _texture->setShadowTextureMode(osg::Texture2D::LUMINANCE);
#endif
    }

#ifdef ANDROID
    _texture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::NEAREST);
    _texture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::NEAREST);
#else
    _texture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::LINEAR);
    _texture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::LINEAR);
#endif''',
        'mwshadowtechnique/raw depth texture sampling',
    )

    text = replace_once(
        text,
        '''        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::NEAREST);
        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::NEAREST);
        _fallbackShadowMapTexture->setShadowComparison(true);
        _fallbackShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);''',
        '''        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::NEAREST);
        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::NEAREST);
#ifdef ANDROID
        _fallbackShadowMapTexture->setShadowComparison(false);
#else
        _fallbackShadowMapTexture->setShadowComparison(true);
        _fallbackShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);
#endif''',
        'mwshadowtechnique/fallback shadow texture raw sampling',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android GLES2 raw shadow texture mode to MWShadowTechnique.')

# Depth clamp is a separate compatibility requirement and must be applied even
# if a source tree already carries the manual-compare marker.
text = mwshadowtechnique.read_text(encoding='utf-8')
if native_clip_marker not in text:
    text = replace_once(
        text,
        '''    osg::ref_ptr<osg::Depth> depth = new osg::Depth;
    depth->setWriteMask(true);
    osg::ref_ptr<osg::ClipControl> clipcontrol = new osg::ClipControl(osg::ClipControl::LOWER_LEFT, osg::ClipControl::NEGATIVE_ONE_TO_ONE);
    _shadowCastingStateSet->setAttribute(clipcontrol, osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE);
    _shadowCastingStateSet->setAttribute(depth, osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE);
    _shadowCastingStateSet->setMode(GL_DEPTH_CLAMP, osg::StateAttribute::ON);''',
        '''    osg::ref_ptr<osg::Depth> depth = new osg::Depth;
    depth->setWriteMask(true);
#ifndef ANDROID
    osg::ref_ptr<osg::ClipControl> clipcontrol = new osg::ClipControl(osg::ClipControl::LOWER_LEFT, osg::ClipControl::NEGATIVE_ONE_TO_ONE);
    _shadowCastingStateSet->setAttribute(clipcontrol, osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE);
#endif
    _shadowCastingStateSet->setAttribute(depth, osg::StateAttribute::ON|osg::StateAttribute::OVERRIDE);
#ifndef ANDROID
    _shadowCastingStateSet->setMode(GL_DEPTH_CLAMP, osg::StateAttribute::ON);
#else
    // OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING
    // Android/GL4ES intentionally uses normal GLES2 clip-volume clipping;
    // do not emulate GL_DEPTH_CLAMP by clamping caster vertices in the shader.
#endif''',
        'mwshadowtechnique/desktop-only clip-control depth-clamp state',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Disabled desktop-only shadow clip-control/depth-clamp state on Android.')

text = shadow_manager.read_text(encoding='utf-8')
if shadow_compare_marker not in text:
    text = replace_once(
        text,
        '''        osg::ref_ptr<osg::Image> fakeShadowMapImage = new osg::Image();
        fakeShadowMapImage->allocateImage(1, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT);
        *(float*)fakeShadowMapImage->data() = std::numeric_limits<float>::infinity();
        osg::ref_ptr<osg::Texture> fakeShadowMapTexture = new osg::Texture2D(fakeShadowMapImage);''',
        '''        osg::ref_ptr<osg::Image> fakeShadowMapImage = new osg::Image();
#ifdef ANDROID
        // OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE
        // Raw sampler2D receivers need a white texel for an always-unshadowed
        // fallback and must not rely on desktop depth-compare texture state.
        fakeShadowMapImage->allocateImage(1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE);
        fakeShadowMapImage->data()[0] = 0xFF;
        fakeShadowMapImage->data()[1] = 0xFF;
        fakeShadowMapImage->data()[2] = 0xFF;
        fakeShadowMapImage->data()[3] = 0xFF;
#else
        fakeShadowMapImage->allocateImage(1, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT);
        *(float*)fakeShadowMapImage->data() = std::numeric_limits<float>::infinity();
#endif
        osg::ref_ptr<osg::Texture> fakeShadowMapTexture = new osg::Texture2D(fakeShadowMapImage);''',
        'shadow.cpp/GLES2-safe fake shadow image',
    )
    text = replace_once(
        text,
        '''        fakeShadowMapTexture->setShadowComparison(true);
        fakeShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);''',
        '''#ifdef ANDROID
        fakeShadowMapTexture->setShadowComparison(false);
#else
        fakeShadowMapTexture->setShadowComparison(true);
        fakeShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);
#endif''',
        'shadow.cpp/fake shadow texture comparison mode',
    )
    shadow_manager.write_text(text, encoding='utf-8', newline='\n')
    print('Applied GLES2-safe white fallback shadow texture.')

# ---------------------------------------------------------------------------
# Patch 12c: Android orthographic shadow projection.
# OpenMW 0.51 defaults to the camera/light-angle-dependent LiSPSM perspective
# path. On GL4ES/GLES2 keep the already proven one-map configuration but avoid
# that projection path; this also makes perspectiveShadowMaps=0 naturally.
# ---------------------------------------------------------------------------
projection_marker = 'OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP'
text = shadow_manager.read_text(encoding='utf-8')
if projection_marker not in text:
    text = replace_once(
        text,
        '        mShadowSettings->setMultipleShadowMapHint(osgShadow::ShadowSettings::CASCADED);\n',
        '''        mShadowSettings->setMultipleShadowMapHint(osgShadow::ShadowSettings::CASCADED);
#ifdef ANDROID
        // OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP
        // GL4ES/GLES2 stability: avoid the view/light-angle-dependent LiSPSM
        // perspective projection. Preserve the existing single map, distance,
        // resolution and fade settings; only the shadow projection changes.
        mShadowSettings->setShadowMapProjectionHint(osgShadow::ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP);
#endif
''',
        'shadow.cpp/Android orthographic shadow projection',
    )
    shadow_manager.write_text(text, encoding='utf-8', newline='\n')
    print('Forced orthographic shadow projection on Android/GL4ES.')
else:
    print('Android orthographic shadow projection is already applied.')

# ---------------------------------------------------------------------------
# Patch 12e: stable camera-independent basis for Android orthographic sun maps.
# ---------------------------------------------------------------------------
stable_ortho_basis_marker = 'OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS'
text = mwshadowtechnique.read_text(encoding='utf-8')
if stable_ortho_basis_marker not in text:
    text = replace_once(
        text,
        '''    double dotProduct_v = positionedLight.lightDir * frustum.frustumCenterLine;
    double gamma_v = acos(dotProduct_v);
    if (gamma_v<osg::DegreesToRadians(settings->getPerspectiveShadowMapCutOffAngle()) || gamma_v>osg::DegreesToRadians(180.0-settings->getPerspectiveShadowMapCutOffAngle()))
    {
        OSG_INFO<<"View direction and Light direction below tolerance"<<std::endl;
        osg::Vec3d viewSide = osg::Matrixd::transform3x3(frustum.modelViewMatrix, osg::Vec3d(1.0,0.0,0.0));
        lightSide = positionedLight.lightDir ^ (viewSide ^ positionedLight.lightDir);
        lightSide.normalize();
    }
    else
    {
        lightSide = positionedLight.lightDir ^ frustum.frustumCenterLine;
        lightSide.normalize();
    }

    osg::Vec3d lightUp = lightSide ^ positionedLight.lightDir;
''',
        '''#ifdef ANDROID
    if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
        && positionedLight.directionalLight)
    {
        // OPENMW_ANDROID_051_STABLE_ORTHO_SHADOW_BASIS
        // Keep the sun direction unchanged, but orient the orthographic shadow
        // camera from a stable world axis instead of the main camera view.
        // This avoids the lightDir x viewDir singularity/fallback flip when the
        // player looks close to the sunlight direction.
        const osg::Vec3d stableAxis = fabs(positionedLight.lightDir.z()) < 0.95
            ? osg::Vec3d(0.0, 0.0, 1.0)
            : osg::Vec3d(0.0, 1.0, 0.0);
        lightSide = positionedLight.lightDir ^ stableAxis;
        if (lightSide.length2() < 1e-12)
            lightSide.set(1.0, 0.0, 0.0);
        else
            lightSide.normalize();
    }
    else
#endif
    {
        double dotProduct_v = positionedLight.lightDir * frustum.frustumCenterLine;
        double gamma_v = acos(dotProduct_v);
        if (gamma_v<osg::DegreesToRadians(settings->getPerspectiveShadowMapCutOffAngle()) || gamma_v>osg::DegreesToRadians(180.0-settings->getPerspectiveShadowMapCutOffAngle()))
        {
            OSG_INFO<<"View direction and Light direction below tolerance"<<std::endl;
            osg::Vec3d viewSide = osg::Matrixd::transform3x3(frustum.modelViewMatrix, osg::Vec3d(1.0,0.0,0.0));
            lightSide = positionedLight.lightDir ^ (viewSide ^ positionedLight.lightDir);
            lightSide.normalize();
        }
        else
        {
            lightSide = positionedLight.lightDir ^ frustum.frustumCenterLine;
            lightSide.normalize();
        }
    }

    osg::Vec3d lightUp = lightSide ^ positionedLight.lightDir;
    lightUp.normalize();
''',
        'mwshadowtechnique.cpp/stable Android orthographic shadow basis',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied stable Android orthographic shadow-camera basis.')
else:
    print('Stable Android orthographic shadow-camera basis is already applied.')

# ---------------------------------------------------------------------------
# Patch 12g: keep Android orthographic directional shadow projection out of
# the final main-camera-frustum crop stage. Earlier caster-extents tightening
# remains enabled intentionally.
# ---------------------------------------------------------------------------
no_main_frustum_crop_marker = 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP'
text = mwshadowtechnique.read_text(encoding='utf-8')
if no_main_frustum_crop_marker not in text:
    text = replace_once(
        text,
        '''            if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
            {
                cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                for (const auto& plane : extraPlanes)
                    local_polytope.getPlaneList().push_back(plane);
                local_polytope.setupMask();
            }
            else
                cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
''',
        '''            if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
            {
                cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                for (const auto& plane : extraPlanes)
                    local_polytope.getPlaneList().push_back(plane);
                local_polytope.setupMask();
            }
            else
            {
#ifdef ANDROID
                if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                    && pl.directionalLight)
                {
                    // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                    // Diagnostic A/B: keep the already-computed orthographic
                    // light-space projection intact instead of re-cropping it
                    // to the current main-camera frustum. This removes one
                    // remaining view-dependent shadow-camera transform while
                    // leaving ComputeLightSpaceBounds tightening untouched.
                }
                else
#endif
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
''',
        'mwshadowtechnique.cpp/Android orthographic no-main-frustum-crop',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android orthographic no-main-frustum-crop A/B.')
else:
    print('Android orthographic no-main-frustum-crop A/B is already applied.')

# ---------------------------------------------------------------------------
# Patch 12h: disable caster-extents projection tightening for Android
# orthographic directional shadows. Patch 12g remains separate and active.
# ---------------------------------------------------------------------------
no_caster_bounds_tightening_marker = 'OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING'
text = mwshadowtechnique.read_text(encoding='utf-8')
if no_caster_bounds_tightening_marker not in text:
    text = replace_once(
        text,
        '''        if (/*numShadowMapsPerLight>1 &&*/ (_shadowedScene->getCastsShadowTraversalMask() & _worldMask) == 0)
''',
        '''        bool tightenProjectionToCasterBounds
            = (_shadowedScene->getCastsShadowTraversalMask() & _worldMask) == 0;
#ifdef ANDROID
        if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
            && pl.directionalLight)
        {
            // OPENMW_ANDROID_051_ORTHO_NO_CASTER_BOUNDS_TIGHTENING
            // Diagnostic A/B: do not rescale the orthographic shadow
            // projection to currently visible caster extents.
            tightenProjectionToCasterBounds = false;
        }
#endif
        if (tightenProjectionToCasterBounds)
''',
        'mwshadowtechnique.cpp/Android orthographic no-caster-bounds-tightening',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android orthographic no-caster-bounds-tightening A/B.')
else:
    print('Android orthographic no-caster-bounds-tightening A/B is already applied.')

# ---------------------------------------------------------------------------
# Patch 12i: fixed eye-anchored orthographic shadow volume for Android.
# ---------------------------------------------------------------------------
fixed_eye_volume_marker = 'OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME'
text = mwshadowtechnique.read_text(encoding='utf-8')
if fixed_eye_volume_marker not in text:
    text = replace_once(
        text,
        '''    if (positionedLight.directionalLight)
    {
        double xMin=0.0, xMax=0.0;
''',
        '''    if (positionedLight.directionalLight)
    {
#ifdef ANDROID
        if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP)
        {
            // OPENMW_ANDROID_051_ORTHO_FIXED_EYE_VOLUME
            // Diagnostic A/B: the Android shadow-camera volume follows only
            // the camera position and sunlight direction, never the current
            // look direction/FOV/frustum corners. This intentionally trades
            // texel efficiency for a rotation-invariant shadow projection.
            const double halfExtent = osg::maximum<double>(512.0, settings->getMaximumShadowMapDistance());
            const double depthExtent = halfExtent * 2.0;
            const osg::Vec3d anchor = frustum.eye;

            projectionMatrix.makeOrtho(
                -halfExtent, halfExtent,
                -halfExtent, halfExtent,
                0.0, depthExtent * 2.0);
            viewMatrix.makeLookAt(
                anchor - positionedLight.lightDir * depthExtent,
                anchor + positionedLight.lightDir * depthExtent,
                lightUp);
            return true;
        }
#endif
        double xMin=0.0, xMax=0.0;
''',
        'mwshadowtechnique.cpp/fixed eye-anchored orthographic shadow volume',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Applied fixed eye-anchored Android orthographic shadow volume A/B.')
else:
    print('Fixed eye-anchored Android orthographic shadow volume A/B is already applied.')

# ---------------------------------------------------------------------------
# Patch 12j: correct Patch 12g for the actually active CASCADED one-map path.
# setupShadowSettings() sets CASCADED unconditionally, so bypass the final
# main-frustum crop for Android orthographic directional shadows regardless of
# the multiple-shadow-map hint.
# ---------------------------------------------------------------------------
all_path_crop_bypass_marker = 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS'
text = mwshadowtechnique.read_text(encoding='utf-8')
if all_path_crop_bypass_marker not in text:
    text = replace_once(
        text,
        '''            if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
            {
                cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                for (const auto& plane : extraPlanes)
                    local_polytope.getPlaneList().push_back(plane);
                local_polytope.setupMask();
            }
            else
            {
#ifdef ANDROID
                if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                    && pl.directionalLight)
                {
                    // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                    // Diagnostic A/B: keep the already-computed orthographic
                    // light-space projection intact instead of re-cropping it
                    // to the current main-camera frustum. This removes one
                    // remaining view-dependent shadow-camera transform while
                    // leaving ComputeLightSpaceBounds tightening untouched.
                }
                else
#endif
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
''',
        '''            bool bypassMainFrustumCrop = false;
#ifdef ANDROID
            if (settings->getShadowMapProjectionHint() == ShadowSettings::ORTHOGRAPHIC_SHADOW_MAP
                && pl.directionalLight)
            {
                // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP
                // OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS
                // Patch 12j correction: setupShadowSettings() uses CASCADED
                // even with exactly one shadow map, so the previous Patch 12g
                // else-only bypass never affected our active path.
                bypassMainFrustumCrop = true;
            }
#endif
            if (!bypassMainFrustumCrop)
            {
                if (settings->getMultipleShadowMapHint() == ShadowSettings::CASCADED)
                {
                    cropShadowCameraToMainFrustum(frustum, camera, cascaseNear, cascadeFar, extraPlanes);
                    for (const auto& plane : extraPlanes)
                        local_polytope.getPlaneList().push_back(plane);
                    local_polytope.setupMask();
                }
                else
                    cropShadowCameraToMainFrustum(frustum, camera, reducedNear, reducedFar, extraPlanes);
            }
''',
        'mwshadowtechnique.cpp/Android all-path no-main-frustum-crop correction',
    )
    mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')
    print('Corrected Android orthographic main-frustum crop bypass for CASCADED one-map path.')
else:
    print('Android all-path main-frustum crop bypass correction is already applied.')


# ---------------------------------------------------------------------------
# Patch 26 / Gate H2g: Android CPU scene-ray sun occlusion for OMWFX.
# ---------------------------------------------------------------------------
cpu_sun_occ_marker = 'OPENMW_ANDROID_051_CPU_SUN_OCCLUSION'

text = fx_stateupdater_hpp.read_text(encoding='utf-8')
if cpu_sun_occ_marker not in text:
    text = replace_once(text,
        '''        void setSunVis(float vis) { mData.get<SunVis>() = vis; }\n''',
        '''        void setSunVis(float vis) { mData.get<SunVis>() = vis; }\n\n#ifdef ANDROID\n        // OPENMW_ANDROID_051_CPU_SUN_OCCLUSION\n        void setSunOcclusion(float visibility) { mData.get<SunOcclusion>() = visibility; }\n#endif\n''',
        'fx/stateupdater.hpp/sun-occlusion setter')
    text = replace_once(text,
        '''        struct SunVis : Std140::Float\n        {\n            static constexpr std::string_view sName = "sunVis";\n        };\n\n        struct WaterHeight : Std140::Float\n''',
        '''        struct SunVis : Std140::Float\n        {\n            static constexpr std::string_view sName = "sunVis";\n        };\n\n#ifdef ANDROID\n        struct SunOcclusion : Std140::Float\n        {\n            static constexpr std::string_view sName = "sunOcclusion";\n        };\n#endif\n\n        struct WaterHeight : Std140::Float\n''',
        'fx/stateupdater.hpp/sun-occlusion field')
    text = replace_once(text,
        '''            RcpResolution, FogNear, FogFar, Near, Far, Fov, GameHour, SunVis, WaterHeight, IsWaterEnabled,\n            SimulationTime, DeltaSimulationTime, FrameNumber, WindSpeed, WeatherTransition, WeatherID, NextWeatherID,\n''',
        '''            RcpResolution, FogNear, FogFar, Near, Far, Fov, GameHour, SunVis,\n#ifdef ANDROID\n            SunOcclusion,\n#endif\n            WaterHeight, IsWaterEnabled, SimulationTime, DeltaSimulationTime, FrameNumber, WindSpeed, WeatherTransition,\n            WeatherID, NextWeatherID,\n''',
        'fx/stateupdater.hpp/sun-occlusion UBO layout')
    fx_stateupdater_hpp.write_text(text, encoding='utf-8', newline='\n')
    print('Added Android OMWFX sunOcclusion state field.')
else:
    print('Android OMWFX sunOcclusion field already applied.')

text = renderingmanager_hpp.read_text(encoding='utf-8')
if cpu_sun_occ_marker not in text:
    text = replace_once(text,
        '''        void updateTextureFiltering();\n        void updateAmbient();\n        void setFogColor(const osg::Vec4f& color);\n''',
        '''        void updateTextureFiltering();\n        void updateAmbient();\n        void setFogColor(const osg::Vec4f& color);\n#ifdef ANDROID\n        // OPENMW_ANDROID_051_CPU_SUN_OCCLUSION\n        void updateAndroidSunOcclusion(float dt);\n#endif\n''',
        'renderingmanager.hpp/helper declaration')
    text = replace_once(text,
        '''        bool mUpdateProjectionMatrix = false;\n        bool mNight = false;\n        osg::Vec2f mProjectionOffset;\n''',
        '''        bool mUpdateProjectionMatrix = false;\n        bool mNight = false;\n#ifdef ANDROID\n        // OPENMW_ANDROID_051_CPU_SUN_OCCLUSION\n        osg::Vec3f mAndroidSunDiscDirection{ 0.f, 0.f, 1.f };\n        float mAndroidSunOcclusion = 1.f;\n        float mAndroidSunOcclusionTarget = 1.f;\n        float mAndroidSunOcclusionRayTimer = 0.f;\n#endif\n        osg::Vec2f mProjectionOffset;\n''',
        'renderingmanager.hpp/state')
    renderingmanager_hpp.write_text(text, encoding='utf-8', newline='\n')
    print('Added Android RenderingManager sun-occlusion state.')
else:
    print('Android RenderingManager sun-occlusion state already applied.')

text = renderingmanager.read_text(encoding='utf-8')
if cpu_sun_occ_marker not in text:
    text = replace_once(text,
        '''        mPostProcessor = new PostProcessor(*this, viewer, mRootNode, resourceSystem->getVFS());\n        resourceSystem->getSceneManager()->setOpaqueDepthTex(\n''',
        '''        mPostProcessor = new PostProcessor(*this, viewer, mRootNode, resourceSystem->getVFS());\n#ifdef ANDROID\n        // OPENMW_ANDROID_051_CPU_SUN_OCCLUSION\n        mPostProcessor->getStateUpdater()->setSunOcclusion(1.f);\n#endif\n        resourceSystem->getSceneManager()->setOpaqueDepthTex(\n''',
        'renderingmanager.cpp/default visibility')
    text = replace_once(text,
        '''        // This is based on the exterior sun orbit and won't make sense for interiors, see WeatherManager::update\n        position.z() = 400.f - std::abs(position.x());\n\n        // The sun is not always synchronized with the sunlight because reasons\n''',
        '''        // This is based on the exterior sun orbit and won't make sense for interiors, see WeatherManager::update\n        position.z() = 400.f - std::abs(position.x());\n\n#ifdef ANDROID\n        // OPENMW_ANDROID_051_CPU_SUN_OCCLUSION\n        // Sun::setDirection() normalizes this exact visual-disc direction.\n        mAndroidSunDiscDirection = position;\n        if (mAndroidSunDiscDirection.length2() > 0.000001f)\n            mAndroidSunDiscDirection.normalize();\n#endif\n\n        // The sun is not always synchronized with the sunlight because reasons\n''',
        'renderingmanager.cpp/visual sun direction')
    text = replace_once(text,
        '''    SkyManager* RenderingManager::getSkyManager()\n    {\n        return mSky.get();\n    }\n\n    void RenderingManager::update(float dt, bool paused)\n''',
        '''    SkyManager* RenderingManager::getSkyManager()\n    {\n        return mSky.get();\n    }\n\n#ifdef ANDROID\n    void RenderingManager::updateAndroidSunOcclusion(float dt)\n    {\n        // OPENMW_ANDROID_051_CPU_SUN_OCCLUSION\n        // Rate-limit the expensive scene-graph intersection to 20 Hz, then\n        // smooth the scalar each rendered frame. castRay() already excludes\n        // Sky/Effects/Water/Groundcover while retaining world blockers.\n        const float safeDt = std::max(0.f, dt);\n        mAndroidSunOcclusionRayTimer -= safeDt;\n\n        const auto& postProcessingChain = Settings::postProcessing().mChain.get();\n        const bool useAndroidSunOcclusion = Settings::postProcessing().mEnabled\n            && std::find(postProcessingChain.begin(), postProcessingChain.end(), "lensflare_android_051_rayocc")\n                != postProcessingChain.end();\n\n        if (useAndroidSunOcclusion && mAndroidSunOcclusionRayTimer <= 0.f\n            && mAndroidSunDiscDirection.length2() > 0.5f)\n        {\n            mAndroidSunOcclusionRayTimer = 0.05f;\n\n            const osg::Vec3d& cameraPos = mCamera->getPosition();\n            osg::Vec3f origin(static_cast<float>(cameraPos.x()), static_cast<float>(cameraPos.y()),\n                static_cast<float>(cameraPos.z()));\n            origin += mAndroidSunDiscDirection * 4.f;\n\n            const float rayDistance = std::max(mViewDistance, 1000.f);\n            const osg::Vec3f dest = origin + mAndroidSunDiscDirection * rayDistance;\n            const RayResult hit = castRay(origin, dest, true, false);\n\n            mAndroidSunOcclusionTarget = hit.mHit ? 0.f : 1.f;\n        }\n        else if (!useAndroidSunOcclusion)\n            mAndroidSunOcclusionTarget = 1.f;\n\n        const float responseSpeed = mAndroidSunOcclusionTarget < mAndroidSunOcclusion ? 18.f : 10.f;\n        const float response = std::min(1.f, safeDt * responseSpeed);\n        mAndroidSunOcclusion += (mAndroidSunOcclusionTarget - mAndroidSunOcclusion) * response;\n        mAndroidSunOcclusion = std::max(0.f, std::min(1.f, mAndroidSunOcclusion));\n        mPostProcessor->getStateUpdater()->setSunOcclusion(mAndroidSunOcclusion);\n    }\n#endif\n\n    void RenderingManager::update(float dt, bool paused)\n''',
        'renderingmanager.cpp/CPU ray helper')
    text = replace_once(text,
        '''        mCamera->update(dt, paused);\n\n        bool isUnderwater = mWater->isUnderwater(mCamera->getPosition());\n''',
        '''        mCamera->update(dt, paused);\n#ifdef ANDROID\n        updateAndroidSunOcclusion(dt);\n#endif\n\n        bool isUnderwater = mWater->isUnderwater(mCamera->getPosition());\n''',
        'renderingmanager.cpp/update order')
    renderingmanager.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android CPU scene-ray sun occlusion.')
else:
    print('Android CPU scene-ray sun occlusion already applied.')

# ---------------------------------------------------------------------------
# Release logging cleanup.
#
# Migrate already-patched source trees as well as fresh 0.51 source trees.
# This deliberately changes logging only; renderer calculations, settings and
# update ordering remain untouched.
# ---------------------------------------------------------------------------
release_log_marker = 'OpenMW 0.51 Android renderer:'

text = postprocessor.read_text(encoding='utf-8')
legacy_pp_pair = '''        Log(Debug::Info) << "OpenMW 0.51 Android Gate G PP init: " << mWidth << "x" << mHeight;
        Log(Debug::Info) << "OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding";'''
release_pp_line = '''        Log(Debug::Info) << "OpenMW 0.51 Android renderer: " << mWidth << "x" << mHeight
                         << ", Tex_Depth scene binding";'''
if legacy_pp_pair in text:
    text = text.replace(legacy_pp_pair, release_pp_line, 1)
elif 'OpenMW 0.51 Android Gate G PP init:' in text:
    text = text.replace(
        '        Log(Debug::Info) << "OpenMW 0.51 Android Gate G PP init: " << mWidth << "x" << mHeight;',
        release_pp_line,
        1,
    )
text = text.replace(
    '        Log(Debug::Info) << "OpenMW 0.51 Android OMWFX depth: Tex_Depth direct scene binding";\n',
    '',
    1,
)
postprocessor.write_text(text, encoding='utf-8', newline='\n')

text = mwshadowtechnique.read_text(encoding='utf-8')
text = text.replace(
    '        OSG_NOTICE << "Android GLES2 manual shadow comparison enabled" << std::endl;\n',
    '',
)
mwshadowtechnique.write_text(text, encoding='utf-8', newline='\n')

text = renderingmanager_hpp.read_text(encoding='utf-8')
text = text.replace('        int mAndroidSunOcclusionLastLoggedState = -1;\n', '', 1)
renderingmanager_hpp.write_text(text, encoding='utf-8', newline='\n')

text = renderingmanager.read_text(encoding='utf-8')
legacy_sun_log = '''            const int state = hit.mHit ? 1 : 0;
            if (state != mAndroidSunOcclusionLastLoggedState)
            {
                Log(Debug::Info) << "OpenMW 0.51 Android sun-occlusion ray: "
                                 << (hit.mHit ? "BLOCKED" : "CLEAR")
                                 << (hit.mHit ? " ratio=" + std::to_string(hit.mRatio) : "");
                mAndroidSunOcclusionLastLoggedState = state;
            }
'''
text = text.replace(legacy_sun_log, '', 1)
renderingmanager.write_text(text, encoding='utf-8', newline='\n')

print('Applied OpenMW 0.51 Android release logging cleanup.')

# Final structural verification.
engine_text = engine.read_text(encoding='utf-8')
android_text = androidmain.read_text(encoding='utf-8')
loading_text = loading.read_text(encoding='utf-8')
windowmanager_text = windowmanager.read_text(encoding='utf-8')
nifloader_text = nifloader.read_text(encoding='utf-8')
stateupdater_text = stateupdater.read_text(encoding='utf-8')
objects_frag_text = objects_frag.read_text(encoding='utf-8')
fog_glsl_text = fog_glsl.read_text(encoding='utf-8')
shadow_fragment_text = shadow_fragment.read_text(encoding='utf-8')
shadow_casting_text = shadow_casting.read_text(encoding='utf-8')
mwshadowtechnique_text = mwshadowtechnique.read_text(encoding='utf-8')
shadow_manager_text = shadow_manager.read_text(encoding='utf-8')
postprocessor_text = postprocessor.read_text(encoding='utf-8')
postprocessor_hpp_text = postprocessor_hpp.read_text(encoding='utf-8')
renderingmanager_text = renderingmanager.read_text(encoding='utf-8')
renderingmanager_hpp_text = renderingmanager_hpp.read_text(encoding='utf-8')
fx_stateupdater_hpp_text = fx_stateupdater_hpp.read_text(encoding='utf-8')
water_cpp_text = water_cpp.read_text(encoding='utf-8')
water_frag_text = water_frag.read_text(encoding='utf-8')
if fog_diag_marker in nifloader_text:
    raise SystemExit('OpenMW 0.51 Patch-6 fog diagnostic was not removed')
for marker, body in (
    (RUNTIME_MARKER, engine_text),
    (RUNTIME_MARKER, android_text),
    (loading_marker, loading_text),
    (cursor_marker, windowmanager_text),
    (fog_uniform_marker, stateupdater_text),
    (object_fog_marker, objects_frag_text),
    (object_fog_marker, fog_glsl_text),
    (additive_fog_marker, objects_frag_text),
    (shadow_compare_marker, shadow_fragment_text),
    (shadow_compare_marker, mwshadowtechnique_text),
    (shadow_compare_marker, shadow_manager_text),
    ('OPENMW_ANDROID_051_ORTHOGRAPHIC_SHADOW_MAP', shadow_manager_text),
    (native_clip_marker, shadow_casting_text),
    (native_clip_marker, mwshadowtechnique_text),
    (pp_init_marker, postprocessor_text),
    (pp_init_marker, postprocessor_hpp_text),
    (pp_scene_depth_marker, postprocessor_text),
    (cpu_sun_occ_marker, renderingmanager_text),
    (cpu_sun_occ_marker, renderingmanager_hpp_text),
    (cpu_sun_occ_marker, fx_stateupdater_hpp_text),
    (wetworld_water_marker, water_cpp_text),
    (wetworld_water_marker, water_frag_text),
):
    if marker not in body:
        raise SystemExit(f'OpenMW 0.51 Android runtime verification failed: missing {marker}')

for path, replacements in shader_replacements.items():
    body = path.read_text(encoding='utf-8')
    for old, new in replacements:
        if old in body or new not in body:
            raise SystemExit(f'OpenMW 0.51 GL4ES initializer verification failed: {path}')

for path, replacements in normal_transform_replacements.items():
    body = path.read_text(encoding='utf-8')
    for old, new in replacements:
        if old in body or new not in body:
            raise SystemExit(f'OpenMW 0.51 GL4ES normal-transform verification failed: {path}')

if '#define ADDITIVE_BLENDING' in objects_frag_text:
    raise SystemExit('OpenMW 0.51 Patch-11 additive fog compatibility was lost')
if 'uniform sampler2DShadow' in shadow_fragment_text or 'shadow2DProj(' in shadow_fragment_text:
    raise SystemExit('OpenMW 0.51 GLES2 shadow receiver still uses unsupported shadow samplers')
if 'sampler2DShadow' in mwshadowtechnique_text or 'shadow2DProj(' in mwshadowtechnique_text:
    raise SystemExit('OpenMW 0.51 MWShadowTechnique fallback shaders still use unsupported shadow samplers')
if 'gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);' in shadow_casting_text:
    raise SystemExit('OpenMW 0.51 Android shadow caster still contains per-vertex Z clamp emulation')

if stable_ortho_basis_marker not in mwshadowtechnique_text:
    raise SystemExit('OpenMW 0.51 Android stable orthographic shadow basis is missing')

if no_main_frustum_crop_marker not in mwshadowtechnique.read_text(encoding='utf-8'):
    raise SystemExit('OpenMW 0.51 Android orthographic no-main-frustum-crop marker is missing')

if no_caster_bounds_tightening_marker not in mwshadowtechnique.read_text(encoding='utf-8'):
    raise SystemExit('OpenMW 0.51 Android orthographic no-caster-bounds-tightening marker is missing')

if 'OPENMW_ANDROID_051_ORTHO_NO_MAIN_FRUSTUM_CROP_ALL_PATHS' not in mwshadowtechnique.read_text(encoding='utf-8'):
    raise SystemExit('OpenMW 0.51 Android all-path main-frustum-crop bypass correction is missing')

if 'setSunOcclusion(float visibility)' not in fx_stateupdater_hpp_text or 'sName = "sunOcclusion"' not in fx_stateupdater_hpp_text:
    raise SystemExit('OpenMW 0.51 Android OMWFX sunOcclusion field is incomplete')
if 'const RayResult hit = castRay(origin, dest, true, false);' not in renderingmanager_text:
    raise SystemExit('OpenMW 0.51 Android CPU sun-occlusion scene ray is missing')
if 'lensflare_android_051_rayocc' not in renderingmanager_text or 'mChain.get()' not in renderingmanager_text:
    raise SystemExit('OpenMW 0.51 Android CPU sun-occlusion chain gate is missing')
if 'OpenMW 0.51 Android sun-occlusion ray:' in renderingmanager_text or 'mAndroidSunOcclusionLastLoggedState' in renderingmanager_hpp_text:
    raise SystemExit('OpenMW 0.51 Android CPU sun-occlusion diagnostic logging was not removed')
if 'setTextureDepth(getTexture(Tex_Depth, frameId))' not in postprocessor_text:
    raise SystemExit('OpenMW 0.51 Android direct OMWFX scene-depth binding is missing')
if release_log_marker not in postprocessor_text:
    raise SystemExit('OpenMW 0.51 Android release renderer marker is missing')
if 'Gate G PP init' in postprocessor_text or 'OMWFX depth: Tex_Depth direct scene binding' in postprocessor_text:
    raise SystemExit('OpenMW 0.51 Android legacy post-processing diagnostics were not removed')
if 'Android GLES2 manual shadow comparison enabled' in mwshadowtechnique_text:
    raise SystemExit('OpenMW 0.51 Android repetitive shadow diagnostic was not removed')
if '#include <osg/BlendFunc>' not in water_cpp_text:
    raise SystemExit('OpenMW 0.51 Android WetWorld BlendFunc include is missing')
if water_cpp_text.count('osg::BlendFunc::ZERO, osg::BlendFunc::ZERO') < 2:
    raise SystemExit('OpenMW 0.51 Android WetWorld water-alpha blend routes are incomplete')
if 'defineMap["wetWorldWaterMask"] = "1";' not in water_cpp_text:
    raise SystemExit('OpenMW 0.51 Android WetWorld shader define is missing')
if '#if @wetWorldWaterMask' not in water_frag_text or 'gl_FragData[0].a = 0.0;' not in water_frag_text:
    raise SystemExit('OpenMW 0.51 Android WetWorld water.frag alpha marker is incomplete')
if 'rainCombined(position.xy/1000.0, waterTimer)' not in water_frag_text:
    raise SystemExit('OpenMW 0.51 Android WetWorld water.frag lost native rain ripples')
camera_update = renderingmanager_text.find('mCamera->update(dt, paused);')
sun_occ_update = renderingmanager_text.find('updateAndroidSunOcclusion(dt);', camera_update)
underwater_update = renderingmanager_text.find('bool isUnderwater =', camera_update)
if not (camera_update >= 0 and camera_update < sun_occ_update < underwater_update):
    raise SystemExit('OpenMW 0.51 Android CPU sun-occlusion update ordering is invalid')

print('OpenMW 0.51 Android runtime baseline patch: READY')
