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

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

class ModsDatabaseOpenHelper private constructor(ctx: Context) :
    SQLiteOpenHelper(ctx, DATABASE_NAME, null, DATABASE_VERSION) {

    companion object {
        private const val DATABASE_NAME = "ModsDatabase"
        private const val DATABASE_VERSION = 1

        @Volatile
        private var instance: ModsDatabaseOpenHelper? = null

        fun getInstance(ctx: Context): ModsDatabaseOpenHelper {
            return instance ?: synchronized(this) {
                instance ?: ModsDatabaseOpenHelper(ctx.applicationContext).also {
                    instance = it
                }
            }
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS mod (
                type INTEGER,
                filename TEXT,
                load_order INTEGER,
                enabled INTEGER
            )
            """.trimIndent()
        )

        db.execSQL("CREATE INDEX IF NOT EXISTS mod_type ON mod(type)")
        db.execSQL("CREATE INDEX IF NOT EXISTS mod_filename ON mod(filename)")
        db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS mod_type_name ON mod(type, filename)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Database schema version 1 is unchanged from the original Anko implementation.
    }
}

// Access property for Context
val Context.database: ModsDatabaseOpenHelper
    get() = ModsDatabaseOpenHelper.getInstance(this)
