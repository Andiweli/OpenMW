#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply-android-graphics-followup2.py <openmw-source-dir>')

root = Path(sys.argv[1])
nifloader = root / 'components' / 'nifosg' / 'nifloader.cpp'
display = root / 'components' / 'misc' / 'display.cpp'

GHOST_MARKER = 'OPENMW_ANDROID_051_GHOSTFENCE_PARTICLE_STABLE_ORDER'
ASPECT_MARKER = 'OPENMW_ANDROID_051_COMMON_ASPECT_RATIO'
OLD_GHOST_MARKER = 'OPENMW_ANDROID_051_GHOSTFENCE_STABLE_ORDER'

for path in (nifloader, display):
    if not path.is_file():
        raise SystemExit(f'missing expected OpenMW 0.51 source file: {path}')

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one anchor, found {count}')
    return text.replace(old, new, 1)

# ---------------------------------------------------------------------------
# Ghostfence:
# Remove Patch-42's first hypothesis (transparent render-bin traversal order).
# Device testing showed no change. The actual OSG ParticleSystem still performs
# camera-dependent SORT_BACK_TO_FRONT sorting internally, which that patch did
# not affect.
# ---------------------------------------------------------------------------
text = nifloader.read_text(encoding='utf-8').replace('\r\n', '\n')

old_block = '''#ifdef ANDROID
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

'''
if OLD_GHOST_MARKER in text:
    if old_block not in text:
        raise SystemExit('nifloader.cpp: old Patch-42 Ghostfence block marker found, but exact migration block differs')
    text = text.replace(old_block, '', 1)
    print('Removed the ineffective Patch-42 Ghostfence render-bin override.')

if GHOST_MARKER not in text:
    text = replace_once(
        text,
        '''            osg::ref_ptr<ParticleSystem> partsys(new ParticleSystem);
            partsys->setSortMode(osgParticle::ParticleSystem::SORT_BACK_TO_FRONT);
''',
        '''            osg::ref_ptr<ParticleSystem> partsys(new ParticleSystem);
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
''',
        'nifloader.cpp/Ghostfence particle sorting',
    )
    print('Disabled camera-dependent particle sorting only for the Ghostfence effect family.')
else:
    print('Ghostfence particle stable-order fix is already applied.')

nifloader.write_text(text, encoding='utf-8', newline='\n')

# ---------------------------------------------------------------------------
# Resolution aspect label:
# OpenMW reports the exact reduced fraction. 854x480 => 427:240 even though it
# is the conventional integer approximation of 16:9 used for 480p. OpenMW
# already has several hand-written "usually referred as" corrections. Extend
# that idea on Android by snapping only close matches (<= 1%) to common ratios.
# ---------------------------------------------------------------------------
text = display.read_text(encoding='utf-8').replace('\r\n', '\n')

if ASPECT_MARKER not in text:
    text = replace_once(
        text,
        '''        else
        {
            // everything between 21:9 and 22:9
            // is usually referred as 21:9
            float ratio = static_cast<float>(xaspect) / yaspect;
            if (ratio >= 21 / 9.f && ratio < 22 / 9.f)
            {
                xaspect = 21;
                yaspect = 9;
            }
        }
''',
        '''        else
        {
            float ratio = static_cast<float>(xaspect) / yaspect;

#ifdef ANDROID
            // OPENMW_ANDROID_051_COMMON_ASPECT_RATIO
            // Logical Android render sizes may use integer approximations of
            // standard video modes, e.g. 854x480 is 427:240 mathematically but
            // conventionally represents 16:9. Snap only very close matches so
            // genuinely unusual aspect ratios keep their exact reduced value.
            struct CommonAspect
            {
                int x;
                int y;
            };
            static constexpr CommonAspect commonAspects[] = {
                { 5, 4 },
                { 4, 3 },
                { 3, 2 },
                { 16, 10 },
                { 16, 9 },
                { 18, 9 },
                { 19, 9 },
                { 20, 9 },
                { 21, 9 },
                { 32, 9 },
            };

            const CommonAspect* bestAspect = nullptr;
            float bestRelativeError = 0.01f;
            for (const CommonAspect& candidate : commonAspects)
            {
                const float candidateRatio = static_cast<float>(candidate.x) / candidate.y;
                const float relativeError = ratio > candidateRatio
                    ? (ratio - candidateRatio) / candidateRatio
                    : (candidateRatio - ratio) / candidateRatio;
                if (relativeError < bestRelativeError)
                {
                    bestRelativeError = relativeError;
                    bestAspect = &candidate;
                }
            }

            if (bestAspect)
            {
                xaspect = bestAspect->x;
                yaspect = bestAspect->y;
            }
            else
#endif
            {
                // everything between 21:9 and 22:9
                // is usually referred as 21:9
                if (ratio >= 21 / 9.f && ratio < 22 / 9.f)
                {
                    xaspect = 21;
                    yaspect = 9;
                }
            }
        }
''',
        'display.cpp/common Android aspect-ratio approximation',
    )
    print('Added conventional aspect-ratio approximation for Android logical render sizes.')
else:
    print('Android common aspect-ratio approximation is already applied.')

display.write_text(text, encoding='utf-8', newline='\n')

for path, marker in ((nifloader, GHOST_MARKER), (display, ASPECT_MARKER)):
    if marker not in path.read_text(encoding='utf-8'):
        raise SystemExit(f'{path}: expected marker {marker} is missing')

print('OpenMW 0.51 Android graphics follow-up 2: READY')
