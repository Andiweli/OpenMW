#!/usr/bin/env python3
from pathlib import Path
import sys

MARKER = 'Synced runtime water.frag for WetWorld mask'


def die(msg: str) -> None:
    raise SystemExit('ERROR: ' + msg)


def main() -> None:
    if len(sys.argv) != 2:
        die('usage: apply-runtime-water-shader-sync.py <MainActivity.kt>')

    path = Path(sys.argv[1])
    if not path.is_file():
        die(f'MainActivity.kt not found: {path}')

    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        required = [
            '"shaders/compatibility/water.frag"',
            'assets.open(assetPath)',
            'privateTarget.copyTo(userTarget, overwrite = true)',
            '@wetWorldWaterMask',
        ]
        for needle in required:
            if needle not in text:
                die(f'existing runtime water sync marker found but required code is missing: {needle}')
        print('MainActivity runtime water shader sync: already applied')
        return

    old = '''        // Core compatibility shaders come from the generated OpenMW resource tree.\n        val coreRelativePaths = listOf(\n            "shaders/compatibility/fullscreen_tri.vert",\n            "shaders/compatibility/shadowcasting.vert"\n        )\n\n        coreRelativePaths.forEach { relativePath ->\n            val source = File(Constants.RESOURCES, relativePath)\n            val target = File(Constants.USER_FILE_STORAGE + "/resources/", relativePath)\n\n            if (!source.isFile) {\n                throw IOException("Missing Android compatibility shader: ${source.absolutePath}")\n            }\n\n            target.parentFile?.mkdirs()\n            source.copyTo(target, overwrite = true)\n        }\n'''

    new = '''        // Core compatibility shaders must be refreshed from the APK itself on every\n        // development launch. VERSION_CODE can stay unchanged, so both the private\n        // resource tree and the writable user mirror may otherwise keep stale files.\n        // water.frag carries the Android WetWorld water-alpha marker from v14.5.5.\n        val coreRelativePaths = listOf(\n            "shaders/compatibility/fullscreen_tri.vert",\n            "shaders/compatibility/shadowcasting.vert",\n            "shaders/compatibility/water.frag"\n        )\n\n        coreRelativePaths.forEach { relativePath ->\n            val assetPath = "libopenmw/resources/$relativePath"\n            val privateTarget = File(Constants.RESOURCES, relativePath)\n            val userTarget = File(Constants.USER_FILE_STORAGE + "/resources/", relativePath)\n\n            privateTarget.parentFile?.mkdirs()\n            assets.open(assetPath).use { input ->\n                privateTarget.outputStream().use { output ->\n                    input.copyTo(output)\n                }\n            }\n\n            userTarget.parentFile?.mkdirs()\n            privateTarget.copyTo(userTarget, overwrite = true)\n\n            if (relativePath == "shaders/compatibility/water.frag") {\n                val hasWetWorldWaterMask = try {\n                    userTarget.readText().contains("@wetWorldWaterMask")\n                } catch (e: IOException) {\n                    false\n                }\n\n                if (!hasWetWorldWaterMask) {\n                    throw IOException(\n                        "Runtime water.frag is missing the WetWorld water-mask marker: ${userTarget.absolutePath}"\n                    )\n                }\n\n                Log.i(\n                    TAG,\n                    "Synced runtime water.frag for WetWorld mask; marker=true; size=${userTarget.length()}"\n                )\n            }\n        }\n'''

    count = text.count(old)
    if count != 1:
        die(f'expected exactly one legacy core shader sync block, found {count}')

    text = text.replace(old, new, 1)
    path.write_text(text, encoding='utf-8')

    for needle in [
        MARKER,
        '"shaders/compatibility/water.frag"',
        'assets.open(assetPath)',
        'privateTarget.copyTo(userTarget, overwrite = true)',
        '@wetWorldWaterMask',
    ]:
        if needle not in text:
            die(f'post-patch verification failed: {needle}')

    print('MainActivity runtime water shader sync: applied')


if __name__ == '__main__':
    main()
