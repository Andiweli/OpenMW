#!/usr/bin/env python3
from pathlib import Path
import sys

MARKER = "OPENMW_ANDROID_GLES2_MANUAL_SHADOW_COMPARE"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def remove_once(text: str, old: str, label: str) -> str:
    return replace_once(text, old, "", label)


def patch_shadows_fragment(root: Path) -> None:
    path = root / "files/shaders/compatibility/shadows_fragment.glsl"
    text = read(path)

    if MARKER in text:
        return

    text = replace_once(
        text,
        "#define SHADOWS @shadows_enabled\n",
        "#define SHADOWS @shadows_enabled\n\n"
        f"// {MARKER}\n"
        "// GL4ES uses a GLES2 backend on Android. GLES2 can expose depth textures\n"
        "// through GL_OES_depth_texture without exposing EXT_shadow_samplers, so\n"
        "// hardware shadow samplers cannot be compiled on those devices.\n"
        "// Sample the depth texture as a regular sampler2D and perform the LEQUAL\n"
        "// comparison explicitly in GLSL instead.\n",
        "shadow fragment marker",
    )
    text = replace_once(
        text,
        "uniform sampler2DShadow shadowTexture@shadow_texture_unit_index;",
        "uniform sampler2D shadowTexture@shadow_texture_unit_index;",
        "shadow sampler type",
    )
    text = replace_once(
        text,
        "shadowing = min(shadow2DProj(shadowTexture@shadow_texture_unit_index, shadowSpaceCoords@shadow_texture_unit_index).r, shadowing);",
        "shadowing = min(step(shadowXYZ.z, texture2D(shadowTexture@shadow_texture_unit_index, shadowXYZ.xy).r), shadowing);",
        "manual shadow depth comparison",
    )

    if "uniform sampler2DShadow" in text or "shadow2DProj(" in text:
        raise SystemExit("shadow fragment still contains hardware shadow sampler syntax")

    write(path, text)


def patch_shadow_technique(root: Path) -> None:
    path = root / "components/sceneutil/mwshadowtechnique.cpp"
    text = read(path)

    if MARKER in text:
        return

    # Internal OSG fallback shaders must also remain valid if OpenMW ever selects
    # them instead of the normal compatibility shader files.
    text = text.replace("sampler2DShadow", "sampler2D")
    text = text.replace(
        "shadow2DProj( shadowTexture, gl_TexCoord[1] ).r",
        "step(gl_TexCoord[1].z / gl_TexCoord[1].w, "
        "texture2D(shadowTexture, gl_TexCoord[1].xy / gl_TexCoord[1].w).r)",
    )

    text = text.replace(
        "shadow2DProj( shadowTexture0, gl_TexCoord[shadowTextureUnit0] ).r",
        "step(gl_TexCoord[shadowTextureUnit0].z / gl_TexCoord[shadowTextureUnit0].w, "
        "texture2D(shadowTexture0, gl_TexCoord[shadowTextureUnit0].xy / gl_TexCoord[shadowTextureUnit0].w).r)",
    )
    text = text.replace(
        "shadow2DProj( shadowTexture1, gl_TexCoord[shadowTextureUnit1] ).r",
        "step(gl_TexCoord[shadowTextureUnit1].z / gl_TexCoord[shadowTextureUnit1].w, "
        "texture2D(shadowTexture1, gl_TexCoord[shadowTextureUnit1].xy / gl_TexCoord[shadowTextureUnit1].w).r)",
    )

    old_texture = """        _texture->setInternalFormat(GL_DEPTH_COMPONENT);\n        _texture->setShadowComparison(true);\n        _texture->setShadowTextureMode(osg::Texture2D::LUMINANCE);\n    }\n\n    _texture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::LINEAR);\n    _texture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::LINEAR);\n"""
    new_texture = """        _texture->setInternalFormat(GL_DEPTH_COMPONENT);\n#ifdef ANDROID\n        // __MARKER__\n        // The GLES2 backend has OES_depth_texture but no shadow-sampler support.\n        // Keep the depth texture in raw sampling mode; shadows_fragment.glsl\n        // performs the LEQUAL comparison manually. NEAREST avoids interpolating\n        // depth before that comparison.\n        OSG_NOTICE << "Android GLES2 manual shadow comparison enabled" << std::endl;\n        _texture->setShadowComparison(false);\n#else\n        _texture->setShadowComparison(true);\n        _texture->setShadowTextureMode(osg::Texture2D::LUMINANCE);\n#endif\n    }\n\n#ifdef ANDROID\n    _texture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::NEAREST);\n    _texture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::NEAREST);\n#else\n    _texture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::LINEAR);\n    _texture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::LINEAR);\n#endif\n""".replace("__MARKER__", MARKER)
    text = replace_once(text, old_texture, new_texture, "shadow depth texture sampling mode")

    old_fallback = """        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::NEAREST);\n        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::NEAREST);\n        _fallbackShadowMapTexture->setShadowComparison(true);\n        _fallbackShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);\n"""
    new_fallback = """        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MIN_FILTER,osg::Texture2D::NEAREST);\n        _fallbackShadowMapTexture->setFilter(osg::Texture2D::MAG_FILTER,osg::Texture2D::NEAREST);\n#ifdef ANDROID\n        _fallbackShadowMapTexture->setShadowComparison(false);\n#else\n        _fallbackShadowMapTexture->setShadowComparison(true);\n        _fallbackShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);\n#endif\n"""
    text = replace_once(text, old_fallback, new_fallback, "fallback shadow texture sampling mode")

    if "sampler2DShadow" in text or "shadow2DProj(" in text:
        raise SystemExit("mwshadowtechnique.cpp still contains hardware shadow sampler syntax")

    write(path, text)


def patch_shadow_manager(root: Path) -> None:
    path = root / "components/sceneutil/shadow.cpp"
    text = read(path)

    if MARKER in text:
        return

    old_image = """        osg::ref_ptr<osg::Image> fakeShadowMapImage = new osg::Image();\n        fakeShadowMapImage->allocateImage(1, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT);\n        *(float*)fakeShadowMapImage->data() = std::numeric_limits<float>::infinity();\n        osg::ref_ptr<osg::Texture> fakeShadowMapTexture = new osg::Texture2D(fakeShadowMapImage);\n"""
    new_image = f"""        osg::ref_ptr<osg::Image> fakeShadowMapImage = new osg::Image();\n#ifdef ANDROID\n        // {MARKER}\n        // Receiver shaders sample raw depth through sampler2D on GLES2. A white\n        // RGBA texel therefore represents an always-unshadowed fallback without\n        // requiring unsupported depth-compare texture state.\n        fakeShadowMapImage->allocateImage(1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE);\n        fakeShadowMapImage->data()[0] = 0xFF;\n        fakeShadowMapImage->data()[1] = 0xFF;\n        fakeShadowMapImage->data()[2] = 0xFF;\n        fakeShadowMapImage->data()[3] = 0xFF;\n#else\n        fakeShadowMapImage->allocateImage(1, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT);\n        *(float*)fakeShadowMapImage->data() = std::numeric_limits<float>::infinity();\n#endif\n        osg::ref_ptr<osg::Texture> fakeShadowMapTexture = new osg::Texture2D(fakeShadowMapImage);\n"""
    text = replace_once(text, old_image, new_image, "fake shadow map image")

    old_compare = """        fakeShadowMapTexture->setShadowComparison(true);\n        fakeShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);\n"""
    new_compare = """#ifdef ANDROID\n        fakeShadowMapTexture->setShadowComparison(false);\n#else\n        fakeShadowMapTexture->setShadowComparison(true);\n        fakeShadowMapTexture->setShadowCompareFunc(osg::Texture::ShadowCompareFunc::ALWAYS);\n#endif\n"""
    text = replace_once(text, old_compare, new_compare, "fake shadow map comparison mode")

    write(path, text)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: apply-android-shadow-gles2-manual-compare.py <openmw-source-dir>")

    root = Path(sys.argv[1]).resolve()
    if not (root / "CMakeLists.txt").is_file():
        raise SystemExit(f"OpenMW source directory not found: {root}")

    patch_shadows_fragment(root)
    patch_shadow_technique(root)
    patch_shadow_manager(root)

    print("OpenMW Android GLES2 manual shadow comparison: READY")
    print("  sampler2DShadow/shadow2DProj: replaced with sampler2D + explicit LEQUAL")
    print("  shadow depth textures: raw-sampling mode on Android")
    print("  fake shadow textures: GLES2-safe white fallback")


if __name__ == "__main__":
    main()
