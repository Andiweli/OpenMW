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

package ui.activity

import android.os.Bundle
import android.view.MenuItem
import android.widget.ViewFlipper
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.tabs.TabLayout
import com.libopenmw.openmw.R
import mods.ModMoveCallback
import mods.ModType
import mods.ModsAdapter
import mods.ModsCollection
import mods.ModsPaths
import mods.database

class ModsActivity : AppCompatActivity() {

    val mPluginAdapter = ModsAdapter()
    val mResourceAdapter = ModsAdapter()
    val mDirAdapter = ModsAdapter()
    val mGroundcoverAdapter = ModsAdapter()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_mods)

        setSupportActionBar(findViewById(R.id.mods_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        val tabLayout = findViewById<TabLayout>(R.id.tabLayout)
        val flipper = findViewById<ViewFlipper>(R.id.flipper)

        tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {
                // Persist directory changes before rebuilding the other tabs.
                if (flipper.displayedChild == 2) {
                    mDirAdapter.collection.update()
                    updateModList()
                    mPluginAdapter.notifyDataSetChanged()
                    mResourceAdapter.notifyDataSetChanged()
                    mGroundcoverAdapter.notifyDataSetChanged()
                }

                flipper.displayedChild = tab.position
            }

            override fun onTabUnselected(tab: TabLayout.Tab) = Unit
            override fun onTabReselected(tab: TabLayout.Tab) = Unit
        })

        setupModList(findViewById(R.id.list_mods), ModType.Plugin)
        setupModList(findViewById(R.id.list_resources), ModType.Resource)
        setupModList(findViewById(R.id.list_dirs), ModType.Dir)
        setupModList(findViewById(R.id.list_groundcovers), ModType.Groundcover)

        updateModList()
    }

    override fun onDestroy() {
        // Persist each list before the Activity goes away. updateModList() must
        // not replace collections before dirty entries have been written.
        mPluginAdapter.collection.update()
        mResourceAdapter.collection.update()
        mDirAdapter.collection.update()
        mGroundcoverAdapter.collection.update()
        super.onDestroy()
    }

    /** Rebuilds mod lists from the base Data Files directory plus enabled data dirs. */
    private fun updateModList() {
        val dataFilesList = ModsPaths.allDataDirectories(this)
        mPluginAdapter.collection = ModsCollection(ModType.Plugin, dataFilesList, database)
        mResourceAdapter.collection = ModsCollection(ModType.Resource, dataFilesList, database)
        mGroundcoverAdapter.collection = ModsCollection(ModType.Groundcover, dataFilesList, database)
    }

    /** Connects a RecyclerView to the corresponding mod collection. */
    private fun setupModList(list: RecyclerView, type: ModType) {
        val dataFilesList = if (type == ModType.Dir) {
            ModsPaths.directoryRoots(this)
        } else {
            ModsPaths.allDataDirectories(this)
        }

        list.layoutManager = LinearLayoutManager(this).apply {
            orientation = RecyclerView.VERTICAL
        }

        val adapter = when (type) {
            ModType.Plugin -> mPluginAdapter
            ModType.Resource -> mResourceAdapter
            ModType.Dir -> mDirAdapter
            ModType.Groundcover -> mGroundcoverAdapter
        }

        adapter.collection = ModsCollection(type, dataFilesList, database)
        val touchHelper = ItemTouchHelper(ModMoveCallback(adapter))
        touchHelper.attachToRecyclerView(list)
        adapter.touchHelper = touchHelper
        list.adapter = adapter
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            android.R.id.home -> {
                onBackPressed()
                true
            }
            else -> super.onOptionsItemSelected(item)
        }
    }
}
