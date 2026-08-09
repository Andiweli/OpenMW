#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "OMWFX050-DIAG"
STARTUP_MARKER = "Android post-processing startup stabilization: scheduling final chain rebuild after 4 completed draws at "


def die(msg: str) -> None:
    raise SystemExit("ERROR: " + msg)


def read(path: Path) -> str:
    if not path.is_file():
        die(f"required OpenMW source file is missing: {path}")
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text.replace("\r\n", "\n"), encoding="utf-8", newline="\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        die(f"{label}: expected exactly one source anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: apply-omwfx050-diagnostics.py <OpenMW-source-dir>")

    root = Path(sys.argv[1]).resolve()
    cpp_path = root / "apps/openmw/mwrender/postprocessor.cpp"
    cpp = read(cpp_path)

    if STARTUP_MARKER not in cpp:
        die("the established Android 4-draw post-processing stabilization is missing; refusing to patch another source baseline")

    if MARKER in cpp:
        for token in (
            "OMWFX050-DIAG: capability",
            "OMWFX050-DIAG: load file=",
            "OMWFX050-DIAG: loadChain configuredCount=",
            "OMWFX050-DIAG: dirty name=",
            "OMWFX050-DIAG: dispatch templates=",
        ):
            if token not in cpp:
                die(f"diagnostic marker exists but required token is missing: {token}")
        print("OpenMW 0.50 OMWFX diagnostics: already applied")
        return

    # Runtime capability and discovery summary. This executes after OpenMW has
    # populated mTechniqueFiles and queried the real GL context.
    cpp = replace_once(
        cpp,
        """        mGLSLVersion = ext->glslLanguageVersion * 100;
        mUBO = ext->isUniformBufferObjectSupported && mGLSLVersion >= 330;
        mStateUpdater = new Fx::StateUpdater(mUBO);""",
        """        mGLSLVersion = ext->glslLanguageVersion * 100;
        mUBO = ext->isUniformBufferObjectSupported && mGLSLVersion >= 330;
#ifdef ANDROID
        Log(Debug::Info) << "OMWFX050-DIAG: capability glsl=" << mGLSLVersion
                         << " ubo=" << mUBO
                         << " normalsSupported=" << mNormalsSupported
                         << " discoveredFiles=" << mTechniqueFiles.size();
#endif
        mStateUpdater = new Fx::StateUpdater(mUBO);""",
        "capability summary",
    )

    # Capture the exact normalized path lookup result and parser/compiler state
    # for every requested technique. All getters below are already used by the
    # 0.50 PostProcessor implementation, so this adds logging only.
    cpp = replace_once(
        cpp,
        """        std::string name;
        if (mTechniqueFiles.contains(path))
            name = mVFS->getStem(path);
        else
            name = path.stem();

        auto technique = std::make_shared<Fx::Technique>(*mVFS, *mRendering.getResourceSystem()->getImageManager(),
            path, std::move(name), renderWidth(), renderHeight(), mUBO, mNormalsSupported);

        technique->compile();""",
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
        "technique load diagnostics",
    )

    # Log the configured chain before OpenMW resolves it, and every requested
    # name individually. This proves that Settings reached the native loader.
    cpp = replace_once(
        cpp,
        """        for (const std::string& techniqueName : Settings::postProcessing().mChain.get())
        {
            if (techniqueName.empty())
                continue;

            mTechniques.push_back(loadTechnique(techniqueName));
        }""",
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
        "chain diagnostics",
    )

    # Log the validity/GLSL/pass state immediately before 0.50's normal filters.
    cpp = replace_once(
        cpp,
        """        for (const auto& technique : mTechniques)
        {
            if (!technique->isValid())
                continue;""",
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
        "dirty-technique diagnostics",
    )

    cpp = replace_once(
        cpp,
        """        mCanvases[frameId]->setPasses(Fx::DispatchArray(mTemplateData));

        if (auto hud = MWBase::Environment::get().getWindowManager()->getPostProcessorHud())""",
        """        mCanvases[frameId]->setPasses(Fx::DispatchArray(mTemplateData));
#ifdef ANDROID
        Log(Debug::Info) << "OMWFX050-DIAG: dispatch templates=" << mTemplateData.size()
                         << " frameId=" << frameId
                         << " usePostProcessing=" << mUsePostProcessing;
#endif

        if (auto hud = MWBase::Environment::get().getWindowManager()->getPostProcessorHud())""",
        "dispatch diagnostics",
    )

    for token in (
        "OMWFX050-DIAG: capability",
        "OMWFX050-DIAG: load file=",
        "OMWFX050-DIAG: loadChain configuredCount=",
        "OMWFX050-DIAG: loadChain request=",
        "OMWFX050-DIAG: dirty name=",
        "OMWFX050-DIAG: dispatch templates=",
        STARTUP_MARKER,
    ):
        if token not in cpp:
            die(f"post-patch verification failed: {token}")

    write(cpp_path, cpp)
    print("OpenMW 0.50 OMWFX diagnostics: READY")
    print("  logs capability + VFS discovery count")
    print("  logs each configured technique load/compile/validity/GLSL/pass count")
    print("  logs dirtyTechniques filtering inputs and final dispatch-template count")


if __name__ == "__main__":
    main()
