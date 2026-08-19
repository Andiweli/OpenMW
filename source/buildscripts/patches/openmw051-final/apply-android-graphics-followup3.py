#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply-android-graphics-followup3.py <openmw-source-dir>")

root = Path(sys.argv[1])
settingswindow = root / "apps" / "openmw" / "mwgui" / "settingswindow.cpp"
nifloader = root / "components" / "nifosg" / "nifloader.cpp"

RES_MARKER = "OPENMW_ANDROID_051_ACTIVE_RENDER_RESOLUTION_ONLY"
DIAG_MARKER = "OPENMW_ANDROID_051_GHOSTFENCE_DEPTH_DIAG"
OLD_PARTICLE_MARKER = "OPENMW_ANDROID_051_GHOSTFENCE_PARTICLE_STABLE_ORDER"

for path in (settingswindow, nifloader):
    if not path.is_file():
        raise SystemExit(f"missing expected OpenMW 0.51 source file: {path}")

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)

text = settingswindow.read_text(encoding="utf-8").replace("\r\n", "\n")

if RES_MARKER not in text:
    old = '''        const int screen = Settings::video().mScreen;
        int numDisplayModes = SDL_GetNumDisplayModes(screen);
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
        for (int i = 0; i < numDisplayModes; i++)
        {
            SDL_DisplayMode mode;
            SDL_GetDisplayMode(screen, i, &mode);
            resolutions.emplace_back(mode.w, mode.h);
        }
'''
    new = '''        std::vector<std::pair<int, int>> resolutions;
#ifdef ANDROID
        // OPENMW_ANDROID_051_ACTIVE_RENDER_RESOLUTION_ONLY
        // Android's physical panel mode is not OpenMW's logical render size.
        // Expose only the actual launcher-selected render resolution.
        const int configuredWidth = Settings::video().mResolutionX;
        const int configuredHeight = Settings::video().mResolutionY;
        if (configuredWidth > 0 && configuredHeight > 0)
            resolutions.emplace_back(configuredWidth, configuredHeight);
#else
        const int screen = Settings::video().mScreen;
        int numDisplayModes = SDL_GetNumDisplayModes(screen);
        for (int i = 0; i < numDisplayModes; i++)
        {
            SDL_DisplayMode mode;
            SDL_GetDisplayMode(screen, i, &mode);
            resolutions.emplace_back(mode.w, mode.h);
        }
#endif
'''
    text = replace_once(text, old, new, "settingswindow.cpp/active Android render resolution only")
    settingswindow.write_text(text, encoding="utf-8", newline="\n")
    print("Android in-game resolution list now exposes only the active render resolution.")
else:
    print("Android active-render-resolution-only list is already applied.")

text = nifloader.read_text(encoding="utf-8").replace("\r\n", "\n")

old_particle = '''            osg::ref_ptr<ParticleSystem> partsys(new ParticleSystem);
#ifdef ANDROID
            // OPENMW_ANDROID_051_GHOSTFENCE_PARTICLE_STABLE_ORDER
            // OSG normally re-sorts every particle by camera-space Z each frame.
            // The Ghostfence uses dense/coincident translucent effect particles;
            // tiny camera changes can therefore change their order and produce
            // visible flicker. Keep creation/traversal order only for the vanilla
            // Ghostfence effect family; all other particles retain upstream sorting.
            const std::string androidParticleNifFilename
                = Misc::StringUtils::lowerCase(mFilename.filename().value());
            const bool stableGhostfenceParticles = androidParticleNifFilename.starts_with("ex_gg_fence_")
                || androidParticleNifFilename == "ex_gg_particles_01.nif";
            partsys->setSortMode(stableGhostfenceParticles ? osgParticle::ParticleSystem::NO_SORT
                                                           : osgParticle::ParticleSystem::SORT_BACK_TO_FRONT);
#else
            partsys->setSortMode(osgParticle::ParticleSystem::SORT_BACK_TO_FRONT);
#endif
'''
upstream_particle = '''            osg::ref_ptr<ParticleSystem> partsys(new ParticleSystem);
            partsys->setSortMode(osgParticle::ParticleSystem::SORT_BACK_TO_FRONT);
'''

if OLD_PARTICLE_MARKER in text:
    if old_particle not in text:
        raise SystemExit("nifloader.cpp: Patch-43 particle marker exists but exact rollback block differs")
    text = text.replace(old_particle, upstream_particle, 1)
    print("Rolled back the device-negative Ghostfence particle NO_SORT experiment.")
else:
    print("Ghostfence particle sorting is already at upstream behavior.")

# Patch 44 v1 accidentally inserted a Ghostfence UV diagnostic into the
# static handleMeshControllers() function. That function has no LoaderImpl
# instance and therefore cannot access mFilename. Remove that block first so
# this v2 patcher also repairs a source tree left behind by the failed v1 build.
broken_uv_diag = '''#ifdef ANDROID
                    const std::string androidDiagFilename
                        = Misc::StringUtils::lowerCase(mFilename.filename().value());
                    if (androidDiagFilename.starts_with("ex_gg_fence_"))
                    {
                        Log(Debug::Info) << "OpenMW 0.51 Ghostfence diag: UV controller file=" << mFilename
                                         << " node=\"" << node->getName() << "\"";
                    }
#endif
'''
if broken_uv_diag in text:
    text = text.replace(broken_uv_diag, "", 1)
    print("Removed the invalid static UV-controller diagnostic from Patch 44 v1.")

if DIAG_MARKER not in text:
    z_old = '''                case Nif::RC_NiZBufferProperty:
                {
                    const Nif::NiZBufferProperty* zprop = static_cast<const Nif::NiZBufferProperty*>(property);
                    osg::StateSet* stateset = node->getOrCreateStateSet();
                    // The test function from this property seems to be ignored.
                    handleDepthFlags(stateset, zprop->depthTest(), zprop->depthWrite());
                    break;
                }
'''
    z_new = '''                case Nif::RC_NiZBufferProperty:
                {
                    const Nif::NiZBufferProperty* zprop = static_cast<const Nif::NiZBufferProperty*>(property);
#ifdef ANDROID
                    // OPENMW_ANDROID_051_GHOSTFENCE_DEPTH_DIAG
                    const std::string androidDiagFilename
                        = Misc::StringUtils::lowerCase(mFilename.filename().value());
                    if (androidDiagFilename.starts_with("ex_gg_fence_"))
                    {
                        Log(Debug::Info) << "OpenMW 0.51 Ghostfence diag: zbuffer file=" << mFilename
                                         << " node=\"" << node->getName() << "\""
                                         << " depthTest=" << zprop->depthTest()
                                         << " depthWrite=" << zprop->depthWrite();
                    }
#endif
                    osg::StateSet* stateset = node->getOrCreateStateSet();
                    // The test function from this property seems to be ignored.
                    handleDepthFlags(stateset, zprop->depthTest(), zprop->depthWrite());
                    break;
                }
'''
    text = replace_once(text, z_old, z_new, "nifloader.cpp/Ghostfence Z-buffer diagnostics")

    alpha_old = '''                    case Nif::RC_NiAlphaProperty:
                    {
                        const Nif::NiAlphaProperty* alphaprop = static_cast<const Nif::NiAlphaProperty*>(property);
                        handleAlphaBlending(alphaprop->useAlphaBlending(), alphaprop->sourceBlendMode(),
                            alphaprop->destinationBlendMode(), !alphaprop->noSorter(), hasSortAlpha, *node);
                        handleAlphaTesting(alphaprop->useAlphaTesting(), getTestMode(alphaprop->alphaTestMode()),
                            alphaprop->mThreshold, *node);
                        break;
                    }
'''
    alpha_new = '''                    case Nif::RC_NiAlphaProperty:
                    {
                        const Nif::NiAlphaProperty* alphaprop = static_cast<const Nif::NiAlphaProperty*>(property);
#ifdef ANDROID
                        const std::string androidDiagFilename
                            = Misc::StringUtils::lowerCase(mFilename.filename().value());
                        if (androidDiagFilename.starts_with("ex_gg_fence_"))
                        {
                            Log(Debug::Info) << "OpenMW 0.51 Ghostfence diag: alpha file=" << mFilename
                                             << " node=\"" << node->getName() << "\""
                                             << " blend=" << alphaprop->useAlphaBlending()
                                             << " src=" << alphaprop->sourceBlendMode()
                                             << " dst=" << alphaprop->destinationBlendMode()
                                             << " sorter=" << (!alphaprop->noSorter())
                                             << " alphaTest=" << alphaprop->useAlphaTesting()
                                             << " threshold=" << alphaprop->mThreshold;
                        }
#endif
                        handleAlphaBlending(alphaprop->useAlphaBlending(), alphaprop->sourceBlendMode(),
                            alphaprop->destinationBlendMode(), !alphaprop->noSorter(), hasSortAlpha, *node);
                        handleAlphaTesting(alphaprop->useAlphaTesting(), getTestMode(alphaprop->alphaTestMode()),
                            alphaprop->mThreshold, *node);
                        break;
                    }
'''
    text = replace_once(text, alpha_old, alpha_new, "nifloader.cpp/Ghostfence alpha diagnostics")
    print("Added Ghostfence-only Z-buffer/alpha diagnostics.")
else:
    print("Ghostfence Z-buffer/alpha diagnostics are already applied.")

if "Ghostfence diag: UV controller" in text:
    raise SystemExit("nifloader.cpp: invalid Patch-44-v1 UV diagnostic still remains")

nifloader.write_text(text, encoding="utf-8", newline="\n")

for path, marker in ((settingswindow, RES_MARKER), (nifloader, DIAG_MARKER)):
    if marker not in path.read_text(encoding="utf-8"):
        raise SystemExit(f"{path}: expected marker {marker} is missing")

if OLD_PARTICLE_MARKER in nifloader.read_text(encoding="utf-8"):
    raise SystemExit("nifloader.cpp: obsolete Patch-43 Ghostfence particle override remains")

print("OpenMW 0.51 Android Patch 44 source update: READY")
