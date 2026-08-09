#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-android-gles-depth-fallback.py <openmw-source-dir>")

root = Path(sys.argv[1])
cpp = root / "apps/openmw/mwrender/postprocessor.cpp"
if not cpp.is_file():
    raise SystemExit(f"postprocessor.cpp not found: {cpp}")

text = cpp.read_text(encoding="utf-8")
runtime_marker = "Android GLES post-processing depth fallback: sampling Tex_Depth directly"

android_binding = """#ifdef ANDROID
        // OpenGL ES cannot reliably populate Tex_OpaqueDepth because that path
        // depends on a depth copy/blit. The primary scene depth texture is
        // already sampleable, so use it directly for Android post-processing.
        mCanvases[frameId]->setTextureDepth(getTexture(Tex_Depth, frameId));
#else
        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));
#endif"""

if android_binding not in text:
    old = "        mCanvases[frameId]->setTextureDepth(getTexture(Tex_OpaqueDepth, frameId));"
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one Tex_OpaqueDepth canvas binding, found {count}; refusing ambiguous patch."
        )
    text = text.replace(old, android_binding, 1)
    print("Applied Android canvas depth source: Tex_OpaqueDepth -> Tex_Depth.")
else:
    print("Android Tex_Depth canvas fallback already applied.")

if runtime_marker not in text:
    anchor = """#ifdef ANDROID
        ext->glDisablei = nullptr;
#endif
"""
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one Android glDisablei anchor, found {count}; refusing ambiguous marker insertion."
        )
    replacement = anchor + """
#ifdef ANDROID
        Log(Debug::Info) << "Android GLES post-processing depth fallback: sampling Tex_Depth directly";
#endif
"""
    text = text.replace(anchor, replacement, 1)
    print("Added Android depth-fallback runtime marker.")
else:
    print("Android depth-fallback runtime marker already present.")

cpp.write_text(text, encoding="utf-8", newline="\n")
print("OpenMW 0.50 Android GLES depth fallback source: READY")
