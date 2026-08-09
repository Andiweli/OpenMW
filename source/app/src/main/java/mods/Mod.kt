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

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase

enum class ModType(val v: Int) {
    Plugin(1),
    Resource(2),
    Dir(3),
    Groundcover(4);

    companion object {
        private val reverseValues: Map<Int, ModType> = values().associate { it.v to it }

        fun valueFrom(i: Int): ModType = reverseValues.getValue(i)
    }
}

/**
 * Representation of a single mod in the database
 * @param type Type of the mod: plugin or resource
 * @param filename Filename of the mod, without the path
 * @param order Load order, or order in the list
 * @param enabled Whether the mod is enabled
 */
class Mod(val type: ModType, val filename: String, var order: Int, var enabled: Boolean) {

    /// Set to true when DB update is needed to keep consistency
    var dirty: Boolean = false

    /**
     * Updates the representation of this mod in the database
     * @param db Database connection
     */
    fun update(db: SQLiteDatabase) {
        val values = ContentValues().apply {
            put("load_order", order)
            put("enabled", if (enabled) 1 else 0)
        }

        db.update(
            "mod",
            values,
            "filename = ? AND type = ?",
            arrayOf(filename, type.v.toString())
        )
    }

    /**
     * Inserts this mod into the database
     * @param db Database connection
     */
    fun insert(db: SQLiteDatabase) {
        val values = ContentValues().apply {
            put("type", type.v)
            put("filename", filename)
            put("load_order", order)
            put("enabled", if (enabled) 1 else 0)
        }

        db.insert("mod", null, values)
    }

    companion object {
        fun fromCursor(cursor: Cursor): Mod {
            return Mod(
                ModType.valueFrom(cursor.getInt(cursor.getColumnIndexOrThrow("type"))),
                cursor.getString(cursor.getColumnIndexOrThrow("filename")),
                cursor.getInt(cursor.getColumnIndexOrThrow("load_order")),
                cursor.getInt(cursor.getColumnIndexOrThrow("enabled")) != 0
            )
        }
    }
}
