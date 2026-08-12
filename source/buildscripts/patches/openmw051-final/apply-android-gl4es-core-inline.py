#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-android-gl4es-core-inline.py <openmw-source-dir>')

root = Path(sys.argv[1])
vertex = root / 'files' / 'shaders' / 'lib' / 'core' / 'vertex.h.glsl'
fragment = root / 'files' / 'shaders' / 'lib' / 'core' / 'fragment.h.glsl'
MARKER = 'OPENMW_ANDROID_051_GL4ES_CORE_INLINE'

for path in (vertex, fragment):
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.51 core shader header: {path}')

vertex_pristine = '''@link "lib/core/vertex.glsl" if !@useOVR_multiview
@link "lib/core/vertex_multiview.glsl" if @useOVR_multiview

vec4 modelToClip(vec4 pos);
vec4 modelToView(vec4 pos);
vec4 viewToClip(vec4 pos);
'''
vertex_android = '''// OPENMW_ANDROID_051_GL4ES_CORE_INLINE
// GL4ES/GLES2 compatibility: keep helper implementations in the consuming
// shader instead of linking a helper-only shader object without main().
uniform mat4 projectionMatrix;

vec4 modelToView(vec4 pos)
{
    return gl_ModelViewMatrix * pos;
}

vec4 modelToClip(vec4 pos)
{
    return projectionMatrix * modelToView(pos);
}

vec4 viewToClip(vec4 pos)
{
    return projectionMatrix * pos;
}
'''

fragment_pristine = '''#ifndef OPENMW_FRAGMENT_H_GLSL
#define OPENMW_FRAGMENT_H_GLSL

@link "lib/core/fragment.glsl" if !@useOVR_multiview
@link "lib/core/fragment_multiview.glsl" if @useOVR_multiview

vec4 sampleReflectionMap(vec2 uv);

#if @waterRefraction
vec4 sampleRefractionMap(vec2 uv);
float sampleRefractionDepthMap(vec2 uv);
#endif

vec4 samplerLastShader(vec2 uv);

#if @skyBlending
vec3 sampleSkyColor(vec2 uv);
#endif

vec4 sampleOpaqueDepthTex(vec2 uv);

#endif  // OPENMW_FRAGMENT_H_GLSL
'''
fragment_android = '''#ifndef OPENMW_FRAGMENT_H_GLSL
#define OPENMW_FRAGMENT_H_GLSL

// OPENMW_ANDROID_051_GL4ES_CORE_INLINE
// GL4ES/GLES2 compatibility: inline the helper implementations. The stock
// OpenMW 0.51 helper-link path creates helper-only shader objects which the tested
// Adreno GLES compiler rejects because they contain no main().
uniform sampler2D reflectionMap;

vec4 sampleReflectionMap(vec2 uv)
{
    return texture2D(reflectionMap, uv);
}

#if @waterRefraction
uniform sampler2D refractionMap;
uniform highp sampler2D refractionDepthMap;

vec4 sampleRefractionMap(vec2 uv)
{
    return texture2D(refractionMap, uv);
}

float sampleRefractionDepthMap(vec2 uv)
{
    return texture2D(refractionDepthMap, uv).x;
}
#endif

uniform sampler2D lastShader;

vec4 samplerLastShader(vec2 uv)
{
    return texture2D(lastShader, uv);
}

#if @skyBlending
uniform sampler2D sky;

vec3 sampleSkyColor(vec2 uv)
{
    return texture2D(sky, uv).xyz;
}
#endif

uniform highp sampler2D opaqueDepthTex;

vec4 sampleOpaqueDepthTex(vec2 uv)
{
    return texture2D(opaqueDepthTex, uv);
}

#endif  // OPENMW_FRAGMENT_H_GLSL
'''

def apply_exact(path: Path, pristine: str, android: str) -> None:
    text = path.read_text(encoding='utf-8').replace('\r\n', '\n')
    if MARKER in text:
        if text != android:
            raise SystemExit(f'{path}: Patch-3 marker exists but file differs from expected Android form')
        print(f'{path.relative_to(root)}: GL4ES core inlining already applied')
        return
    if text != pristine:
        raise SystemExit(f'{path}: source does not match exact OpenMW 0.51 Final core header')
    path.write_text(android, encoding='utf-8', newline='\n')
    print(f'{path.relative_to(root)}: applied GL4ES core helper inlining')

apply_exact(vertex, vertex_pristine, vertex_android)
apply_exact(fragment, fragment_pristine, fragment_android)

for path in (vertex, fragment):
    body = path.read_text(encoding='utf-8')
    if MARKER not in body or '@link "lib/core/' in body:
        raise SystemExit(f'{path}: GL4ES core-inline verification failed')

print('OpenMW 0.51 Android GL4ES core shader inlining: READY')
