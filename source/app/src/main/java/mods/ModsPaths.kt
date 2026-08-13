/*
    Copyright (C) 2026 OpenMW-Android contributors

    This file is part of OpenMW-Android.

    OpenMW-Android is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
*/

package mods

import android.content.Context
import file.GameInstaller
import java.io.File

/** Shared path handling for the launcher mod manager and openmw.cfg writer. */
object ModsPaths {

    /** Root directory that contains the game's Data Files directory. */
    fun gameRoot(ctx: Context): File {
        val dataFiles = GameInstaller.getDataFilesFile(ctx)
        return dataFiles.parentFile ?: File("")
    }

    /** Path list used by the Directories tab. */
    fun directoryRoots(ctx: Context): ArrayList<String> =
        arrayListOf(gameRoot(ctx).absolutePath)

    /**
     * Returns the base Data Files directory plus every additional directory
     * next to it. This is used by the mod manager so enable/load-order state
     * is preserved even while an additional data directory is disabled.
     */
    fun allDataDirectories(ctx: Context): ArrayList<String> {
        val dataFiles = GameInstaller.getDataFilesFile(ctx)
        val result = arrayListOf(dataFiles.absolutePath)
        val root = dataFiles.parentFile ?: return result

        root.listFiles()
            ?.asSequence()
            ?.filter { it.isDirectory }
            ?.filterNot { it.absoluteFile == dataFiles.absoluteFile }
            ?.mapTo(result) { it.absolutePath }

        return result
    }

    /**
     * Returns the base Data Files directory plus only additional data
     * directories that are enabled in the launcher.
     */
    fun activeDataDirectories(
        ctx: Context,
        db: ModsDatabaseOpenHelper = ModsDatabaseOpenHelper.getInstance(ctx)
    ): ArrayList<String> {
        val dataFiles = GameInstaller.getDataFilesFile(ctx)
        val result = arrayListOf(dataFiles.absolutePath)
        val root = dataFiles.parentFile ?: return result

        val directories = ModsCollection(
            ModType.Dir,
            arrayListOf(root.absolutePath),
            db
        )

        directories.mods
            .asSequence()
            .filter { it.enabled }
            .map { File(root, it.filename) }
            .filter { it.isDirectory }
            .mapTo(result) { it.absolutePath }

        return result
    }

    /** Returns true if [filename] is present in at least one active data directory. */
    fun fileExistsIn(filename: String, dataDirectories: Collection<String>): Boolean =
        dataDirectories.any { File(it, filename).isFile }
}
