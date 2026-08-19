#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-android-graphics-followup.py <openmw-source-dir>')

root = Path(sys.argv[1])
windowmanager = root / 'apps' / 'openmw' / 'mwgui' / 'windowmanagerimp.cpp'
settingswindow = root / 'apps' / 'openmw' / 'mwgui' / 'settingswindow.cpp'
nifloader = root / 'components' / 'nifosg' / 'nifloader.cpp'
pingpong_hpp = root / 'apps' / 'openmw' / 'mwrender' / 'pingpongcanvas.hpp'
pingpong_cpp = root / 'apps' / 'openmw' / 'mwrender' / 'pingpongcanvas.cpp'

RESOLUTION_MARKER = 'OPENMW_ANDROID_051_LOGICAL_RENDER_RESOLUTION'
GHOSTFENCE_MARKER = 'OPENMW_ANDROID_051_GHOSTFENCE_STABLE_ORDER'
GAMMA_MARKER = 'OPENMW_ANDROID_051_FINAL_GAMMA'

for path in (windowmanager, settingswindow, nifloader, pingpong_hpp, pingpong_cpp):
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.51 source file: {path}')

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)

# Resolution
text = windowmanager.read_text(encoding='utf-8').replace('\r\n', '\n')
if RESOLUTION_MARKER not in text:
    text = replace_once(
        text,
        '''    void WindowManager::windowResized(int x, int y)
    {
        Settings::video().mResolutionX.set(x);
        Settings::video().mResolutionY.set(y);

        // We only want to process changes to window-size related settings.''',
        '''    void WindowManager::windowResized(int x, int y)
    {
#ifndef ANDROID
        Settings::video().mResolutionX.set(x);
        Settings::video().mResolutionY.set(y);
#else
        // OPENMW_ANDROID_051_LOGICAL_RENDER_RESOLUTION
        // SDL reports the physical Android Surface here. Do not overwrite the
        // launcher-selected logical render size with that physical size.
        (void)x;
        (void)y;
#endif

        // We only want to process changes to window-size related settings.''',
        'windowmanager.cpp/logical render resolution',
    )
    windowmanager.write_text(text, encoding='utf-8', newline='\n')
    print('Preserved launcher-selected logical render resolution across Android Surface resizes.')
else:
    print('Android logical render-resolution preservation is already applied.')

text = settingswindow.read_text(encoding='utf-8').replace('\r\n', '\n')
if RESOLUTION_MARKER not in text:
    text = replace_once(
        text,
        '''        int numDisplayModes = SDL_GetNumDisplayModes(screen);
        std::vector<std::pair<int, int>> resolutions;
        for (int i = 0; i < numDisplayModes; i++)''',
        '''        int numDisplayModes = SDL_GetNumDisplayModes(screen);
        std::vector<std::pair<int, int>> resolutions;
#ifdef ANDROID
        // OPENMW_ANDROID_051_LOGICAL_RENDER_RESOLUTION
        // Launcher render sizes are logical sizes and need not be physical SDL
        // display modes. Put the configured size into the list explicitly.
        const int configuredWidth = Settings::video().mResolutionX;
        const int configuredHeight = Settings::video().mResolutionY;
        if (configuredWidth > 0 && configuredHeight > 0)
            resolutions.emplace_back(configuredWidth, configuredHeight);
#endif
        for (int i = 0; i < numDisplayModes; i++)''',
        'settingswindow.cpp/configured Android resolution',
    )
    settingswindow.write_text(text, encoding='utf-8', newline='\n')
    print('Added the launcher-selected Android render resolution to the in-game list.')
else:
    print('Android in-game logical render-resolution listing is already applied.')

# Ghostfence
text = nifloader.read_text(encoding='utf-8').replace('\r\n', '\n')
if GHOSTFENCE_MARKER not in text:
    text = replace_once(
        text,
        '''            if (specStrength != 1.f)
                node->getOrCreateStateSet()->addUniform(new osg::Uniform("specStrength", specStrength));

            if (!mPushedSorter)''',
        '''            if (specStrength != 1.f)
                node->getOrCreateStateSet()->addUniform(new osg::Uniform("specStrength", specStrength));

#ifdef ANDROID
            // OPENMW_ANDROID_051_GHOSTFENCE_STABLE_ORDER
            // Keep the known vanilla Ghostfence translucent mesh family in a
            // deterministic traversal order. Normalize case explicitly because
            // game data may preserve the original NIF filename casing.
            const std::string androidNifFilename
                = Misc::StringUtils::lowerCase(mFilename.filename().value());
            const bool stableGhostfenceOrder = androidNifFilename.starts_with("ex_gg_fence_")
                || androidNifFilename == "ex_gg_particles_01.nif";
            if (hasSortAlpha && stableGhostfenceOrder)
            {
                setBinTraversal(node->getOrCreateStateSet());
                return;
            }
#endif

            if (!mPushedSorter)''',
        'nifloader.cpp/Ghostfence stable alpha ordering',
    )
    nifloader.write_text(text, encoding='utf-8', newline='\n')
    print('Applied targeted stable alpha ordering to Ghostfence fence/particle meshes.')
else:
    print('Ghostfence stable alpha ordering is already applied.')

# Gamma
text = pingpong_hpp.read_text(encoding='utf-8').replace('\r\n', '\n')
if GAMMA_MARKER not in text:
    text = replace_once(
        text,
        '''        osg::ref_ptr<osg::Program> mFallbackProgram;
        osg::ref_ptr<osg::Program> mMultiviewResolveProgram;
        osg::ref_ptr<osg::StateSet> mFallbackStateSet;
        osg::ref_ptr<osg::StateSet> mMultiviewResolveStateSet;''',
        '''        osg::ref_ptr<osg::Program> mFallbackProgram;
        osg::ref_ptr<osg::Program> mMultiviewResolveProgram;
        osg::ref_ptr<osg::StateSet> mFallbackStateSet;
        osg::ref_ptr<osg::StateSet> mMultiviewResolveStateSet;
#ifdef ANDROID
        // OPENMW_ANDROID_051_FINAL_GAMMA
        osg::ref_ptr<osg::StateSet> mAndroidGammaStateSet;
#endif''',
        'pingpongcanvas.hpp/Android gamma state',
    )
    pingpong_hpp.write_text(text, encoding='utf-8', newline='\n')
    print('Added Android final-gamma state to PingPongCanvas.')
else:
    print('Android final-gamma state is already declared.')

text = pingpong_cpp.read_text(encoding='utf-8').replace('\r\n', '\n')
if GAMMA_MARKER not in text:
    text = replace_once(
        text,
        '''#include <cassert>

#include <components/shader/shadermanager.hpp>''',
        '''#include <cassert>
#include <cstdlib>

#include <osg/Shader>

#include <components/shader/shadermanager.hpp>''',
        'pingpongcanvas.cpp/gamma includes',
    )

    text = replace_once(
        text,
        '''        mFallbackStateSet->setAttributeAndModes(mFallbackProgram);
        mFallbackStateSet->addUniform(new osg::Uniform("lastShader", 0));
        mFallbackStateSet->addUniform(new osg::Uniform("scaling", osg::Vec2f(1, 1)));

        mMultiviewResolveProgram = shaderManager.getProgram("multiview_resolve");''',
        '''        mFallbackStateSet->setAttributeAndModes(mFallbackProgram);
        mFallbackStateSet->addUniform(new osg::Uniform("lastShader", 0));
        mFallbackStateSet->addUniform(new osg::Uniform("scaling", osg::Vec2f(1, 1)));

#ifdef ANDROID
        // OPENMW_ANDROID_051_FINAL_GAMMA
        // OPENMW_GAMMA is supplied by the Android launcher. SDL gamma ramps are
        // ineffective on Android, so gamma is applied once to the final image.
        float androidGamma = 1.f;
        if (const char* value = std::getenv("OPENMW_GAMMA"))
        {
            char* end = nullptr;
            const float parsed = std::strtof(value, &end);
            if (end != value && parsed >= 0.1f && parsed <= 5.f)
                androidGamma = parsed;
        }

        if (androidGamma != 1.f)
        {
            static const char* vertexSource = R"GLSL(#version 120
uniform vec2 scaling;
varying vec2 uv;
void main()
{
    gl_Position = vec4(gl_Vertex.xy, 0.0, 1.0);
    uv = (gl_Position.xy * 0.5 + 0.5) * scaling;
}
)GLSL";

            static const char* fragmentSource = R"GLSL(#version 120
uniform sampler2D lastShader;
uniform float androidGamma;
varying vec2 uv;
void main()
{
    vec4 color = texture2D(lastShader, uv);
    color.rgb = pow(max(color.rgb, vec3(0.0)), vec3(1.0 / androidGamma));
    gl_FragColor = color;
}
)GLSL";

            osg::ref_ptr<osg::Program> gammaProgram = new osg::Program;
            gammaProgram->addShader(new osg::Shader(osg::Shader::VERTEX, vertexSource));
            gammaProgram->addShader(new osg::Shader(osg::Shader::FRAGMENT, fragmentSource));

            mAndroidGammaStateSet = new osg::StateSet;
            mAndroidGammaStateSet->setAttributeAndModes(gammaProgram);
            mAndroidGammaStateSet->addUniform(new osg::Uniform("lastShader", 0));
            mAndroidGammaStateSet->addUniform(new osg::Uniform("scaling", osg::Vec2f(1.f, 1.f)));
            mAndroidGammaStateSet->addUniform(new osg::Uniform("androidGamma", androidGamma));
        }
#endif

        mMultiviewResolveProgram = shaderManager.getProgram("multiview_resolve");''',
        'pingpongcanvas.cpp/create Android gamma program',
    )

    text = replace_once(
        text,
        '''        if (filtered.empty() || !mPostprocessing)
        {
            state.pushStateSet(mFallbackStateSet);''',
        '''        if (filtered.empty() || !mPostprocessing)
        {
#ifdef ANDROID
            if (mAndroidGammaStateSet && !Stereo::getMultiview())
            {
                state.pushStateSet(mAndroidGammaStateSet);
                state.apply();
                state.applyTextureAttribute(0, mTextureScene);
                resolveViewport->apply(state);
                drawGeometry(renderInfo);
                state.popStateSet();
                return;
            }
#endif
            state.pushStateSet(mFallbackStateSet);''',
        'pingpongcanvas.cpp/no-postprocessing gamma resolve',
    )

    text = replace_once(
        text,
        '''        auto buffer = buffers[0];

        int lastDraw = 0;
        int lastShader = 0;''',
        '''        auto buffer = buffers[0];

        int lastDraw = 0;
        int lastShader = 0;
#ifdef ANDROID
        bool androidGammaPending = false;
#endif''',
        'pingpongcanvas.cpp/gamma pending state',
    )

    text = replace_once(
        text,
        '''                if (pass.mRenderTarget)
                {
                    pass.mRenderTarget->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);

                    lastApplied = pass.mRenderTarget->getHandle(state.getContextID());
                }
                else if (pass.mResolve && index == filtered.back())''',
        '''#ifdef ANDROID
                if (mAndroidGammaStateSet && !Stereo::getMultiview() && lastPass && index == filtered.back()
                    && !pass.mRenderTarget)
                {
                    lastDraw = buffer[0];
                    lastShader = buffer[0];
                    mFbos[buffer[0] - GL_COLOR_ATTACHMENT0_EXT]->apply(
                        state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);
                    lastApplied = mFbos[buffer[0] - GL_COLOR_ATTACHMENT0_EXT]->getHandle(cid);
                    androidGammaPending = true;
                }
                else
#endif
                if (pass.mRenderTarget)
                {
                    pass.mRenderTarget->apply(state, osg::FrameBufferObject::DRAW_FRAMEBUFFER);

                    lastApplied = pass.mRenderTarget->getHandle(state.getContextID());
                }
                else if (pass.mResolve && index == filtered.back())''',
        'pingpongcanvas.cpp/divert final pass for gamma',
    )

    text = replace_once(
        text,
        '''        if (Stereo::getMultiview())
        {
            ext->glBindFramebuffer(GL_DRAW_FRAMEBUFFER_EXT, 0);''',
        '''#ifdef ANDROID
        if (androidGammaPending)
        {
            bindDestinationFbo();
            if (!destinationFbo)
                resolveViewport->apply(state);

            state.pushStateSet(mAndroidGammaStateSet);
            state.apply();
            state.applyTextureAttribute(PostProcessor::Unit_LastShader,
                (osg::Texture*)mFbos[lastShader - GL_COLOR_ATTACHMENT0_EXT]
                    ->getAttachment(osg::Camera::COLOR_BUFFER0)
                    .getTexture());
            drawGeometry(renderInfo);
            state.popStateSet();
            state.apply();

            lastApplied = destinationHandle;
        }
#endif

        if (Stereo::getMultiview())
        {
            ext->glBindFramebuffer(GL_DRAW_FRAMEBUFFER_EXT, 0);''',
        'pingpongcanvas.cpp/final Android gamma resolve',
    )

    pingpong_cpp.write_text(text, encoding='utf-8', newline='\n')
    print('Applied Android gamma as the final fullscreen resolve.')
else:
    print('Android final gamma pass is already applied.')

checks = {
    windowmanager: RESOLUTION_MARKER,
    settingswindow: RESOLUTION_MARKER,
    nifloader: GHOSTFENCE_MARKER,
    pingpong_hpp: GAMMA_MARKER,
    pingpong_cpp: GAMMA_MARKER,
}
for path, marker in checks.items():
    if marker not in path.read_text(encoding='utf-8'):
        raise SystemExit(f'{path}: expected marker {marker} is missing')

print('OpenMW 0.51 Android graphics follow-up fixes: READY')
