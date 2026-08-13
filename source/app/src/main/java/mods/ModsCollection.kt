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

package mods

import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.util.Locale

/**
 * Represents an ordered list of mods of a specific type
 * @param type Type of the mods represented by this collection, Plugin or Resource
 * @param dataFiles Path to the directory of the mods (the Data Files directory)
 */
class ModsCollection(
    private val type: ModType,
    private val dataFiles: ArrayList<String>,
    private val db: ModsDatabaseOpenHelper
) {
    val mods = arrayListOf<Mod>()

    private val extensions: Array<String> = when (type) {
        ModType.Resource -> arrayOf("bsa")
        ModType.Dir -> emptyArray()
        else -> arrayOf("esm", "esp", "omwaddon", "omwgame", "omwscripts")
    }

    init {
        if (isEmpty()) {
            initDb()
        }

        syncWithFs(type)

        // The database might have become empty (e.g. if user deletes all mods) after the FS sync.
        if (isEmpty()) {
            initDb()
        }
    }

    /**
     * Checks if the mod DB is empty, i.e. no mods defined yet.
     */
    private fun isEmpty(): Boolean {
        val database = db.readableDatabase
        database.rawQuery("SELECT count(1) FROM mod", null).use { cursor ->
            return !cursor.moveToFirst() || cursor.getInt(0) == 0
        }
    }

    /**
     * Inserts built-in mods into the database, in proper order.
     * Also checks to make sure only installed mods are inserted.
     */
    private fun initDb() {
        val builtIn = arrayOf("Morrowind", "Tribunal", "Bloodmoon")
        initDbMods(builtIn.map { "$it.esm" }, ModType.Plugin)
        initDbMods(builtIn.map { "$it.bsa" }, ModType.Resource)
    }

    /**
     * Inserts built-in mods of a specific mod type.
     * All of the built-in mods will be enabled by default.
     */
    private fun initDbMods(files: List<String>, type: ModType) {
        var order = 0
        val database = db.writableDatabase

        dataFiles.forEach { dataPath ->
            files
                .map { File(dataPath, it) }
                .filter { it.exists() }
                .map {
                    order += 1
                    Mod(type, it.name, order, true)
                }
                .forEach { it.insert(database) }
        }
    }

    /**
     * Synchronizes state of mods in database with the actual mod files on disk.
     */
    private fun syncWithFs(type: ModType) {
        val database = db.writableDatabase
        val dbMods = mutableListOf<Mod>()

        database.query(
            "mod",
            arrayOf("type", "filename", "load_order", "enabled"),
            "type = ?",
            arrayOf(type.v.toString()),
            null,
            null,
            null
        ).use { cursor ->
            while (cursor.moveToNext()) {
                dbMods.add(Mod.fromCursor(cursor))
            }
        }

        val fsNames = mutableSetOf<String>()

        dataFiles.forEach { dataPath ->
            val modFiles = File(dataPath).listFiles()?.filter {
                when (type) {
                    ModType.Dir -> it.isDirectory
                    else -> it.isFile && extensions.contains(it.extension.lowercase(Locale.ROOT))
                }
            }

            // Blacklist "Data Files" in Directories tab and default plugins in Groundcovers tab.
            val blacklist = mutableSetOf<String>()
            if (type == ModType.Dir) {
                File(dataPath).listFiles()
                    ?.firstOrNull { it.name.equals("Data Files", ignoreCase = true) }
                    ?.let { blacklist.add(it.name) }
            }
            if (type == ModType.Groundcover) {
                blacklist.add("Morrowind.esm")
                blacklist.add("Tribunal.esm")
                blacklist.add("Bloodmoon.esm")
                blacklist.add("adamantiumarmor.esp")
                blacklist.add("AreaEffectArrows.esp")
                blacklist.add("bcsounds.esp")
                blacklist.add("EBQ_Artifact.esp")
                blacklist.add("entertainers.esp")
                blacklist.add("LeFemmArmor.esp")
                blacklist.add("master_index.esp")
                blacklist.add("Siege at Firemoth.esp")
            }

            modFiles?.forEach {
                if (!blacklist.contains(it.name)) {
                    fsNames.add(it.name)
                }
            }
        }

        val dbNames = dbMods.mapTo(mutableSetOf()) { it.filename }

        // Mods present in both the DB and on disk.
        dbMods.filter { fsNames.contains(it.filename) }.forEach {
            mods.add(it)
        }

        // New mods are appended after the current maximum load order.
        var maxOrder = mods.maxOfOrNull { it.order } ?: 0

        val newMods = arrayListOf<Mod>()
        (fsNames - dbNames).forEach {
            maxOrder += 1
            val mod = Mod(type, it, maxOrder, false)
            newMods.add(mod)
            mods.add(mod)
        }

        database.beginTransaction()
        try {
            // Delete mods which remain in the DB but no longer exist on disk.
            (dbNames - fsNames).forEach {
                database.delete(
                    "mod",
                    "type = ? AND filename = ?",
                    arrayOf(type.v.toString(), it)
                )
            }

            // Insert newly discovered mods.
            newMods.forEach { it.insert(database) }

            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }

        mods.sortBy { it.order }
    }

    /**
     * Performs DB updates for all mods marked as dirty.
     */
    fun update() {
        val database = db.writableDatabase
        database.beginTransaction()

        try {
            mods.filter { it.dirty }.forEach {
                it.update(database)
                it.dirty = false
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }
}
