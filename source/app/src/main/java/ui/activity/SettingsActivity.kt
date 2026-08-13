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
import android.app.AlertDialog
import com.google.android.material.tabs.TabLayout
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import file.GameInstaller
import android.view.MenuItem
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import java.io.File
import java.util.Locale
import kotlin.math.round


import android.content.SharedPreferences
import android.content.SharedPreferences.OnSharedPreferenceChangeListener
import android.content.Intent
import android.preference.EditTextPreference
import android.preference.Preference
import android.preference.ListPreference
import android.preference.PreferenceFragment
import android.preference.PreferenceGroup

class FragmentGameSettings : PreferenceFragment() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        addPreferencesFromResource(R.xml.game_settings)

        // Every entry on this page opens a child settings screen.
        listOf(
            "game_settings_game_mechanics",
            "game_settings_visuals",
            "game_settings_shadows",
            "game_settings_animations",
            "game_settings_interface",
            "game_settings_engine"
        ).forEach { key ->
            findPreference(key)?.widgetLayoutResource = R.layout.preference_widget_chevron
        }
/*
        findPreference("game_settings_game_mechanics").setOnPreferenceClickListener {
            getPreferenceScreen().removeAll()
            addPreferencesFromResource(R.xml.gs_game_mechanics)
            true
        }

        findPreference("game_settings_visuals").setOnPreferenceClickListener {
            getPreferenceScreen().removeAll()
            addPreferencesFromResource(R.xml.gs_visuals)
            true
        }
*/
        findPreference("game_settings_game_mechanics").setOnPreferenceClickListener {
            val intent = Intent(activity, Game_Mechanics_SettingsActivity::class.java)
            this.startActivity(intent)
            true
        }

        findPreference("game_settings_visuals").setOnPreferenceClickListener {
            val intent = Intent(activity, Visuals_SettingsActivity::class.java)
            this.startActivity(intent)
            true
        }

        findPreference("game_settings_shadows").setOnPreferenceClickListener {
            val intent = Intent(activity, Shadows_SettingsActivity::class.java)
            this.startActivity(intent)
            true
        }

        findPreference("game_settings_animations").setOnPreferenceClickListener {
            val intent = Intent(activity, Animations_SettingsActivity::class.java)
            this.startActivity(intent)
            true
        }

        findPreference("game_settings_interface").setOnPreferenceClickListener {
            val intent = Intent(activity, Interface_SettingsActivity::class.java)
            this.startActivity(intent)
            true
        }

        findPreference("game_settings_engine").setOnPreferenceClickListener {
            val intent = Intent(activity, Engine_SettingsActivity::class.java)
            this.startActivity(intent)
            true
        }
    }
}

class SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))

        // Enable the "back" icon in the action bar
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
/*
        // Switch tabs between categories
        settings_tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {	
                settings_flipper.displayedChild = tab.position
            }

            override fun onTabUnselected(tab: TabLayout.Tab) {
            }

            override fun onTabReselected(tab: TabLayout.Tab) {
            }
        })
*/

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettings())
                .commit()
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

class FragmentGameSettingsPage : PreferenceFragment(), OnSharedPreferenceChangeListener {
    private var pageResource: Int = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        pageResource = arguments?.getInt(ARG_PAGE_RESOURCE, 0) ?: 0
        if (pageResource == 0) {
            throw IllegalStateException("Missing settings page resource")
        }

        addPreferencesFromResource(pageResource)
        preferenceScreen.sharedPreferences.registerOnSharedPreferenceChangeListener(this)

        if (pageResource == R.xml.gs_game_mechanics) {
            findPreference("gs_always_allow_npc_to_follow_over_water_surface").isEnabled =
                preferenceScreen.sharedPreferences.getBoolean("gs_build_navmesh", true)

            val quicksavePreference = findPreference("gs_maximum_quicksaves") as ListPreference
            val storedQuicksaves = preferenceScreen.sharedPreferences
                .getString("gs_maximum_quicksaves", "1")
                ?.toIntOrNull() ?: 1
            val normalizedQuicksaves = storedQuicksaves.coerceIn(1, 3).toString()
            if (quicksavePreference.value != normalizedQuicksaves)
                quicksavePreference.value = normalizedQuicksaves
        }

        if (pageResource == R.xml.gs_visuals) {
            normalizeFloatPreference("gs_object_paging_min_size", 0.01f, 1.0f, 0.25f, 2)
            findPreference("gs_object_paging_min_size").setOnPreferenceClickListener {
                showSteppedSliderPreference(
                    key = "gs_object_paging_min_size",
                    title = findPreference("gs_object_paging_min_size").title.toString(),
                    minimum = 0.01f,
                    maximum = 1.0f,
                    step = 0.01f,
                    defaultValue = 0.25f,
                    decimals = 2
                )
                true
            }
        }

        if (pageResource == R.xml.gs_animations)
            updatePreference(preferenceScreen.sharedPreferences, "gs_use_additional_animation_sources")

        if (pageResource == R.xml.gs_engine) {
            updatePreference(preferenceScreen.sharedPreferences, "gs_build_navmesh")
            normalizeIntegerPreference("gs_navmesh_threads", 1, 8, 1)
            normalizeIntegerPreference("gs_physics_threads", 1, 8, 1)
            normalizeIntegerPreference("gs_preload_threads", 1, 8, 1)

            listOf(
                "gs_navmesh_threads",
                "gs_physics_threads",
                "gs_preload_threads"
            ).forEach { key ->
                findPreference(key).setOnPreferenceClickListener {
                    showSteppedSliderPreference(
                        key = key,
                        title = findPreference(key).title.toString(),
                        minimum = 1.0f,
                        maximum = 8.0f,
                        step = 1.0f,
                        defaultValue = 1.0f,
                        decimals = 0
                    )
                    true
                }
            }
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun normalizeIntegerPreference(key: String, minimum: Int, maximum: Int, defaultValue: Int) {
        val sharedPreferences = preferenceScreen.sharedPreferences
        val current = sharedPreferences.getString(key, null)?.toIntOrNull() ?: defaultValue
        val normalized = current.coerceIn(minimum, maximum).toString()
        if (sharedPreferences.getString(key, null) != normalized)
            sharedPreferences.edit().putString(key, normalized).apply()
    }

    private fun normalizeFloatPreference(
        key: String,
        minimum: Float,
        maximum: Float,
        defaultValue: Float,
        decimals: Int
    ) {
        val sharedPreferences = preferenceScreen.sharedPreferences
        val current = sharedPreferences.getString(key, null)?.toFloatOrNull() ?: defaultValue
        val normalizedValue = current.coerceIn(minimum, maximum)
        val normalized = String.format(Locale.ROOT, "%.${decimals}f", normalizedValue)
        if (sharedPreferences.getString(key, null) != normalized)
            sharedPreferences.edit().putString(key, normalized).apply()
    }

    private fun showSteppedSliderPreference(
        key: String,
        title: String,
        minimum: Float,
        maximum: Float,
        step: Float,
        defaultValue: Float,
        decimals: Int
    ) {
        val sharedPreferences = preferenceScreen.sharedPreferences
        val current = sharedPreferences.getString(key, null)
            ?.toFloatOrNull()
            ?.coerceIn(minimum, maximum)
            ?: defaultValue.coerceIn(minimum, maximum)

        val steps = round((maximum - minimum) / step).toInt()
        val initialProgress = round((current - minimum) / step)
            .toInt()
            .coerceIn(0, steps)

        fun valueForProgress(progress: Int): Float =
            (minimum + progress * step).coerceIn(minimum, maximum)

        fun formatValue(value: Float): String =
            if (decimals == 0) {
                round(value).toInt().toString()
            } else {
                String.format(Locale.ROOT, "%.${decimals}f", value)
            }

        val valueLabel = TextView(activity).apply {
            textSize = 18f
            gravity = Gravity.CENTER
            text = formatValue(valueForProgress(initialProgress))
        }

        val seekBar = SeekBar(activity).apply {
            max = steps
            progress = initialProgress
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar?, progress: Int, fromUser: Boolean) {
                    valueLabel.text = formatValue(valueForProgress(progress))
                }

                override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                override fun onStopTrackingTouch(bar: SeekBar?) = Unit
            })
        }

        val limits = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(
                TextView(activity).apply { text = formatValue(minimum) },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            )
            addView(
                TextView(activity).apply {
                    text = formatValue(maximum)
                    gravity = Gravity.END
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            )
        }

        val content = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(16), dp(24), dp(8))
            addView(
                valueLabel,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )
            addView(
                seekBar,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(8) }
            )
            addView(
                limits,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            )
        }

        AlertDialog.Builder(activity)
            .setTitle(title)
            .setView(content)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                sharedPreferences.edit()
                    .putString(key, formatValue(valueForProgress(seekBar.progress)))
                    .apply()
            }
            .show()
    }

    override fun onDestroy() {
        super.onDestroy()
        preferenceScreen.sharedPreferences.unregisterOnSharedPreferenceChangeListener(this)
    }

    override fun onSharedPreferenceChanged(sharedPreferences: SharedPreferences, key: String?) {
        if (key == null)
            return
        updatePreference(sharedPreferences, key)
    }

    private fun updatePreference(sharedPreferences: SharedPreferences, key: String) {

        if(key == "gs_use_additional_animation_sources") {
            findPreference("gs_weapon_sheating").isEnabled = sharedPreferences.getBoolean("gs_use_additional_animation_sources", false)
            findPreference("gs_shield_sheating").isEnabled = sharedPreferences.getBoolean("gs_use_additional_animation_sources", false)
        }

        if(key == "gs_build_navmesh") {
            findPreference("gs_write_navmesh").isEnabled = sharedPreferences.getBoolean("gs_build_navmesh", true)
            findPreference("gs_navmesh_threads").isEnabled = sharedPreferences.getBoolean("gs_build_navmesh", true)
        }
    }

    companion object {
        private const val ARG_PAGE_RESOURCE = "page_resource"

        fun newInstance(resource: Int): FragmentGameSettingsPage {
            return FragmentGameSettingsPage().apply {
                arguments = Bundle().apply {
                    putInt(ARG_PAGE_RESOURCE, resource)
                }
            }
        }
    }
}

class Game_Mechanics_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_game_mechanics))
                .commit()
        }
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

class Visuals_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_visuals))
                .commit()
        }
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

class Shadows_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_shadows))
                .commit()
        }
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

class Animations_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_animations))
                .commit()
        }
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

class Interface_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_interface))
                .commit()
        }
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

class Bug_Fixes_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_bug_fixes))
                .commit()
        }
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

class Miscellaneous_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_miscellaneous))
                .commit()
        }
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

class Engine_SettingsActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        setSupportActionBar(findViewById(R.id.settings_toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        if (savedInstanceState == null) {
            fragmentManager.beginTransaction()
                .replace(R.id.settings_frame, FragmentGameSettingsPage.newInstance(R.xml.gs_engine))
                .commit()
        }
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

