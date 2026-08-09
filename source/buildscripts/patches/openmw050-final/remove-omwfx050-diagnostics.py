#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "OMWFX050-DIAG"

def die(msg: str) -> None:
    raise SystemExit("ERROR: " + msg)

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        die(f"{label}: expected exactly one diagnostic block, found {count}")
    return text.replace(old, new, 1)

def main() -> None:
    if len(sys.argv) != 2:
        die("usage: remove-omwfx050-diagnostics.py <OpenMW-source-dir>")

    path = Path(sys.argv[1]).resolve() / "apps/openmw/mwrender/postprocessor.cpp"
    if not path.is_file():
        die(f"postprocessor.cpp not found: {path}")

    text = path.read_text(encoding="utf-8")

    if MARKER not in text:
        print("OpenMW 0.50 OMWFX diagnostics: already absent")
        return

    text = replace_once(
        text,
        """        mGLSLVersion = ext->glslLanguageVersion * 100;
        mUBO = ext->isUniformBufferObjectSupported && mGLSLVersion >= 330;
#ifdef ANDROID
        Log(Debug::Info) << "OMWFX050-DIAG: capability glsl=" << mGLSLVersion
                         << " ubo=" << mUBO
                         << " normalsSupported=" << mNormalsSupported
                         << " discoveredFiles=" << mTechniqueFiles.size();
#endif
        mStateUpdater = new Fx::StateUpdater(mUBO);""",
        """        mGLSLVersion = ext->glslLanguageVersion * 100;
        mUBO = ext->isUniformBufferObjectSupported && mGLSLVersion >= 330;
        mStateUpdater = new Fx::StateUpdater(mUBO);""",
        "capability diagnostics",
    )

    text = replace_once(
        text,
        """        const bool discovered = mTechniqueFiles.contains(path);
        std::string name;
        if (discovered)
            name = mVFS->getStem(path);
        else
            name = path.stem();

        auto technique = std::make_shared<Fx::Technique>(*mVFS, *mRendering.getResourceSystem()->getImageManager(),
            path, std::move(name), renderWidth(), renderHeight(), mUBO, mNormalsSupported);

        const bool compiled = technique->compile();
#ifdef ANDROID
        Log(Debug::Info) << "OMWFX050-DIAG: load file=" << technique->getFileName()
                         << " name=" << technique->getName()
                         << " discovered=" << discovered
                         << " compiled=" << compiled
                         << " valid=" << technique->isValid()
                         << " status=" << static_cast<int>(technique->getStatus())
                         << " glsl=" << technique->getGLSLVersion()
                         << " passes=" << technique->getPasses().size();
#endif""",
        """        std::string name;
        if (mTechniqueFiles.contains(path))
            name = mVFS->getStem(path);
        else
            name = path.stem();

        auto technique = std::make_shared<Fx::Technique>(*mVFS, *mRendering.getResourceSystem()->getImageManager(),
            path, std::move(name), renderWidth(), renderHeight(), mUBO, mNormalsSupported);

        technique->compile();""",
        "technique load diagnostics",
    )

    text = replace_once(
        text,
        """#ifdef ANDROID
        Log(Debug::Info) << "OMWFX050-DIAG: loadChain configuredCount="
                         << Settings::postProcessing().mChain.get().size();
#endif
        for (const std::string& techniqueName : Settings::postProcessing().mChain.get())
        {
            if (techniqueName.empty())
                continue;

#ifdef ANDROID
            Log(Debug::Info) << "OMWFX050-DIAG: loadChain request=" << techniqueName;
#endif
            mTechniques.push_back(loadTechnique(techniqueName));
        }""",
        """        for (const std::string& techniqueName : Settings::postProcessing().mChain.get())
        {
            if (techniqueName.empty())
                continue;

            mTechniques.push_back(loadTechnique(techniqueName));
        }""",
        "chain diagnostics",
    )

    text = replace_once(
        text,
        """        for (const auto& technique : mTechniques)
        {
#ifdef ANDROID
            Log(Debug::Info) << "OMWFX050-DIAG: dirty name=" << technique->getName()
                             << " file=" << technique->getFileName()
                             << " internal=" << technique->getInternal()
                             << " valid=" << technique->isValid()
                             << " status=" << static_cast<int>(technique->getStatus())
                             << " techniqueGlsl=" << technique->getGLSLVersion()
                             << " hardwareGlsl=" << mGLSLVersion
                             << " passes=" << technique->getPasses().size();
#endif
            if (!technique->isValid())
                continue;""",
        """        for (const auto& technique : mTechniques)
        {
            if (!technique->isValid())
                continue;""",
        "dirty-technique diagnostics",
    )

    text = replace_once(
        text,
        """        mCanvases[frameId]->setPasses(Fx::DispatchArray(mTemplateData));
#ifdef ANDROID
        Log(Debug::Info) << "OMWFX050-DIAG: dispatch templates=" << mTemplateData.size()
                         << " frameId=" << frameId
                         << " usePostProcessing=" << mUsePostProcessing;
#endif

        if (auto hud = MWBase::Environment::get().getWindowManager()->getPostProcessorHud())""",
        """        mCanvases[frameId]->setPasses(Fx::DispatchArray(mTemplateData));

        if (auto hud = MWBase::Environment::get().getWindowManager()->getPostProcessorHud())""",
        "dispatch diagnostics",
    )

    if MARKER in text:
        die("diagnostic cleanup incomplete: OMWFX050-DIAG remains in postprocessor.cpp")

    path.write_text(text.replace("\r\n", "\n"), encoding="utf-8", newline="\n")
    print("OpenMW 0.50 OMWFX diagnostics: REMOVED")

if __name__ == "__main__":
    main()
