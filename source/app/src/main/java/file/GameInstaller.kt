/*
    Copyright (C) 2019 Ilya Zhuravlev

    This file is part of OpenMW-Android.

    OpenMW-Android is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    OpenMW-Android is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with OpenMW-Android.  If not, see <https://www.gnu.org/licenses/>.
*/

package file

import android.content.Context
import android.preference.PreferenceManager
import constants.Constants
import java.io.File
import java.io.IOException
import java.nio.charset.Charset
import java.util.Locale

/**
 * Class responsible for initial game setup which involves
 * transforming morrowind.ini into openmw.cfg.
 */
class GameInstaller(path: String) {

    val dir = File(path)

    /**
     * Lists the root directory and finds a file or directory named [name]
     * using a case-insensitive comparison.
     */
    private fun findCaseInsensitive(name: String): File? {
        val nameLower = name.lowercase(Locale.ROOT)
        return try {
            dir.listFiles()
                ?.firstOrNull { it.name.lowercase(Locale.ROOT) == nameLower }
        } catch (_: SecurityException) {
            null
        }
    }

    /**
     * Checks that the selected game directory contains a Morrowind.ini file
     * and a Data Files directory.
     */
    fun check(): Boolean {
        if (!dir.isDirectory)
            return false

        val ini = findCaseInsensitive(INI_NAME)
        val dataFiles = findCaseInsensitive(DATA_NAME)
        return ini?.isFile == true && dataFiles?.isDirectory == true
    }

    /**
     * Returns the actual Data Files directory found on disk. This preserves
     * the real filename casing on case-sensitive filesystems.
     *
     * If the directory has not been validated yet, the conventional path is
     * returned so callers can still display a useful location.
     */
    fun findDataFilesFile(): File {
        return findCaseInsensitive(DATA_NAME)
            ?.takeIf { it.isDirectory }
            ?: File(dir, DATA_NAME)
    }

    /** Returns the absolute path to the Data Files directory. */
    fun findDataFiles(): String = findDataFilesFile().absolutePath

    /**
     * Adds a .nomedia file to the game folder so media scanners do not index
     * all game assets. Failure is intentionally non-fatal.
     */
    fun setNomedia() {
        try {
            val file = File(dir, ".nomedia")
            if (!file.exists())
                file.createNewFile()
        } catch (_: IOException) {
            // Non-critical convenience file.
        }
    }

    /**
     * Converts Morrowind.ini into OpenMW format and writes the result into
     * the application configuration directory.
     *
     * @param encoding game encoding selected by the user
     * @return true when the conversion and write completed successfully
     */
    fun convertIni(encoding: String): Boolean {
        val file = findCaseInsensitive(INI_NAME)?.takeIf { it.isFile } ?: return false

        val charset = when (encoding) {
            "win1250" -> Charset.forName("windows-1250")
            "win1251" -> Charset.forName("windows-1251")
            else -> Charset.forName("windows-1252")
        }

        return try {
            val contents = file.readText(charset)
            if (contents.isEmpty())
                return false

            val output = IniConverter(contents).convert()
            if (output.isEmpty())
                return false

            val target = File(Constants.OPENMW_FALLBACK_CFG)
            target.parentFile?.mkdirs()
            target.writeText(output)
            target.isFile && target.length() > 0
        } catch (_: IOException) {
            false
        } catch (_: SecurityException) {
            false
        } catch (_: RuntimeException) {
            // Malformed input should be reported as a failed conversion, not
            // terminate the launcher process.
            false
        }
    }

    companion object {
        const val INI_NAME = "Morrowind.ini"
        const val DATA_NAME = "Data Files"
        const val DEFAULT_CHARSET_PREF = "win1252"

        /** Returns the configured Data Files directory. */
        fun getDataFilesFile(ctx: Context): File {
            val gamePath = PreferenceManager.getDefaultSharedPreferences(ctx)
                .getString("game_files", "")
                .orEmpty()
            return GameInstaller(gamePath).findDataFilesFile()
        }

        /** Returns the absolute path of the configured Data Files directory. */
        fun getDataFiles(ctx: Context): String = getDataFilesFile(ctx).absolutePath
    }
}
