#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-android-graphics-followup4.py <openmw-source-dir>")

root = Path(sys.argv[1])
nifloader = root / "components" / "nifosg" / "nifloader.cpp"

MARKER = "OPENMW_ANDROID_051_GHOSTFENCE_NO_DEPTH_WRITE"

if not nifloader.is_file():
    raise SystemExit(f"missing expected OpenMW 0.51 source file: {nifloader}")

text = nifloader.read_text(encoding="utf-8").replace("\r\n", "\n")

if MARKER not in text:
    anchor = '''                    default:
                        break;
                }
            }

            // While NetImmerse and Gamebryo support specular lighting, Morrowind has its support disabled.
'''
    replacement = '''                    default:
                        break;
                }
            }

#ifdef ANDROID
            // OPENMW_ANDROID_051_GHOSTFENCE_NO_DEPTH_WRITE
            // The simplified Ghostfence barrier consists of several overlapping,
            // alpha-blended meshes. The NIFs do not provide a NiZBufferProperty,
            // so the inherited/default depth state can still write depth while
            // these transparent layers are drawn. Keep normal depth testing
            // against the world, but prevent the Ghostfence alpha layers from
            // occluding one another through the depth buffer.
            const std::string androidDrawableNifFilename
                = Misc::StringUtils::lowerCase(mFilename.filename().value());
            if (hasSortAlpha && androidDrawableNifFilename.starts_with("ex_gg_fence_s_"))
            {
                handleDepthFlags(node->getOrCreateStateSet(), true, false);
                Log(Debug::Info) << "OpenMW 0.51 Ghostfence depth-write fix active: " << mFilename;
            }
#endif

            // While NetImmerse and Gamebryo support specular lighting, Morrowind has its support disabled.
'''
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(
            f"nifloader.cpp/Ghostfence depth-write anchor: expected exactly one match, found {count}"
        )
    text = text.replace(anchor, replacement, 1)
    print("Applied Ghostfence alpha depth-write suppression.")
else:
    print("Ghostfence alpha depth-write suppression is already applied.")

if MARKER not in text:
    raise SystemExit("nifloader.cpp: Patch-45 marker missing after patch")
if 'hasSortAlpha && androidDrawableNifFilename.starts_with("ex_gg_fence_s_")' not in text:
    raise SystemExit("nifloader.cpp: Patch-45 Ghostfence scope check missing")
if "handleDepthFlags(node->getOrCreateStateSet(), true, false);" not in text:
    raise SystemExit("nifloader.cpp: Patch-45 depth-test/depth-write state missing")

nifloader.write_text(text, encoding="utf-8", newline="\n")
print("OpenMW 0.51 Android Patch 45 source update: READY")
