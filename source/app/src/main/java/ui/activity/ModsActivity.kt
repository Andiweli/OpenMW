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

import com.libopenmw.openmw.R

import androidx.appcompat.app.AppCompatActivity
import android.os.Bundle
import com.google.android.material.tabs.TabLayout
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import file.GameInstaller
import mods.*
import android.view.MenuItem
import android.widget.ViewFlipper
import java.io.File

class ModsActivity : AppCompatActivity() {

    val mPluginAdapter = ModsAdapter()
    val mResourceAdapter = ModsAdapter()
    val mDirAdapter = ModsAdapter()
    val mGroundcoverAdapter = ModsAdapter()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_mods)

        setSupportActionBar(findViewById(R.id.mods_toolbar))

        // Enable the "back" icon in the action bar
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        val tabLayout = findViewById<TabLayout>(R.id.tabLayout)
        val flipper = findViewById<ViewFlipper>(R.id.flipper)

        // Switch tabs between plugins/resources
        tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {

                // Reload mod list when moving from data dir tab
                if(flipper.displayedChild == 2) {
                    updateModList()
                    mPluginAdapter.notifyDataSetChanged()
                    mResourceAdapter.notifyDataSetChanged()
                    mGroundcoverAdapter.notifyDataSetChanged()
                }
		
                flipper.displayedChild = tab.position
            }

            override fun onTabUnselected(tab: TabLayout.Tab) {
            }

            override fun onTabReselected(tab: TabLayout.Tab) {
            }
        })

        // Set up adapters for the lists
        setupModList(findViewById(R.id.list_mods), ModType.Plugin)
        setupModList(findViewById(R.id.list_resources), ModType.Resource)
        setupModList(findViewById(R.id.list_dirs), ModType.Dir)
        setupModList(findViewById(R.id.list_groundcovers), ModType.Groundcover)

        updateModList()
    }

    override fun onDestroy() {
        super.onDestroy()
        updateModList()
    }

    private fun updateModList() {

	var dataFilesList = ArrayList<String>()
	dataFilesList.add(GameInstaller.getDataFiles(this))

	// Get list of enabled data directories
	var dataDirs = ArrayList<String>()
	var enabledDataDirs = ArrayList<String>()
	enabledDataDirs.add(GameInstaller.getDataFiles(this))
	dataDirs.add(GameInstaller.getDataFiles(this).dropLast(10))
	val availableDirs = ModsCollection(ModType.Dir, dataDirs, database)

	availableDirs.mods
	    .filter { it.enabled }
            .forEach { enabledDataDirs.add(it.filename) }

	File(GameInstaller.getDataFiles(this).dropLast(10)).listFiles().forEach {
	    if (!it.isFile() && enabledDataDirs.contains(it.getName()) )
	        dataFilesList.add(GameInstaller.getDataFiles(this).dropLast(10) + it.getName())
	}

        mPluginAdapter.collection = ModsCollection(ModType.Plugin, dataFilesList, database)
        mResourceAdapter.collection = ModsCollection(ModType.Resource, dataFilesList, database)
        mGroundcoverAdapter.collection = ModsCollection(ModType.Groundcover, dataFilesList, database)
    }

    /**
     * Connects a user-interface RecyclerView to underlying mod data on the disk
     * @param list The list displayed to the user
     * @param type Type of the mods this list will contain
     */
    private fun setupModList(list: RecyclerView, type: ModType) {

        // This is here just to auto-enable basic plugins (morrowind.esp...) it somehow dont work in updateModList :( 
	var dataFilesList = ArrayList<String>()

	if (type == ModType.Dir) 
            dataFilesList.add(GameInstaller.getDataFiles(this).dropLast(10))
	else {
	    dataFilesList.add(GameInstaller.getDataFiles(this))

	    File(GameInstaller.getDataFiles(this).dropLast(10)).listFiles().forEach {
	        if (!it.isFile())
	            dataFilesList.add(GameInstaller.getDataFiles(this).dropLast(10) + it.getName())
	    }
        }

        val linearLayoutManager = LinearLayoutManager(this)
        linearLayoutManager.orientation = RecyclerView.VERTICAL
        list.layoutManager = linearLayoutManager

	if (type == ModType.Plugin) {
	    mPluginAdapter.collection = ModsCollection(type, dataFilesList, database)
            val callback = ModMoveCallback(mPluginAdapter)
            val touchHelper = ItemTouchHelper(callback)
            touchHelper.attachToRecyclerView(list)
            mPluginAdapter.touchHelper = touchHelper
            list.adapter = mPluginAdapter
	}
	else if (type == ModType.Resource) {
	    mResourceAdapter.collection = ModsCollection(type, dataFilesList, database)
            val callback = ModMoveCallback(mResourceAdapter)
            val touchHelper = ItemTouchHelper(callback)
            touchHelper.attachToRecyclerView(list)
            mResourceAdapter.touchHelper = touchHelper
            list.adapter = mResourceAdapter
        }
        else if (type == ModType.Dir){
	    mDirAdapter.collection = ModsCollection(type, dataFilesList, database)
            val callback = ModMoveCallback(mDirAdapter)
            val touchHelper = ItemTouchHelper(callback)
            touchHelper.attachToRecyclerView(list)
            mDirAdapter.touchHelper = touchHelper
            list.adapter = mDirAdapter
        }
	else if (type == ModType.Groundcover){ 
	    mGroundcoverAdapter.collection = ModsCollection(type, dataFilesList, database)
            val callback = ModMoveCallback(mGroundcoverAdapter)
            val touchHelper = ItemTouchHelper(callback)
            touchHelper.attachToRecyclerView(list)
            mGroundcoverAdapter.touchHelper = touchHelper
            list.adapter = mGroundcoverAdapter
        }
    }

    /**
     * Makes the "back" icon in the actionbar perform the back operation
     */
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
