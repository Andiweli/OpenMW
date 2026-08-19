/*
    Copyright (C) 2015, 2016 sandstranger
    Copyright (C) 2018, 2019 Ilya Zhuravlev

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

import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.AlertDialog
import android.app.PendingIntent
import android.app.ProgressDialog
import android.content.*
import android.net.Uri
import android.os.Bundle
import android.preference.PreferenceManager
import android.system.ErrnoException
import android.system.Os
import android.util.DisplayMetrics
import com.google.android.material.floatingactionbutton.FloatingActionButton
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import android.util.Log
import android.view.Menu
import android.view.MenuItem
import android.widget.Toast
import com.bugsnag.android.Bugsnag

import com.libopenmw.openmw.BuildConfig
import com.libopenmw.openmw.R
import constants.Constants
import file.GameInstaller

import java.io.BufferedReader
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStreamReader

import file.utils.CopyFilesFromAssets
import mods.ModType
import mods.ModsCollection
import mods.ModsDatabaseOpenHelper
import mods.ModsPaths
import ui.fragments.FragmentSettings
import permission.PermissionHelper
import utils.MyApp
import utils.Utils.hideAndroidControls
import java.util.*

import android.util.Base64

import android.content.res.Configuration

class MainActivity : AppCompatActivity() {
    private lateinit var prefs: SharedPreferences

    // v14.3 Skip GUI launch + v14.4 no-flash behavior restored in v14.6.2
    private val skipGuiHandler =
        android.os.Handler(android.os.Looper.getMainLooper())
    private var skipGuiAutoLaunchPending = false
    private var skipGuiOverrideRequested = false
    private var skipGuiVolumeOverrideHeld = false
    private var skipGuiDirectLaunchActive = false

    private val skipGuiAutoLaunchRunnable = java.lang.Runnable {
        if (!skipGuiAutoLaunchPending || skipGuiOverrideRequested || isFinishing) {
            return@Runnable
        }

        skipGuiAutoLaunchPending = false
        skipGuiDirectLaunchActive = true
        Log.i(TAG, "Skip GUI: launching game directly after Volume Up override window.")
        checkStartGame()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Draw an opaque loading surface before the launcher hierarchy is inflated.
        // Together with MyTheme's black starting-window background this prevents
        // Android from presenting stale launcher/app pixels while MainActivity is
        // being created. Keep it on-screen for at least one display frame so the
        // user sees a deterministic "Loading" state before the launcher.
        window.setBackgroundDrawable(
            android.graphics.drawable.ColorDrawable(android.graphics.Color.BLACK)
        )
        setContentView(createOpaqueLoadingPanel())
        window.decorView.postDelayed({
            if (!isFinishing && !isDestroyed) {
                initializeLauncher(savedInstanceState)
            }
        }, 34L)
    }

    private fun initializeLauncher(savedInstanceState: Bundle?) {
        MyApp.app.defaultScaling = determineScaling()

        prefs = PreferenceManager.getDefaultSharedPreferences(this)

        // Only a fresh app launch may auto-skip. Activity recreation while the
        // launcher is already open must never unexpectedly start the game.
        // First-run Bugsnag consent takes precedence over direct launch.
        val bugsnagConsentMissing =
            MyApp.haveBugsnagApiKey &&
                prefs.getString("bugsnag_consent", "").isNullOrEmpty()

        skipGuiOverrideRequested = false
        skipGuiVolumeOverrideHeld = false
        skipGuiDirectLaunchActive = false
        skipGuiAutoLaunchPending =
            savedInstanceState == null &&
                prefs.getBoolean("pref_skip_gui", false) &&
                !bugsnagConsentMissing

        PermissionHelper.getWriteExternalStoragePermission(this@MainActivity)

        // Keep the opaque black Android starting window only for the short
        // pre-launcher loading phase. Once the launcher hierarchy is installed,
        // restore the stock themed background unless the explicit OLED launcher
        // design is selected.
        val launcherThemePreference = prefs.getInt(getString(R.string.theme), 0)
        setContentView(R.layout.main)
        if (launcherThemePreference == 3) {
            applyOledLauncherWindowBackground()
        } else {
            restoreOriginalLauncherWindowBackground()
        }
        migrateObjectPagingMinSizeDefault()
        migrateOpenMw050SettingsPreferences()
        migrateOpenMw051SettingsPreferences()

        if(launcherThemePreference == 0) AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
        else if(launcherThemePreference == 1) AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_NO)
        else AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_YES)

        fragmentManager.beginTransaction()
            .replace(R.id.content_frame, FragmentSettings()).commit()

        val launcherToolbar =
            findViewById<androidx.appcompat.widget.Toolbar>(R.id.main_toolbar)
        setSupportActionBar(launcherToolbar)
        applyLauncherSurfaceTheme(launcherToolbar)
        installUserConfigurationOverflow(launcherToolbar)

        val fab = findViewById<FloatingActionButton>(R.id.fab)
        fab.setOnClickListener { checkStartGame() }

        if (prefs.getString("bugsnag_consent", "")!! == "") {
            askBugsnagConsent()
        }

        if (skipGuiAutoLaunchPending) {
            // Preserve the existing no-flash Skip GUI behaviour after the normal
            // launcher layout has been constructed behind the startup screen.
            window.decorView.alpha = 0f
            Log.i(
                TAG,
                "Skip GUI armed: press/hold Volume Up during startup to show launcher."
            )
            skipGuiHandler.postDelayed(skipGuiAutoLaunchRunnable, 800L)
        }
    }

    private fun restoreOriginalLauncherWindowBackground() {
        // The startup panel deliberately paints the Window black before the launcher exists.
        // Once R.layout.main is installed, restore the Window background resolved from the
        // original MyTheme/AppCompat DayNight theme. Do not hard-code a grey here: this is
        // exactly the background the unmodified launcher inherited from its theme.
        val value = android.util.TypedValue()
        if (!theme.resolveAttribute(android.R.attr.windowBackground, value, true)) {
            window.setBackgroundDrawable(null)
            return
        }

        val background = when {
            value.resourceId != 0 -> resources.getDrawable(value.resourceId, theme)
            value.type in android.util.TypedValue.TYPE_FIRST_COLOR_INT..android.util.TypedValue.TYPE_LAST_COLOR_INT ->
                android.graphics.drawable.ColorDrawable(value.data)
            else -> null
        }
        window.setBackgroundDrawable(background)
    }

    private fun isOledLauncherTheme(): Boolean =
        prefs.getInt(getString(R.string.theme), 0) == 3

    private fun applyOledLauncherWindowBackground() {
        val black = android.graphics.Color.BLACK
        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(black))
        window.statusBarColor = black
        window.navigationBarColor = black
    }

    private fun applyLauncherSurfaceTheme(toolbar: androidx.appcompat.widget.Toolbar) {
        if (!isOledLauncherTheme()) {
            return
        }

        val black = android.graphics.Color.BLACK
        applyOledLauncherWindowBackground()
        findViewById<android.view.View>(R.id.drawer_layout)?.setBackgroundColor(black)
        findViewById<android.view.View>(R.id.content_frame)?.setBackgroundColor(black)
        toolbar.setBackgroundColor(black)
    }

    private fun createOpaqueLoadingPanel(): android.view.View {
        val density = resources.displayMetrics.density
        val spacing = (18f * density + 0.5f).toInt()
        val horizontalPadding = (28f * density + 0.5f).toInt()

        return android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            setPadding(horizontalPadding, spacing, horizontalPadding, spacing)
            setBackgroundColor(android.graphics.Color.BLACK)

            addView(android.widget.ProgressBar(this@MainActivity))
            addView(android.widget.TextView(this@MainActivity).apply {
                text = getString(R.string.launch_preparing)
                setTextColor(android.graphics.Color.WHITE)
                textSize = 16f
                gravity = android.view.Gravity.CENTER
                setPadding(0, spacing, 0, 0)
            })
        }
    }

    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) {
            if (skipGuiAutoLaunchPending &&
                event.action == android.view.KeyEvent.ACTION_DOWN) {
                skipGuiOverrideRequested = true
                skipGuiAutoLaunchPending = false
                skipGuiDirectLaunchActive = false
                skipGuiVolumeOverrideHeld = true
                skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)
                window.decorView.alpha = 1f

                Log.i(TAG, "Skip GUI overridden by Volume Up; launcher remains visible.")
                return true
            }

            if (skipGuiVolumeOverrideHeld) {
                if (event.action == android.view.KeyEvent.ACTION_UP) {
                    skipGuiVolumeOverrideHeld = false
                }
                return true
            }
        }

        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)
        skipGuiAutoLaunchPending = false
        super.onDestroy()
    }

    private fun revealLauncherAfterSkipGui(reason: String) {
        if (!skipGuiDirectLaunchActive && window.decorView.alpha >= 1f) {
            return
        }

        skipGuiDirectLaunchActive = false
        skipGuiAutoLaunchPending = false
        skipGuiHandler.removeCallbacks(skipGuiAutoLaunchRunnable)
        window.decorView.alpha = 1f
        Log.i(TAG, "Skip GUI: launcher restored ($reason).")
    }

    override fun onResume() {
        super.onResume()

        // Migrate the legacy /storage/emulated/0/omw user tree after the
        // Activity has had a chance to request legacy game-file storage
        // permission. On modern Android this is a no-op after migration.
        MyApp.app.migrateLegacyUserStorageIfPossible()
    }

    private fun migrateObjectPagingMinSizeDefault() {
        val valueKey = "gs_object_paging_min_size"
        val migrationKey = "migration_object_paging_min_size_025_v11"

        if (prefs.getBoolean(migrationKey, false)) {
            return
        }

        val current = prefs.getString(valueKey, null)
        val editor = prefs.edit()

        // v11 changes the Android preset default from OpenMW's 0.01 to 0.25.
        // Preserve any explicitly selected non-default value.
        if (current.isNullOrBlank() || current == "0.01") {
            editor.putString(valueKey, "0.25")
        }

        editor.putBoolean(migrationKey, true)
        editor.apply()
    }

    /**
     * Set new user consent and maybe restart the app
     * @param consent New value of bugsnag consent
     */
    @SuppressLint("ApplySharedPref")
    private fun setBugsnagConsent(consent: String) {
        val currentConsent = prefs.getString("bugsnag_consent", "")!!
        if (currentConsent == consent)
            return

        // We only need to force a restart if the user revokes their consent
        // If user grants consent, crashes won't be reported for 1 game session, but that's alright
        val needRestart = currentConsent == "true" && consent == "false"

        with (prefs.edit()) {
            putString("bugsnag_consent", consent)
            commit()
        }

        if (needRestart) {
            AlertDialog.Builder(this)
                .setOnDismissListener { System.exit(0) }
                .setTitle(R.string.bugsnag_consent_restart_title)
                .setMessage(R.string.bugsnag_consent_restart_message)
                .setPositiveButton(android.R.string.ok) { _, _ -> System.exit(0) }
                .show()
        }
    }

    /**
     * Opens the url in a web browser and gracefully handles the failure
     * @param url Url to open
     */
    fun openUrl(url: String) {
        try {
            val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            startActivity(browserIntent)
        } catch (e: ActivityNotFoundException) {
            AlertDialog.Builder(this)
                .setTitle(R.string.no_browser_title)
                .setMessage(getString(R.string.no_browser_message, url))
                .setPositiveButton(android.R.string.ok) { _, _ -> }
                .show()
        }
    }

    /**
     * Asks the user if they want to automatically report crashes
     */
    private fun askBugsnagConsent() {
        // Do nothing for builds without api-key
        if (!MyApp.haveBugsnagApiKey)
            return

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.bugsnag_consent_title)
            .setMessage(R.string.bugsnag_consent_message)
            .setNeutralButton(R.string.bugsnag_policy) { _, _ -> /* set up below */ }
            .setNegativeButton(R.string.bugsnag_no) { _, _ -> setBugsnagConsent("false") }
            .setPositiveButton(R.string.bugsnag_yes) { _, _ -> setBugsnagConsent("true") }
            .create()

        dialog.show()

        // don't close the dialog when the privacy-policy button is clicked
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
            openUrl("https://omw.xyz.is/privacy-policy.html")
        }
    }

    /**
     * Checks that the game is properly installed and if so, starts the game
     * - the game files must be selected
     * - there must be at least 1 activated mod (user can ignore this warning)
     */
    private fun checkStartGame() {
        // First, check that there are game files present
        val inst = GameInstaller(prefs.getString("game_files", "")!!)
        if (!inst.check()) {
            revealLauncherAfterSkipGui("game files need configuration")
            AlertDialog.Builder(this)
                .setTitle(R.string.no_data_files_title)
                .setMessage(R.string.no_data_files_message)
                .setNeutralButton(R.string.dialog_howto) { _, _ ->
                    openUrl("https://omw.xyz.is/game.html")
                }
                .setPositiveButton(android.R.string.ok) { _: DialogInterface, _: Int -> }
                .show()
            return
        }

        // Second, check if user has at least one mod enabled. Only scan the
        // base Data Files directory and additional data directories enabled by
        // the user; disabled directories must not leak plugins into the launch.
        val db = ModsDatabaseOpenHelper.getInstance(this)
        val allDataFilesList = ModsPaths.allDataDirectories(this)
        val activeDataFilesList = ModsPaths.activeDataDirectories(this, db)
        val plugins = ModsCollection(ModType.Plugin, allDataFilesList, db)
        if (plugins.mods.count { it.enabled && ModsPaths.fileExistsIn(it.filename, activeDataFilesList) } == 0) {
            // No mods enabled, show a warning
            revealLauncherAfterSkipGui("content selection needs confirmation")
            AlertDialog.Builder(this)
                .setTitle(R.string.no_content_files_title)
                .setMessage(R.string.no_content_files_message)
                .setNeutralButton(R.string.dialog_howto) { _, _ ->
                    openUrl("https://omw.xyz.is/mods.html")
                }
                .setNegativeButton(R.string.no_content_files_dismiss) { _, _ -> startGame() }
                .setPositiveButton(R.string.configure_mods) { _, _ ->
                    this.startActivity(Intent(this, ModsActivity::class.java))
                }
                .show()

            return
        }

        // If everything's alright, start the game
        startGame()
    }

    private fun deleteRecursive(fileOrDirectory: File) {
        if (fileOrDirectory.isDirectory) {
            fileOrDirectory.listFiles()?.forEach { child ->
                deleteRecursive(child)
            }
        }

        fileOrDirectory.delete()
    }

    private fun logConfig() {
        val config = File(Constants.OPENMW_CFG)
        Log.i(TAG, "OpenMW config path: ${config.absolutePath}; exists=${config.exists()}; size=${if (config.exists()) config.length() else 0}")

        if (!config.isFile) {
            return
        }

        try {
            val interestingPrefixes = listOf(
                "resources=",
                "data=",
                "content=",
                "groundcover=",
                "fallback-archive=",
                "encoding="
            )

            var logged = 0
            config.forEachLine { line ->
                val trimmed = line.trim()
                if (interestingPrefixes.any { trimmed.startsWith(it) }) {
                    if (logged < 120) {
                        Log.i("OpenMW-Config", trimmed)
                    }
                    logged += 1
                }
            }

            if (logged > 120) {
                Log.i("OpenMW-Config", "... ${logged - 120} additional config entries omitted")
            }
        } catch (e: IOException) {
            Log.e(TAG, "Failed to log generated openmw.cfg.", e)
        }
    }

    private fun runGame() {
        logConfig()

        val intent = Intent(this@MainActivity, GameActivity::class.java)
        startActivity(intent)
        finish()
    }


    /**
     * Set up fixed screen resolution
     * This doesn't do anything unless the user chose to override screen resolution
     */
    private fun obtainFixedScreenResolution() {
        // Split resolution e.g 640x480 to width/height
        val customResolution = prefs.getString("pref_customResolution", "")
        val sep = customResolution!!.indexOf("x")
        if (sep > 0) {
            try {
                val x = Integer.parseInt(customResolution.substring(0, sep))
                val y = Integer.parseInt(customResolution.substring(sep + 1))

                resolutionX = x
                resolutionY = y
            } catch (e: NumberFormatException) {
                // user entered resolution wrong, just ignore it
            }
        }
    }

    /**
     * Generates openmw.cfg using values from openmw.base.cfg combined with mod manager settings
     */
    private fun generateOpenmwCfg(): Boolean {
        // contents of openmw.base.cfg
        val base: String
        // contents of openmw.fallback.cfg
        val fallback: String

        // try to read the files
        try {
            base = File(Constants.OPENMW_BASE_CFG).readLines()
                .filterNot { it.trim() == "data=\"specify-me!\"" }
                .joinToString("\n", postfix = "\n")
            // TODO: support user custom options
            fallback = File(Constants.OPENMW_FALLBACK_CFG).readText()
        } catch (e: IOException) {
            Log.e(TAG, "Failed to read openmw.base.cfg or openmw.fallback.cfg", e)
            return false
        }

        val db = ModsDatabaseOpenHelper.getInstance(this)
        val allDataFilesList = ModsPaths.allDataDirectories(this)
        val activeDataFilesList = ModsPaths.activeDataDirectories(this, db)

        // Keep the database synchronized against every present directory so
        // disabled directories retain their enable/load-order state. Runtime
        // output below is restricted to active data directories only.
        val resources = ModsCollection(ModType.Resource, allDataFilesList, db)
        val plugins = ModsCollection(ModType.Plugin, allDataFilesList, db)
        val groundcovers = ModsCollection(ModType.Groundcover, allDataFilesList, db)

        try {
            // Generate final openmw.cfg without repeatedly reallocating a growing String.
            val output = buildString {
                append(base)
                append('\n')
                append(fallback)
                append('\n')

                resources.mods
                    .filter { it.enabled && ModsPaths.fileExistsIn(it.filename, activeDataFilesList) }
                    .forEach { append("fallback-archive=${it.filename}\n") }

                // The base Data Files path must be first. startGame() later
                // rewrites the first data= line for compatibility; keeping the
                // base path first prevents that write from replacing an enabled
                // additional data directory.
                activeDataFilesList
                    .map(::File)
                    .filter { it.isDirectory }
                    .forEach { append("data=\"${it.absolutePath}\"\n") }

                plugins.mods
                    .filter { it.enabled && ModsPaths.fileExistsIn(it.filename, activeDataFilesList) }
                    .forEach { append("content=${it.filename}\n") }

                groundcovers.mods
                    .filter { it.enabled && ModsPaths.fileExistsIn(it.filename, activeDataFilesList) }
                    .forEach { append("groundcover=${it.filename}\n") }
            }

            // Write only the real launcher configuration. Keep unrelated
            // legacy side writes out of this code path; on ChromeOS a failed
            // secondary write must never invalidate a valid openmw.cfg.
            val configFile = File(Constants.OPENMW_CFG)
            configFile.parentFile?.mkdirs()
            configFile.writeText(output)
            Log.i(TAG, "Generated openmw.cfg at ${configFile.absolutePath}; size=${configFile.length()}")
            return configFile.isFile && configFile.length() > 0
        } catch (e: IOException) {
            Log.e(TAG, "Failed to generate openmw.cfg.", e)
            return false
        }
    }

    /**
     * Determines required screen scaling based on resolution and physical size of the device
     */
    private fun determineScaling(): Float {
        // The idea is to stretch an old-school 1024x768 monitor to the device screen
        // Assume that 1x scaling corresponds to resolution of 1024x768
        // Assume that the longest side of the device corresponds to the 1024 side
        // Therefore scaling is calculated as longest size of the device divided by 1024
        // Note that it doesn't take into account DPI at all. Which is fine for now, but in future
        // we might want to add some bonus scaling to e.g. phone devices so that it's easier
        // to click things.

        val dm = DisplayMetrics()
        windowManager.defaultDisplay.getMetrics(dm)
        return maxOf(dm.heightPixels, dm.widthPixels) / 1024.0f
    }

    /**
     * Checks whether the OpenMW runtime payload was successfully deployed.
     */
    private fun staticFilesInstalled(): Boolean {
        val fullscreenShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/fullscreen_tri.vert"
        )
        val shadowShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/shadowcasting.vert"
        )
        val shadowFragmentShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/shadows_fragment.glsl"
        )
        val debugVert = File(
            Constants.RESOURCES,
            "shaders/compatibility/debug.vert"
        )
        val debugFrag = File(
            Constants.RESOURCES,
            "shaders/compatibility/debug.frag"
        )
        val objectsVertexShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/objects.vert"
        )
        val objectsFragmentShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/objects.frag"
        )
        val terrainVertexShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/terrain.vert"
        )
        val terrainFragmentShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/terrain.frag"
        )
        val groundcoverVertexShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/groundcover.vert"
        )
        val bsDefaultVertexShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/bs/default.vert"
        )
        val bsDefaultFragmentShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/bs/default.frag"
        )
        val bsNoLightingVertexShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/bs/nolighting.vert"
        )
        val fogShader = File(
            Constants.RESOURCES,
            "shaders/compatibility/fog.glsl"
        )
        val coreVertexHeader = File(
            Constants.RESOURCES,
            "shaders/lib/core/vertex.h.glsl"
        )
        val coreFragmentHeader = File(
            Constants.RESOURCES,
            "shaders/lib/core/fragment.h.glsl"
        )
        val esmFallbacksScript = File(
            Constants.RESOURCES,
            "vfs-mw/scripts/omw/esmfallbacks.lua"
        )
        val bundledAdjustments = File(
            Constants.RESOURCES,
            "vfs/shaders/adjustments.omwfx"
        )

        if (!File(Constants.DEFAULTS_BIN).isFile ||
            !File(Constants.OPENMW_BASE_CFG).isFile ||
            !File(Constants.RESOURCES).isDirectory ||
            !File(Constants.RESOURCES, "version").isFile ||
            !fullscreenShader.isFile ||
            !shadowShader.isFile ||
            !shadowFragmentShader.isFile ||
            !debugVert.isFile ||
            !debugFrag.isFile ||
            !objectsVertexShader.isFile ||
            !objectsFragmentShader.isFile ||
            !terrainVertexShader.isFile ||
            !terrainFragmentShader.isFile ||
            !groundcoverVertexShader.isFile ||
            !bsDefaultVertexShader.isFile ||
            !bsDefaultFragmentShader.isFile ||
            !bsNoLightingVertexShader.isFile ||
            !fogShader.isFile ||
            !coreVertexHeader.isFile ||
            !coreFragmentHeader.isFile ||
            !esmFallbacksScript.isFile ||
            !bundledAdjustments.isFile) {
            return false
        }

        return try {
            val resourceVersion = File(Constants.RESOURCES, "version").readText().trim()
            val shadowFragmentText = shadowFragmentShader.readText()
            val objectsVertexText = objectsVertexShader.readText()
            val objectsFragmentText = objectsFragmentShader.readText()
            val terrainVertexText = terrainVertexShader.readText()
            val terrainFragmentText = terrainFragmentShader.readText()
            val groundcoverVertexText = groundcoverVertexShader.readText()
            val bsDefaultVertexText = bsDefaultVertexShader.readText()
            val bsDefaultFragmentText = bsDefaultFragmentShader.readText()
            val bsNoLightingVertexText = bsNoLightingVertexShader.readText()
            val fogShaderText = fogShader.readText()
            val coreVertexText = coreVertexHeader.readText()
            val coreFragmentText = coreFragmentHeader.readText()

            resourceVersion.startsWith("0.51.0") &&
                !fullscreenShader.readText().contains("uniform vec2 scaling =") &&
                !shadowShader.readText().contains("uniform bool useDiffuseMapForShadowAlpha =") &&
                !shadowShader.readText().contains("uniform bool alphaTestShadows =") &&
                !debugVert.readText().contains("uniform bool useAdvancedShader =") &&
                !debugFrag.readText().contains("uniform bool useAdvancedShader =") &&
                objectsFragmentText.contains("OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG") &&
                objectsFragmentText.contains("OPENMW_ANDROID_051_LOCALMAP_OBJECT_FOG_BYPASS_V1") &&
                // Patch 8 ports only the proven OpenMW-0.50 Android/GL4ES
                // normal-transform compatibility substitutions. Avoid direct
                // gl_NormalMatrix * passNormal in these 0.51 shader stages.
                objectsVertexText.contains("vec3 viewNormal = normalToView(passNormal);") &&
                objectsFragmentText.contains("vec3 viewNormal = normalToView(normalize(passNormal));") &&
                terrainVertexText.contains("vec3 viewNormal = normalToView(passNormal);") &&
                terrainFragmentText.contains("vec3 viewNormal = normalToView(normalize(passNormal));") &&
                groundcoverVertexText.contains("vec3 viewNormal = normalToView(passNormal);") &&
                bsDefaultVertexText.contains("vec3 viewNormal = normalToView(passNormal);") &&
                bsDefaultFragmentText.contains("vec3 viewNormal = normalToView(normalize(passNormal));") &&
                bsNoLightingVertexText.contains("vec3 viewNormal = normalize((gl_NormalMatrix * gl_Normal).xyz);") &&
                fogShaderText.contains("OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG") &&
                fogShaderText.contains("uniform float omwFogStart") &&
                fogShaderText.contains("uniform float omwFogEnd") &&
                // GL4ES on the Retroid/Adreno path cannot link OpenMW 0.51's
                // helper-only shader objects. Patch 4 keeps the public helper
                // API but inlines the implementations into the include headers.
                !coreVertexText.contains("@link") &&
                coreVertexText.contains("OPENMW_ANDROID_051_GL4ES_CORE_INLINE") &&
                coreVertexText.contains("vec4 modelToClip(vec4 pos)") &&
                !coreFragmentText.contains("@link") &&
                coreFragmentText.contains("OPENMW_ANDROID_051_GL4ES_CORE_INLINE") &&
                coreFragmentText.contains("vec4 sampleReflectionMap(vec2 uv)") &&
                // Patch 12 / Gate F: GLES2 depth textures are sampled as regular
                // sampler2D values and compared manually; the casting shader also
                // uses normal GLES2 near/far clipping instead of emulating GL_DEPTH_CLAMP.
                shadowFragmentText.contains("OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE") &&
                shadowFragmentText.contains("OPENMW_ANDROID_051_GLES2_QUALITY_PCF") &&
                !shadowFragmentText.contains("uniform sampler2DShadow") &&
                !shadowFragmentText.contains("shadow2DProj(") &&
                shadowShader.readText().contains("OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING")
        } catch (e: IOException) {
            false
        }
    }

    /**
     * Removes old and creates new files located in private application directories
     * (i.e. under getFilesDir(), or /data/data/.../files)
     */
    private fun reinstallStaticFiles() {
        // we store global "config" and "resources" under private files

        // wipe old version first
        removeStaticFiles()

        // copy in the new version
        val assetCopier = CopyFilesFromAssets(this)
        assetCopier.copy("libopenmw/resources", Constants.RESOURCES)
        assetCopier.copy("libopenmw/openmw", Constants.GLOBAL_CONFIG)

        // The non-OMWFX path uses OpenMW 0.51's bundled adjustments.omwfx.
        // The standalone Android/OMWFX shader assets remain isolated and are
        // still not copied into OpenMW's VFS during this gate.

        if (!staticFilesInstalled()) {
            throw IOException(
                "OpenMW runtime assets are missing from this APK. " +
                    "Run tools/bootstrap-openmw-arm64.ps1 or buildscripts/build.sh before building the APK."
            )
        }

        // set up user config (if not present)
        File(Constants.USER_CONFIG).mkdirs()
        if (!File(Constants.USER_OPENMW_CFG).exists())
            File(Constants.USER_OPENMW_CFG).writeText("# This is the user openmw.cfg. Feel free to modify it as you wish.\n")

        // create user custom icon folder as a hint
        File(Constants.USER_FILE_STORAGE + "/icons").mkdirs()
        if (!File(Constants.USER_FILE_STORAGE + "/icons/paste custom icons here.txt").exists())
            File(Constants.USER_FILE_STORAGE + "/icons/paste custom icons here.txt").writeText(
"attack.png \ninventory.png \njournal.png \njump.png \nkeyboard.png \nmouse.png \npause.png \npointer_arrow.png \nrun.png \nsave.png \nsneak.png \nthird_person.png \ntoggle_magic.png \ntoggle_weapon.png \ntoggle.png \nuse.png \nwait.png")

        // set version stamp
        File(Constants.VERSION_STAMP).writeText(BuildConfig.VERSION_CODE.toString())
    }

    /**
     * Removes global static files, these include resources and config
     */
    private fun removeStaticFiles() {
        // remove version stamp so that reinstallStaticFiles is called during game launch
        File(Constants.VERSION_STAMP).delete()

        deleteRecursive(File(Constants.GLOBAL_CONFIG))
        deleteRecursive(File(Constants.RESOURCES))
    }

    /**
     * Resets user config to default values by removing it
     */
    private fun removeUserConfig() {
        deleteRecursive(File(Constants.USER_CONFIG))
    }

    /**
     * Reset user resource files to default
     */
    private fun removeResourceFiles() {
        reinstallStaticFiles()
        deleteRecursive(File(Constants.USER_FILE_STORAGE + "/resources/"))

        val src = File(Constants.RESOURCES)
        val dst = File(Constants.USER_FILE_STORAGE + "/resources/")
        dst.mkdirs()
        src.copyRecursively(dst, true)
    }

    private fun resourcePayloadMatches(source: File, target: File): Boolean {
        if (!source.isDirectory || !target.isDirectory) {
            return false
        }

        val sourceVersion = File(source, "version")
        val targetVersion = File(target, "version")
        val sourceLogo = File(source, "openmw.png")
        val targetLogo = File(target, "openmw.png")
        val sourceEsmFallbacks = File(source, "vfs-mw/scripts/omw/esmfallbacks.lua")
        val targetEsmFallbacks = File(target, "vfs-mw/scripts/omw/esmfallbacks.lua")

        if (!sourceVersion.isFile || !targetVersion.isFile ||
            !sourceLogo.isFile || !targetLogo.isFile ||
            !sourceEsmFallbacks.isFile || !targetEsmFallbacks.isFile) {
            return false
        }

        return try {
            sourceVersion.readText().trim() == targetVersion.readText().trim() &&
                sourceVersion.readText().trim().startsWith("0.51.0") &&
                sourceLogo.length() == targetLogo.length() &&
                sourceEsmFallbacks.length() == targetEsmFallbacks.length()
        } catch (e: IOException) {
            false
        }
    }

    /**
     * The original CaveBros launcher runs OpenMW against the writable resource
     * mirror under USER_FILE_STORAGE. Older installs can leave that mirror
     * incomplete or from another engine revision. In that case OpenMW starts,
     * but reports that the resource directory does not match the binary and can
     * remain on a black screen.
     *
     * Only rebuild the mirror when it is demonstrably incomplete/mismatched so
     * valid user-customised resources are preserved during normal launches.
     */
    private fun ensureUserResourcesCurrent() {
        val source = File(Constants.RESOURCES)
        val target = File(Constants.USER_FILE_STORAGE + "/resources/")

        if (!source.isDirectory) {
            throw IOException("Bundled OpenMW resources are missing: ${source.absolutePath}")
        }

        if (!resourcePayloadMatches(source, target)) {
            Log.w(TAG, "User OpenMW resources are incomplete or mismatched; rebuilding ${target.absolutePath}")
            deleteRecursive(target)
            target.parentFile?.mkdirs()

            if (!source.copyRecursively(target, overwrite = true)) {
                throw IOException("Failed to rebuild OpenMW user resources at ${target.absolutePath}")
            }

            if (!resourcePayloadMatches(source, target)) {
                throw IOException("OpenMW user resources still do not match the bundled runtime after rebuild")
            }
        }

        syncAndroidShaderCompatibilityResources()
    }

    /**
     * OpenMW 0.51 adds engine-owned Morrowind compatibility scripts below
     * resources/vfs-mw. CaveBros historically stripped every data= line from
     * the generated base config, which also removed this new internal path.
     * Insert it before user/game data paths so engine fallbacks are loaded first
     * while mods can still override them afterwards.
     */
    private fun ensureOpenMw051InternalDataPath() {
        val configFile = File(Constants.OPENMW_CFG)
        if (!configFile.isFile) {
            throw IOException("OpenMW config is missing before vfs-mw migration: ${configFile.absolutePath}")
        }

        val internalPath = Constants.USER_FILE_STORAGE + "/resources/vfs-mw"
        val internalLine = "data=\"$internalPath\""
        val original = configFile.readLines()
        val filtered = original.filterNot { line ->
            val trimmed = line.trim()
            trimmed.startsWith("data=") && trimmed.contains("/resources/vfs-mw")
        }.toMutableList()

        val firstData = filtered.indexOfFirst { it.trim().startsWith("data=") }
        if (firstData >= 0) {
            filtered.add(firstData, internalLine)
        } else {
            filtered.add(internalLine)
        }

        configFile.writeText(filtered.joinToString("\n", postfix = "\n"))

        val fallbackScript = File(internalPath, "scripts/omw/esmfallbacks.lua")
        if (!fallbackScript.isFile) {
            throw IOException("OpenMW 0.51 vfs-mw fallback script is missing: ${fallbackScript.absolutePath}")
        }

        Log.i(TAG, "OpenMW 0.51 internal data path enabled: $internalPath")
    }

    private fun syncAndroidShaderCompatibilityResources() {
        // VERSION_CODE can stay unchanged between development APK rebuilds.
        // Refresh the Patch-12 GL4ES compatibility + shadow shader set from the APK on every launch so
        // the private tree and writable user mirror cannot retain stale 0.50/0.51 files.
        val coreRelativePaths = listOf(
            "shaders/compatibility/fullscreen_tri.vert",
            "shaders/compatibility/shadowcasting.vert",
            "shaders/compatibility/shadows_fragment.glsl",
            "shaders/compatibility/debug.vert",
            "shaders/compatibility/debug.frag",
            "shaders/compatibility/objects.vert",
            "shaders/compatibility/objects.frag",
            "shaders/compatibility/terrain.vert",
            "shaders/compatibility/terrain.frag",
            "shaders/compatibility/groundcover.vert",
            "shaders/compatibility/groundcover.frag",
            "shaders/compatibility/water.vert",
            "shaders/compatibility/water.frag",
            "shaders/compatibility/bs/default.vert",
            "shaders/compatibility/bs/default.frag",
            "shaders/compatibility/bs/nolighting.vert",
            "shaders/compatibility/bs/nolighting.frag",
            "shaders/compatibility/fog.glsl",
            "shaders/lib/core/vertex.h.glsl",
            "shaders/lib/core/fragment.h.glsl"
        )

        coreRelativePaths.forEach { relativePath ->
            val assetPath = "libopenmw/resources/$relativePath"
            val privateTarget = File(Constants.RESOURCES, relativePath)
            val userTarget = File(Constants.USER_FILE_STORAGE + "/resources/", relativePath)

            privateTarget.parentFile?.mkdirs()
            userTarget.parentFile?.mkdirs()

            if (relativePath == "shaders/compatibility/shadows_fragment.glsl") {
                // The bundled receiver is a valid Medium-quality shader. Before
                // each launch specialize its compile-time GLES2 PCF constants
                // to the currently selected shadow quality. This keeps the
                // stable one-map Android path while avoiding runtime loops,
                // textureSize() (not available on GLES2) or native uniforms.
                val bundledShadowShader = assets.open(assetPath).bufferedReader(Charsets.UTF_8).use {
                    it.readText()
                }
                val specializedShadowShader = specializeAndroidShadowShader(bundledShadowShader)
                privateTarget.writeText(specializedShadowShader, Charsets.UTF_8)
                userTarget.writeText(specializedShadowShader, Charsets.UTF_8)
            } else {
                assets.open(assetPath).use { input ->
                    privateTarget.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                privateTarget.copyTo(userTarget, overwrite = true)
            }
        }

        // Publish only the device-proven OpenMW 0.51 Android OMWFX stack.
        // WetWorld runs before the optical passes, RainLens runs last, and the
        // native water-alpha marker excludes actual water from WetWorld.
        val bloomShader = "gateh_bloom051.omwfx"
        val bloomPrivateTarget = File(Constants.RESOURCES, "vfs/shaders/$bloomShader")
        val bloomUserTarget = File(
            Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/",
            bloomShader
        )

        bloomPrivateTarget.parentFile?.mkdirs()
        assets.open("android_omwfx/$bloomShader").use { input ->
            bloomPrivateTarget.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        bloomUserTarget.parentFile?.mkdirs()
        bloomPrivateTarget.copyTo(bloomUserTarget, overwrite = true)

        val lensflareShader = "lensflare_android_051_rayocc.omwfx"
        val lensflarePrivateTarget = File(Constants.RESOURCES, "vfs/shaders/$lensflareShader")
        val lensflareUserTarget = File(
            Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/",
            lensflareShader
        )

        lensflarePrivateTarget.parentFile?.mkdirs()
        assets.open("android_omwfx/$lensflareShader").use { input ->
            lensflarePrivateTarget.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        lensflareUserTarget.parentFile?.mkdirs()
        lensflarePrivateTarget.copyTo(lensflareUserTarget, overwrite = true)

        val godraysShader = "godrays_android_051_depthfixed_vivid.omwfx"
        val godraysPrivateTarget = File(Constants.RESOURCES, "vfs/shaders/$godraysShader")
        val godraysUserTarget = File(
            Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/",
            godraysShader
        )

        godraysPrivateTarget.parentFile?.mkdirs()
        assets.open("android_omwfx/$godraysShader").use { input ->
            godraysPrivateTarget.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        godraysUserTarget.parentFile?.mkdirs()
        godraysPrivateTarget.copyTo(godraysUserTarget, overwrite = true)

        val rainLensShader = "rainlens_android_051_v12_dense.omwfx"
        val rainLensPrivateTarget = File(Constants.RESOURCES, "vfs/shaders/$rainLensShader")
        val rainLensUserTarget = File(
            Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/",
            rainLensShader
        )

        rainLensPrivateTarget.parentFile?.mkdirs()
        assets.open("android_omwfx/$rainLensShader").use { input ->
            rainLensPrivateTarget.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        rainLensUserTarget.parentFile?.mkdirs()
        rainLensPrivateTarget.copyTo(rainLensUserTarget, overwrite = true)

        val wetWorldShader = "wetworld_android_051_weather.omwfx"
        val wetWorldPrivateTarget = File(Constants.RESOURCES, "vfs/shaders/$wetWorldShader")
        val wetWorldUserTarget = File(
            Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/",
            wetWorldShader
        )

        wetWorldPrivateTarget.parentFile?.mkdirs()
        assets.open("android_omwfx/$wetWorldShader").use { input ->
            wetWorldPrivateTarget.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        wetWorldUserTarget.parentFile?.mkdirs()
        wetWorldPrivateTarget.copyTo(wetWorldUserTarget, overwrite = true)

        // Remove obsolete development techniques so shaders.yaml cannot bind
        // stale values to superseded uniforms.
        val obsoleteAndroidOmwfxShaders = listOf(
            "gateh_probe.omwfx",
            "bloomlinear_android.omwfx",
            "lensflare_android.omwfx",
            "lensflare_android_051.omwfx",
            "lensflare_android_051_occ.omwfx",
            "lensflare_android_051_depthocc.omwfx",
            "lensflare_android_051_h2f.omwfx",
            "godrays_android.omwfx",
            "godrays_android_051.omwfx",
            "godrays_android_051_rayocc.omwfx",
            "godrays_android_051_dynamic.omwfx",
            "godrays_android_051_depthfixed.omwfx",
            "rainlens_android.omwfx",
            "rainlens_android_051_weather.omwfx",
            "rainlens_android_051_teardrops.omwfx",
            "rainlens_android_051_v12.omwfx",
            "wetworld_android.omwfx"
        )
        obsoleteAndroidOmwfxShaders.forEach { shaderName ->
            File(Constants.RESOURCES, "vfs/shaders/$shaderName").delete()
            File(
                Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/",
                shaderName
            ).delete()
        }

        val bloomText = bloomUserTarget.readText()
        if (!bloomText.contains("passes = nomipmap, horizontal, vertical, final;") ||
            !bloomText.contains("internal_format = rgb16f;") ||
            !bloomText.contains("source_type = half_float;") ||
            !bloomText.contains("uniform_float uThreshold {\n    default = 0.30;") ||
            !bloomText.contains("uniform_float uSkyFactor {\n    default = 0.60;") ||
            !bloomText.contains("uniform_float uRadius {\n    default = 0.55;") ||
            !bloomText.contains("uniform_float uStrength {\n    default = 0.35;") ||
            bloomText.count { it == '\n' } < 150) {
            throw IOException("OpenMW 0.51 Android OMWFX bloom payload is invalid")
        }

        val lensflareText = lensflareUserTarget.readText()
        if (!lensflareText.contains("uniform_float flare_strength {\n    default = 0.27;") ||
            !lensflareText.contains("uniform_float halo_size {\n    default = 0.18;") ||
            !lensflareText.contains("uniform_float ghost_strength {\n    default = 0.13;") ||
            !lensflareText.contains("vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);") ||
            !lensflareText.contains("omw.sunVis * clamp(omw.sunOcclusion, 0.0, 1.0) * edgeFade051(sunUv)") ||
            lensflareText.contains("sunOcclusion(") ||
            lensflareText.contains("sunOcclusion051(") ||
            lensflareText.contains("omw_GetLinearDepth(") ||
            lensflareText.contains("omw_GetDepth(") ||
            lensflareText.contains("Disable_SunGlare") ||
            !lensflareText.contains("passes = main;") ||
            !lensflareText.contains("version = \"2.1-051-rayocc\";") ||
            lensflareText.count { it == '\n' } < 100) {
            throw IOException("OpenMW 0.51 Android OMWFX CPU-ray lens flare payload is invalid")
        }

        val godraysText = godraysUserTarget.readText()
        if (!godraysText.contains("uniform_float ray_strength {\n    default = 0.60;") ||
            !godraysText.contains("uniform_float ray_length {\n    default = 0.85;") ||
            !godraysText.contains("uniform_float sun_glow_strength {\n    default = 0.65;") ||
            !godraysText.contains("uniform_float direct_glare_strength {\n    default = 0.48;") ||
            !godraysText.contains("vec4 viewDir = omw.viewMatrix * vec4(discDir, 0.0);") ||
            !godraysText.contains("clamp(omw.sunOcclusion, 0.0, 1.0)") ||
            !godraysText.contains("float depth = omw_GetDepth(clamp(uv, vec2(0.001), vec2(0.999)));") ||
            !godraysText.contains("float shaftContrast = smoothstep(0.08, 0.92, shafts);") ||
            !godraysText.contains("shafts = mix(shafts, shaftContrast, 0.35);") ||
            !godraysText.contains("light += warmColor * shaftIntensity * 0.78;") ||
            !godraysText.contains("light += sunColor * directSun * direct_glare_strength * 0.60 * glowVisibility;") ||
            godraysText.contains("direct_glare_strength * 0.80 * glowVisibility;") ||
            !godraysText.contains("float directSun = 1.0 - smoothstep(0.035, 0.48, centerDistance);") ||
            godraysText.contains("omw_GetLinearDepth(") ||
            godraysText.contains("Disable_SunGlare") ||
            !godraysText.contains("for (int i = 0; i < 16; i += 1)") ||
            !godraysText.contains("passes = main;") ||
            !godraysText.contains("version = \"3.4-051-depthfixed-vivid-softglare\";") ||
            godraysText.count { it == '\n' } < 150) {
            throw IOException("OpenMW 0.51 Android OMWFX calibrated Godrays/Sun-Glow payload is invalid")
        }

        val rainLensText = rainLensUserTarget.readText()
        if (!rainLensText.contains("uniform_float rainlens_strength_v34 {\n    default = 0.72;") ||
            !rainLensText.contains("uniform_float rainlens_refraction_v34 {\n    default = 0.92;") ||
            !rainLensText.contains("uniform_float rainlens_density_v34 {\n    default = 0.90;") ||
            !rainLensText.contains("float hash21051(vec2 p)") ||
            !rainLensText.contains("vec4 movingDrop051(") ||
            !rainLensText.contains("p.y += timeValue * speed;") ||
            !rainLensText.contains("float timeValue = omw.simulationTime;") ||
            !rainLensText.contains("float currentRain = rainForWeather051(omw.weatherID);") ||
            !rainLensText.contains("float nextRain = rainForWeather051(omw.nextWeatherID);") ||
            !rainLensText.contains("clamp(omw.weatherTransition, 0.0, 1.0)") ||
            !rainLensText.contains("vec4 drop = movingDrop051(") ||
            !rainLensText.contains("omw_TexCoord, 5.6, 0.215, 19.7, timeValue, wind, density") ||
            !rainLensText.contains("float threshold = mix(0.94, 0.72, clamp(density, 0.0, 1.0));") ||
            !rainLensText.contains("float refractionMix = clamp(mask * 0.82, 0.0, 0.82);") ||
            !rainLensText.contains("result += vec3(0.028) * drop.w * rain;") ||
            !rainLensText.contains("flags = Disable_Interiors, Disable_Underwater;") ||
            !rainLensText.contains("version = \"4.3-051-rainlens-v12-dense\";") ||
            rainLensText.contains("omw.simulationTime * 0.001") ||
            rainLensText.contains("rainHash3051(") ||
            rainLensText.contains("teardropLayer051(") ||
            rainLensText.count { it == '\n' } < 160) {
            throw IOException("OpenMW 0.51 Android OMWFX RainLens payload is invalid")
        }

        val wetWorldText = wetWorldUserTarget.readText()
        if (!wetWorldText.contains("uniform_float wet_strength_v35 {\n    default = 0.92;") ||
            !wetWorldText.contains("uniform_float wet_darkening_v35 {\n    default = 0.30;") ||
            !wetWorldText.contains("uniform_float wet_sheen_v35 {\n    default = 0.34;") ||
            !wetWorldText.contains("uniform_float puddle_strength_v35 {\n    default = 0.62;") ||
            !wetWorldText.contains("float rainFactor051()") ||
            !wetWorldText.contains("float valueNoise051(vec2 p)") ||
            !wetWorldText.contains("vec3 reconstructedWorldNormal051(vec2 uv)") ||
            !wetWorldText.contains("float upFacing = smoothstep(0.30, 0.76, abs(n.z));") ||
            !wetWorldText.contains("float puddleMask = smoothstep(0.56, 0.76, puddleField)") ||
            !wetWorldText.contains("if (base.a < 0.25)") ||
            !wetWorldText.contains("flags = Disable_Interiors, Disable_Underwater;") ||
            !wetWorldText.contains("version = \"5.1-051-weather-puddles-mali-safe\";") ||
            wetWorldText.contains("dFdx(") ||
            wetWorldText.contains("dFdy(") ||
            wetWorldText.contains("sin(") ||
            wetWorldText.count { it == '\n' } < 170) {
            throw IOException("OpenMW 0.51 Android OMWFX WetWorld/Puddle payload is invalid")
        }

        val waterVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/water.vert"
        ).readText()
        val waterShaderText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/water.frag"
        ).readText()
        if (!waterVertexText.contains("OPENMW_ANDROID_051_WATER_PROJECTIVE_SCREEN_COORDS") ||
            !waterVertexText.contains("screenPosition = gl_Position;") ||
            !waterShaderText.contains("OPENMW_ANDROID_051_WATER_PROJECTIVE_SCREEN_COORDS") ||
            !waterShaderText.contains("(screenPosition.xy / screenPosition.w) * 0.5 + 0.5") ||
            waterShaderText.contains("gl_FragCoord.xy / screenRes") ||
            !waterShaderText.contains("OPENMW_ANDROID_051_WETWORLD_WATER_MASK") ||
            !waterShaderText.contains("#if @wetWorldWaterMask") ||
            !waterShaderText.contains("gl_FragData[0].a = 0.0;") ||
            !waterShaderText.contains("rainCombined(position.xy/1000.0, waterTimer)")) {
            throw IOException("Runtime OpenMW 0.51 Android water reflection/ripple shader is missing or stale")
        }

        val fullscreenText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/fullscreen_tri.vert"
        ).readText()
        val shadowCastingText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/shadowcasting.vert"
        ).readText()
        val shadowReceiverText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/shadows_fragment.glsl"
        ).readText()
        val objectsVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/objects.vert"
        ).readText()
        val objectsFragmentText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/objects.frag"
        ).readText()
        val terrainVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/terrain.vert"
        ).readText()
        val terrainFragmentText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/terrain.frag"
        ).readText()
        val groundcoverVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/groundcover.vert"
        ).readText()
        val groundcoverFragmentText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/groundcover.frag"
        ).readText()
        val bsDefaultVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/bs/default.vert"
        ).readText()
        val bsDefaultFragmentText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/bs/default.frag"
        ).readText()
        val bsNoLightingVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/bs/nolighting.vert"
        ).readText()
        val bsNoLightingFragmentText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/bs/nolighting.frag"
        ).readText()
        val fogShaderText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/compatibility/fog.glsl"
        ).readText()
        val coreVertexText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/lib/core/vertex.h.glsl"
        ).readText()
        val coreFragmentText = File(
            Constants.USER_FILE_STORAGE + "/resources/shaders/lib/core/fragment.h.glsl"
        ).readText()

        if (fullscreenText.contains("uniform vec2 scaling =") ||
            shadowCastingText.contains("uniform bool useDiffuseMapForShadowAlpha =") ||
            shadowCastingText.contains("uniform bool alphaTestShadows =")) {
            throw IOException("Runtime OpenMW 0.51 compatibility shaders still contain GL4ES-hostile uniform initializers")
        }

        val shadowQualityProfile = selectedAndroidShadowQualityProfile()
        if (!shadowReceiverText.contains("OPENMW_ANDROID_051_GLES2_MANUAL_SHADOW_COMPARE") ||
            !shadowReceiverText.contains("OPENMW_ANDROID_051_GLES2_QUALITY_PCF") ||
            !shadowReceiverText.contains("#define OPENMW_ANDROID_SHADOW_PCF_LEVEL ${shadowQualityProfile.pcfLevel}") ||
            !shadowReceiverText.contains("#define OPENMW_ANDROID_SHADOW_MAP_RESOLUTION ${shadowQualityProfile.shadowMapResolution}.0") ||
            !shadowReceiverText.contains("pcfShadow * 0.25") ||
            !shadowReceiverText.contains("pcfShadow * (1.0 / 9.0)") ||
            !shadowReceiverText.contains("pcfShadow * (1.0 / 64.0)") ||
            !shadowReceiverText.contains("OPENMW_ANDROID_051_GLES2_TENT_PCF") ||
            !shadowReceiverText.contains("OPENMW_ANDROID_051_GLES2_RECEIVER_DEPTH_BIAS") ||
            !shadowReceiverText.contains("float receiverDepth = max(shadowXYZ.z - 0.00005, 0.0);") ||
            shadowReceiverText.contains("uniform sampler2DShadow") ||
            shadowReceiverText.contains("shadow2DProj(") ||
            !shadowCastingText.contains("OPENMW_ANDROID_051_GLES2_NATIVE_SHADOW_CLIPPING") ||
            shadowCastingText.contains("gl_Position.z = clamp(gl_Position.z, -gl_Position.w, gl_Position.w);")) {
            throw IOException("Runtime OpenMW 0.51 Android GLES2 shadow compatibility/PCF shader is missing or mismatched")
        }

        if (coreVertexText.contains("@link") ||
            !coreVertexText.contains("OPENMW_ANDROID_051_GL4ES_CORE_INLINE") ||
            coreFragmentText.contains("@link") ||
            !coreFragmentText.contains("OPENMW_ANDROID_051_GL4ES_CORE_INLINE")) {
            throw IOException("Runtime OpenMW 0.51 core shader helpers are not GL4ES-inline compatible")
        }

        if (!objectsVertexText.contains("vec3 viewNormal = normalToView(passNormal);") ||
            !objectsFragmentText.contains("vec3 viewNormal = normalToView(normalize(passNormal));") ||
            !terrainVertexText.contains("vec3 viewNormal = normalToView(passNormal);") ||
            !terrainFragmentText.contains("vec3 viewNormal = normalToView(normalize(passNormal));") ||
            !groundcoverVertexText.contains("vec3 viewNormal = normalToView(passNormal);") ||
            !bsDefaultVertexText.contains("vec3 viewNormal = normalToView(passNormal);") ||
            !bsDefaultFragmentText.contains("vec3 viewNormal = normalToView(normalize(passNormal));") ||
            !bsNoLightingVertexText.contains("vec3 viewNormal = normalize((gl_NormalMatrix * gl_Normal).xyz);")) {
            throw IOException("Runtime OpenMW 0.51 Android GL4ES normal-transform compatibility shaders are missing")
        }

        if (!objectsFragmentText.contains("OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG") ||
            !objectsFragmentText.contains("OPENMW_ANDROID_051_LOCALMAP_OBJECT_FOG_BYPASS_V1") ||
            !fogShaderText.contains("OPENMW_ANDROID_051_GL4ES_EXPLICIT_OBJECT_FOG") ||
            !fogShaderText.contains("uniform vec4 omwFogColor") ||
            !fogShaderText.contains("uniform float omwFogStart") ||
            !fogShaderText.contains("uniform float omwFogEnd")) {
            throw IOException("Runtime OpenMW 0.51 Android explicit GL4ES object-fog/LocalMap shaders are missing")
        }

        if (!objectsFragmentText.contains("OPENMW_ANDROID_051_GL4ES_DISABLE_ADDITIVE_FOG") ||
            objectsFragmentText.contains("#define ADDITIVE_BLENDING") ||
            objectsFragmentText.contains("OPENMW_ANDROID_051_SHADER_PREFIX_TAG_OBJECTS") ||
            bsDefaultFragmentText.contains("OPENMW_ANDROID_051_SHADER_PREFIX_TAG_BS_DEFAULT") ||
            bsNoLightingFragmentText.contains("OPENMW_ANDROID_051_SHADER_PREFIX_TAG_BS_NOLIGHTING") ||
            groundcoverFragmentText.contains("OPENMW_ANDROID_051_SHADER_PREFIX_TAG_GROUNDCOVER")) {
            throw IOException("Runtime OpenMW 0.51 Android GL4ES additive-fog compatibility shaders are missing or diagnostics remain")
        }

        Log.i(
            TAG,
            "Synced OpenMW 0.51 Android OMWFX release payload: WetWorld, Godrays, Lensflare, Bloom and RainLens"
        )
    }

    private fun availableOmwfxChain(): String {
        val shaderDirectory = File(
            Constants.USER_FILE_STORAGE + "/resources/vfs/shaders"
        )

        val available = OMWFX_RECOMMENDED_CHAIN.filter { technique ->
            File(shaderDirectory, "$technique.omwfx").isFile
        }

        if (available.isEmpty()) {
            throw IOException(
                "OMWFX was selected, but no OMWFX techniques were found in " +
                    shaderDirectory.absolutePath
            )
        }

        return available.joinToString(",")
    }

    /**
     * Updates one INI-style section without touching unrelated settings.
     * OpenMW stores user rendering settings in USER_CONFIG/settings.cfg.
     */
    private fun updateSettingsSection(
        file: File,
        sectionName: String,
        values: LinkedHashMap<String, String>
    ) {
        file.parentFile?.mkdirs()

        val lines = if (file.isFile) {
            file.readLines().toMutableList()
        } else {
            mutableListOf()
        }

        val header = "[$sectionName]"
        var sectionStart = lines.indexOfFirst {
            it.trim().equals(header, ignoreCase = true)
        }

        if (sectionStart < 0) {
            if (lines.isNotEmpty() && lines.last().isNotBlank()) {
                lines.add("")
            }
            lines.add(header)
            sectionStart = lines.lastIndex
        }

        var sectionEnd = lines.size
        for (index in sectionStart + 1 until lines.size) {
            val trimmed = lines[index].trim()
            if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
                sectionEnd = index
                break
            }
        }

        values.forEach { (key, value) ->
            var existingIndex = -1

            for (index in sectionStart + 1 until sectionEnd) {
                val line = lines[index]
                val equals = line.indexOf('=')
                if (equals > 0 &&
                    line.substring(0, equals).trim().equals(key, ignoreCase = true)) {
                    existingIndex = index
                    break
                }
            }

            val replacement = "$key = $value"
            if (existingIndex >= 0) {
                lines[existingIndex] = replacement
            } else {
                lines.add(sectionEnd, replacement)
                sectionEnd += 1
            }
        }

        file.writeText(lines.joinToString("\n").trimEnd() + "\n")
    }

    private data class AndroidShadowQualityProfile(
        val preferenceValue: String,
        val shadowMapResolution: String,
        val pcfLevel: Int,
        val pcfSamples: Int,
        val normalOffsetDistance: String
    )

    /**
     * Android deliberately keeps exactly one orthographic shadow map because
     * multiple maps/cascades caused moving dark regions on the GLES2/GL4ES
     * backend. Quality therefore scales both map resolution and a compile-time
     * PCF kernel in the receiver shader.
     */
    private fun selectedAndroidShadowQualityProfile(): AndroidShadowQualityProfile {
        return when (prefs.getString("gs_shadow_quality", "medium") ?: "medium") {
            "low" -> AndroidShadowQualityProfile("low", "2048", 1, 4, "1.25")
            "high" -> AndroidShadowQualityProfile("high", "4096", 3, 16, "1.75")
            else -> AndroidShadowQualityProfile("medium", "4096", 2, 9, "1.50")
        }
    }

    /**
     * Rewrites only two guarded compile-time constants in the bundled receiver.
     * The rest of the shader stays byte-for-byte identical. A hard failure is
     * preferable to silently launching with mismatched resolution/PCF offsets.
     */
    private fun specializeAndroidShadowShader(sourceText: String): String {
        if (!sourceText.contains("OPENMW_ANDROID_051_GLES2_QUALITY_PCF")) {
            throw IOException("Bundled Android shadow shader has no quality-PCF marker")
        }

        val levelPattern = Regex(
            "(?m)^#define\\s+OPENMW_ANDROID_SHADOW_PCF_LEVEL\\s+\\d+\\s*$"
        )
        val resolutionPattern = Regex(
            "(?m)^#define\\s+OPENMW_ANDROID_SHADOW_MAP_RESOLUTION\\s+\\d+(?:\\.\\d+)?\\s*$"
        )
        if (levelPattern.findAll(sourceText).count() != 1 ||
            resolutionPattern.findAll(sourceText).count() != 1) {
            throw IOException("Bundled Android shadow shader PCF constants are missing or duplicated")
        }

        val profile = selectedAndroidShadowQualityProfile()
        return sourceText
            .replace(levelPattern, "#define OPENMW_ANDROID_SHADOW_PCF_LEVEL ${profile.pcfLevel}")
            .replace(
                resolutionPattern,
                "#define OPENMW_ANDROID_SHADOW_MAP_RESOLUTION ${profile.shadowMapResolution}.0"
            )
    }

    /**
     * Applies the launcher Shadow settings directly to OpenMW's user settings.
     *
     * OpenMW 0.51 provides the complete shadow-mapping implementation.
     * On Android/GL4ES, Quality keeps one stable shadow map and controls its
     * resolution plus the GLES2 PCF kernel. Distance controls the maximum shadow range. A 0.75 fade start gives the outer 25 percent of
     * the selected range to smoothly fade shadows out (and back in when approaching).
     */
    private fun applyShadowSettings() {
        val qualityProfile = selectedAndroidShadowQualityProfile()
        // Android/GL4ES: keep a single shadow map for every quality tier.
        // Multi-map cascades (2+ maps) produce moving dark/flickering regions on
        // GLES2 devices. Quality scales resolution plus the launcher-specialized
        // PCF receiver kernel instead: Low=4 taps, Medium=9 taps, High=16 taps.
        val shadowMapCount = "1"
        val shadowMapResolution = qualityProfile.shadowMapResolution

        val maximumShadowDistance = when (prefs.getString("gs_shadow_distance", "medium")) {
            "low" -> "2048"
            "high" -> "8192"
            else -> "4096"
        }

        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")
        updateSettingsSection(
            settingsFile,
            "Shadows",
            linkedMapOf(
                "enable shadows" to if (prefs.getBoolean("gs_enable_shadows", false)) "true" else "false",
                "player shadows" to if (prefs.getBoolean("gs_player_shadows", true)) "true" else "false",
                "actor shadows" to if (prefs.getBoolean("gs_actor_shadows", true)) "true" else "false",
                "object shadows" to if (prefs.getBoolean("gs_object_shadows", true)) "true" else "false",
                "terrain shadows" to if (prefs.getBoolean("gs_terrain_shadows", true)) "true" else "false",
                "enable indoor shadows" to if (prefs.getBoolean("gs_indoor_shadows", true)) "true" else "false",
                "number of shadow maps" to shadowMapCount,
                "shadow map resolution" to shadowMapResolution,
                "maximum shadow map distance" to maximumShadowDistance,
                "shadow fade start" to "0.75",
                // OpenMW's normal-offset mechanism is the least intrusive way to
                // suppress receiver self-shadowing (shadow acne). The wider PCF
                // kernel used at higher quality samples a larger terrain slope,
                // so scale the offset modestly with the selected quality. Keep
                // polygon offset at the upstream 0.51 defaults to avoid excess
                // Peter Panning on actors and small objects.
                "polygon offset factor" to "1.1",
                "polygon offset units" to "4.0",
                "normal offset distance" to qualityProfile.normalOffsetDistance,
                "use front face culling" to "false"
            )
        )

        Log.i(
            TAG,
            "Applied OpenMW 0.51 Android shadows: enabled=${prefs.getBoolean("gs_enable_shadows", false)}, " +
                "quality=${qualityProfile.preferenceValue} (${shadowMapCount}x${shadowMapResolution}, " +
                "pcf=${qualityProfile.pcfSamples} taps), distance=$maximumShadowDistance, fadeStart=0.75, " +
                "normalOffset=${qualityProfile.normalOffsetDistance}"
        )
    }

    /**
     * WetWorld runs first so wet roads and procedural puddles feed the optical
     * stack. RainLens remains last, and OpenMW 0.51 weather IDs drive both
     * weather effects through smooth transitions.
     */
    private fun applyOpenMw051RuntimeSettings() {
        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")
        val selectedShaderPreset = prefs.getString("pref_shadersDir_v2", "none") ?: "none"
        val omwfxSelected = selectedShaderPreset == OMWFX_PRESET_VALUE
        val postProcessingChain = if (omwfxSelected) {
            OMWFX_RECOMMENDED_CHAIN.joinToString(",")
        } else {
            "adjustments"
        }

        if (omwfxSelected) {
            val wetWorldFile = File(
                Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/wetworld_android_051_weather.omwfx"
            )
            if (!wetWorldFile.isFile) {
                throw IOException(
                    "OMWFX was selected, but wetworld_android_051_weather.omwfx is missing: " +
                        wetWorldFile.absolutePath
                )
            }

            val bloomFile = File(
                Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/gateh_bloom051.omwfx"
            )
            if (!bloomFile.isFile) {
                throw IOException(
                    "OMWFX was selected, but gateh_bloom051.omwfx is missing: " +
                        bloomFile.absolutePath
                )
            }

            val lensflareFile = File(
                Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/lensflare_android_051_rayocc.omwfx"
            )
            if (!lensflareFile.isFile) {
                throw IOException(
                    "OMWFX was selected, but lensflare_android_051_rayocc.omwfx is missing: " +
                        lensflareFile.absolutePath
                )
            }

            val godraysFile = File(
                Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/godrays_android_051_depthfixed_vivid.omwfx"
            )
            if (!godraysFile.isFile) {
                throw IOException(
                    "OMWFX was selected, but godrays_android_051_depthfixed_vivid.omwfx is missing: " +
                        godraysFile.absolutePath
                )
            }

            val rainLensFile = File(
                Constants.USER_FILE_STORAGE + "/resources/vfs/shaders/rainlens_android_051_v12_dense.omwfx"
            )
            if (!rainLensFile.isFile) {
                throw IOException(
                    "OMWFX was selected, but rainlens_android_051_v12_dense.omwfx is missing: " +
                        rainLensFile.absolutePath
                )
            }
        }

        updateSettingsSection(
            settingsFile,
            "Post Processing",
            linkedMapOf(
                // OPENMW_ANDROID_051_POSTPROCESSING_PRESERVE_ENABLED_V1
                // enabled is owned by preset transitions/F2, not every launch.
                "chain" to postProcessingChain,
                "transparent postpass" to if (omwfxSelected) "true" else if (
                    prefs.getBoolean("gs_transparent_postpass", false)
                ) "true" else "false"
            )
        )

        // Keep the complete device-proven Android shadow selection unchanged.
        applyShadowSettings()

        Log.i(
            TAG,
            "OpenMW 0.51 Android release runtime: shadows=launcher-controlled, " +
                "postProcessing=preset/F2-controlled, transparentPostpass=${if (omwfxSelected) "forced-on" else "launcher"}, " +
                "chain=$postProcessingChain, omwfx=${if (omwfxSelected) "enabled" else "off"}"
        )
    }

    // v14.2 OpenMW 0.50 launcher settings
    private fun readOpenMwSetting(
        file: File,
        sectionName: String,
        key: String
    ): String? {
        if (!file.isFile) {
            return null
        }

        val wantedSection = "[$sectionName]"
        var inSection = false

        return try {
            for (line in file.readLines()) {
                val trimmed = line.trim()

                if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
                    inSection = trimmed.equals(wantedSection, ignoreCase = true)
                    continue
                }

                if (!inSection || trimmed.isEmpty() ||
                    trimmed.startsWith("#") || trimmed.startsWith(";")) {
                    continue
                }

                val equals = trimmed.indexOf('=')
                if (equals <= 0) {
                    continue
                }

                val foundKey = trimmed.substring(0, equals).trim()
                if (foundKey.equals(key, ignoreCase = true)) {
                    return trimmed.substring(equals + 1)
                        .substringBefore('#')
                        .substringBefore(';')
                        .trim()
                }
            }

            null
        } catch (e: IOException) {
            Log.w(TAG, "Could not read OpenMW 0.51 setting [$sectionName] $key", e)
            null
        }
    }

    /**
     * Import existing user choices once. If settings.cfg does not contain one
     * of the new OpenMW 0.50 settings, use the official 0.50 default.
     *
     * This means an existing hand-edited settings.cfg is respected when the
     * new launcher controls first appear.
     */
    private fun migrateOpenMw050SettingsPreferences() {
        val migrationKey = "migration_openmw050_launcher_settings_v1"
        if (prefs.getBoolean(migrationKey, false)) {
            return
        }

        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

        fun readBoolean(section: String, key: String, defaultValue: Boolean): Boolean {
            val raw = readOpenMwSetting(settingsFile, section, key) ?: return defaultValue
            return when {
                raw.equals("true", ignoreCase = true) -> true
                raw.equals("false", ignoreCase = true) -> false
                else -> defaultValue
            }
        }

        val controllerMenus =
            readBoolean("GUI", "controller menus", false)
        val controllerTooltips =
            readBoolean("GUI", "controller tooltips", false)
        val cameraListener =
            readBoolean("Sound", "camera listener", false)

        val dopplerFactor =
            readOpenMwSetting(settingsFile, "Sound", "doppler factor")
                ?.toDoubleOrNull()
        val dopplerEnabled = dopplerFactor?.let { it != 0.0 } ?: true

        prefs.edit()
            .putBoolean("pref_omw050_controller_menus", controllerMenus)
            .putBoolean("pref_omw050_controller_tooltips", controllerTooltips)
            .putBoolean("pref_omw050_doppler", dopplerEnabled)
            .putBoolean("pref_omw050_camera_listener", cameraListener)
            .putBoolean(migrationKey, true)
            .apply()

        Log.i(
            TAG,
            "Imported OpenMW 0.50 launcher settings: " +
                "controllerMenus=$controllerMenus, " +
                "controllerTooltips=$controllerTooltips, " +
                "doppler=$dopplerEnabled, " +
                "cameraListener=$cameraListener"
        )
    }

    /**
     * Import the Android-relevant settings added by OpenMW 0.51. Exact custom
     * trigger thresholds from a hand-edited settings.cfg are preserved as one
     * pair even if they are not one of the launcher presets.
     */
    private fun migrateOpenMw051SettingsPreferences() {
        val migrationKey = "migration_openmw051_launcher_settings_v1"
        if (prefs.getBoolean(migrationKey, false)) {
            return
        }

        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

        val triggerPress = readOpenMwSetting(settingsFile, "GUI", "controller trigger press")
            ?.toIntOrNull()
            ?.coerceIn(1, 32767)
            ?: 30720
        val triggerRelease = readOpenMwSetting(settingsFile, "GUI", "controller trigger release")
            ?.toIntOrNull()
            ?.coerceIn(0, minOf(32766, triggerPress - 1))
            ?: minOf(26624, triggerPress - 1)
        val groundcoverPointLighting =
            !readOpenMwSetting(settingsFile, "Groundcover", "point lighting")
                .equals("false", ignoreCase = true)

        prefs.edit()
            .putString(
                "pref_omw051_controller_trigger_thresholds",
                "$triggerPress,$triggerRelease"
            )
            .putBoolean("gs_groundcover_point_lighting", groundcoverPointLighting)
            .putBoolean(migrationKey, true)
            .apply()

        Log.i(
            TAG,
            "Imported OpenMW 0.51 launcher settings: " +
                "controllerTrigger=$triggerPress/$triggerRelease, " +
                "groundcoverPointLighting=$groundcoverPointLighting"
        )
    }

    private fun controllerTriggerThresholds(): Pair<Int, Int> {
        val encoded = prefs.getString(
            "pref_omw051_controller_trigger_thresholds",
            "30720,26624"
        ) ?: "30720,26624"
        val values = encoded.split(',', limit = 2)
        val triggerPress = values.getOrNull(0)
            ?.trim()
            ?.toIntOrNull()
            ?.coerceIn(1, 32767)
            ?: 30720
        val triggerRelease = values.getOrNull(1)
            ?.trim()
            ?.toIntOrNull()
            ?.coerceIn(0, minOf(32766, triggerPress - 1))
            ?: minOf(26624, triggerPress - 1)
        return triggerPress to triggerRelease
    }

    /**
     * Write only launcher-owned controller/audio and Groundcover settings to
     * settings.cfg. Unrelated settings and OMWFX/F2 edits remain untouched.
     */
    private fun applyOpenMw051LauncherSettings() {
        val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

        val controllerMenus =
            prefs.getBoolean("pref_omw050_controller_menus", false)
        val controllerTooltips =
            prefs.getBoolean("pref_omw050_controller_tooltips", false)
        val dopplerEnabled =
            prefs.getBoolean("pref_omw050_doppler", true)
        val cameraListener =
            prefs.getBoolean("pref_omw050_camera_listener", false)
        val (triggerPress, triggerRelease) = controllerTriggerThresholds()
        val groundcoverPointLighting =
            prefs.getBoolean("gs_groundcover_point_lighting", true)

        updateSettingsSection(
            settingsFile,
            "GUI",
            linkedMapOf(
                "controller menus" to if (controllerMenus) "true" else "false",
                "controller trigger press" to triggerPress.toString(),
                "controller trigger release" to triggerRelease.toString(),
                "controller tooltips" to if (controllerTooltips) "true" else "false"
            )
        )

        updateSettingsSection(
            settingsFile,
            "Sound",
            linkedMapOf(
                "doppler factor" to if (dopplerEnabled) "0.25" else "0.0",
                "camera listener" to if (cameraListener) "true" else "false"
            )
        )

        updateSettingsSection(
            settingsFile,
            "Groundcover",
            linkedMapOf(
                "point lighting" to if (groundcoverPointLighting) "true" else "false"
            )
        )

        Log.i(
            TAG,
            "Applied OpenMW 0.51 launcher settings: " +
                "controllerMenus=$controllerMenus, " +
                "controllerTrigger=$triggerPress/$triggerRelease, " +
                "controllerTooltips=$controllerTooltips, " +
                "doppler=${if (dopplerEnabled) "0.25" else "0.0"}, " +
                "cameraListener=$cameraListener, " +
                "groundcoverPointLighting=$groundcoverPointLighting"
        )
    }
    /**
     * `Original`, `Modified` and `Zesterer` remain core-shader presets.
     * OMWFX is different: it uses the original core shaders plus OpenMW's
     * post-processing pipeline.
     *
     * Only change the Post Processing enabled state when the launcher preset
     * actually changes. Normal relaunches preserve the F2/user enabled choice;
     * launcher-owned chain/transparent-postpass values remain runtime-managed.
     */
    private fun applyShaderPresetSettings() {
        val selected = prefs.getString("pref_shadersDir_v2", "none") ?: "none"
        val previouslyApplied = prefs.getString(OMWFX_APPLIED_PRESET_KEY, null)

        if (selected == OMWFX_PRESET_VALUE) {
            if (previouslyApplied != OMWFX_PRESET_VALUE) {
                val chain = availableOmwfxChain()
                val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

                updateSettingsSection(
                    settingsFile,
                    "Post Processing",
                    linkedMapOf(
                        "enabled" to "true",
                        "chain" to chain
                    )
                )

                Log.i(TAG, "Enabled OMWFX OpenMW 0.51 preset with weather WetWorld/puddles + Tex_Depth Godrays + CPU-ray Lensflare + calibrated Bloom + weather RainLens: $chain")
            }
        } else if (previouslyApplied == OMWFX_PRESET_VALUE) {
            val settingsFile = File(Constants.USER_CONFIG, "settings.cfg")

            updateSettingsSection(
                settingsFile,
                "Post Processing",
                linkedMapOf(
                    "enabled" to "false",
                    "chain" to ""
                )
            )

            Log.i(TAG, "Disabled OMWFX post-processing preset.")
        }

        if (previouslyApplied != selected) {
            prefs.edit()
                .putString(OMWFX_APPLIED_PRESET_KEY, selected)
                .apply()
        }
    }

    private fun configureDefaultsBin(args: Map<String, String>) {
        val defaults = File(Constants.DEFAULTS_BIN).readText()
        val decoded = String(android.util.Base64.decode(defaults, android.util.Base64.DEFAULT))
        val lines = decoded.lines().map {
            for ((k, v) in args) {
                if (it.startsWith("$k ="))
                    return@map "$k = $v"
            }
            it
        }
        val data = lines.joinToString("\n")

        val encoded = android.util.Base64.encodeToString(data.toByteArray(), android.util.Base64.NO_WRAP)
        File(Constants.DEFAULTS_BIN).writeText(encoded)
    }

    private fun startGame() {
        // Get scaling factor from config; if invalid or not provided, generate one
        var scaling = 0f

        try {
            scaling = prefs.getString("pref_uiScaling", "")!!.toFloat()
        } catch (e: NumberFormatException) {
            // Reset the invalid setting
            with(prefs.edit()) {
                putString("pref_uiScaling", "")
                apply()
            }
        }

        // set up gamma, if invalid, use the default (1.0)
        var gamma = 1.0f
        try {
            gamma = prefs.getString("pref_gamma", "")!!.toFloat()
        } catch (e: NumberFormatException) {
            // Reset the invalid setting
            with(prefs.edit()) {
                putString("pref_gamma", "")
                apply()
            }
        }

        try {
            Os.setenv("OPENMW_GAMMA", "%.2f".format(Locale.ROOT, gamma), true)
        } catch (e: ErrnoException) {
            // can't really do much if that fails...
        }

        // If scaling didn't get set, determine it automatically
        if (scaling == 0f) {
            scaling = MyApp.app.defaultScaling
        }

        // Keep the opaque "Loading" screen exclusive to application startup.
        // When the user starts the game from the launcher, retain the launcher's
        // long-standing compact preparation dialog instead of covering the whole
        // screen a second time. Skip-GUI stays dialog-free as before.
        val dialog = if (skipGuiDirectLaunchActive) {
            null
        } else {
            ProgressDialog.show(
                this,
                "",
                getString(R.string.launch_preparing_game),
                true,
                false
            )
        }

        // Hide Android system chrome after the dialog has been created so screen
        // resolution probing sees the actual game viewport, matching the original
        // launcher sequence.
        hideAndroidControls(this)

        val activity = this

        val th = Thread {
            try {
                // Reinstall static files if their version mismatches OR if an older
                // launcher-only APK left a valid-looking stamp without the runtime payload.
                val staticFilesCurrent = try {
                    val stamp = File(Constants.VERSION_STAMP).readText().trim()
                    stamp.toInt() == BuildConfig.VERSION_CODE && staticFilesInstalled()
                } catch (e: Exception) {
                    false
                }
                if (!staticFilesCurrent) {
                    reinstallStaticFiles()
                }

                val inst = GameInstaller(prefs.getString("game_files", "")!!)

                // Regenerate the fallback file in case user edits their Morrowind.ini
                if (!inst.convertIni(prefs.getString("pref_encoding", GameInstaller.DEFAULT_CHARSET_PREF)!!)) {
                    throw IOException("Failed to convert Morrowind.ini into openmw.fallback.cfg")
                }

                if (!generateOpenmwCfg()) {
                    throw IOException("Failed to generate openmw.cfg")
                }

                // openmw.cfg: data, resources
                file.Writer.write(Constants.OPENMW_CFG, "resources", Constants.RESOURCES)
                file.Writer.write(Constants.OPENMW_CFG, "data", "\"" + inst.findDataFiles() + "\"")

                file.Writer.write(Constants.OPENMW_CFG, "encoding", prefs!!.getString("pref_encoding", GameInstaller.DEFAULT_CHARSET_PREF)!!)

                // Keep the writable CaveBros resource mirror in sync with the
                // embedded runtime. This also repairs stale/incomplete resource
                // directories left behind by older installs.
                ensureUserResourcesCurrent()
                ensureOpenMw051InternalDataPath()

                // Keep the retained 0.50 controller/audio choices and apply the
                // Android-relevant controller/Groundcover additions from 0.51.
                // The older SharedPreferences keys intentionally remain stable.
                applyOpenMw051LauncherSettings()

                // Apply OMWFX enable/disable only when the launcher preset actually
                // changes. Normal relaunches must preserve the F2/user choice.
                applyShaderPresetSettings()

                // Android shadows remain launcher-controlled. OMWFX forces the
                // transparent postpass for WetWorld and the optical stack.
                applyOpenMw051RuntimeSettings()

                //val displayInCutoutArea = PreferenceManager.getDefaultSharedPreferences(this).getBoolean("pref_display_cutout_area", false)
                obtainFixedScreenResolution()
                val dm = DisplayMetrics()
                windowManager.defaultDisplay.getRealMetrics(dm)

                val orientation = this.getResources().getConfiguration().orientation
                var displayWidth = 0
                var displayHeight = 0

                if (orientation == Configuration.ORIENTATION_PORTRAIT)
                {
                    displayWidth = if(resolutionX == 0) dm.heightPixels else resolutionX
                    displayHeight = if(resolutionY == 0) dm.widthPixels else resolutionY
                }
                else
                {
                    displayWidth = if(resolutionX == 0) dm.widthPixels else resolutionX
                    displayHeight = if(resolutionY == 0) dm.heightPixels else resolutionY
                }
               
                // OPENMW_ANDROID_051_SYNC_LAUNCHER_RESOLUTION_TO_SETTINGS
                // defaults.bin provides Android defaults, but an existing user
                // settings.cfg has higher precedence. ChromeOS can therefore retain
                // a previously persisted physical display size (for example
                // 1920x1080) even when the launcher requests 640x360.
                //
                // Keep OpenMW's real [Video] settings synchronized with the
                // launcher-selected logical render size on every game start.
                // If no custom resolution is selected, displayWidth/displayHeight
                // already contain the physical/native size, so stale custom values
                // are also cleared correctly.
                updateSettingsSection(
                    File(Constants.USER_CONFIG, "settings.cfg"),
                    "Video",
                    linkedMapOf(
                        "resolution x" to displayWidth.toString(),
                        "resolution y" to displayHeight.toString()
                    )
                )

                Log.i(
                    TAG,
                    "OpenMW Android launcher resolution synced to settings.cfg: " +
                        "${displayWidth}x${displayHeight}"
                )

                configureDefaultsBin(mapOf(
                        "scaling factor" to "%.2f".format(Locale.ROOT, scaling),
                        // android-specific defaults
                        "viewing distance" to "2048.0",
                        "camera sensitivity" to "0.4",
                        "resolution x" to displayWidth.toString(),
                        "resolution y" to displayHeight.toString(),
                        // and a bunch of windows positioning
                        "stats x" to "0.0",
                        "stats y" to "0.0",
                        "stats w" to "0.375",
                        "stats h" to "0.4275",
                        "spells x" to "0.625",
                        "spells y" to "0.5725",
                        "spells w" to "0.375",
                        "spells h" to "0.4275",
                        "map x" to "0.625",
                        "map y" to "0.0",
                        "map w" to "0.375",
                        "map h" to "0.5725",
                        "inventory y" to "0.4275",
                        "inventory w" to "0.6225",
                        "inventory h" to "0.5725",
                        "inventory container x" to "0.0",
                        "inventory container y" to "0.4275",
                        "inventory container w" to "0.6225",
                        "inventory container h" to "0.5725",
                        "inventory barter x" to "0.0",
                        "inventory barter y" to "0.4275",
                        "inventory barter w" to "0.6225",
                        "inventory barter h" to "0.5725",
                        "inventory companion x" to "0.0",
                        "inventory companion y" to "0.4275",
                        "inventory companion w" to "0.6225",
                        "inventory companion h" to "0.5725",
                        "dialogue x" to "0.095",
                        "dialogue y" to "0.095",
                        "dialogue w" to "0.810",
                        "dialogue h" to "0.890",
                        "console x" to "0.0",
                        "console y" to "0.0",
                        "container x" to "0.25",
                        "container y" to "0.0",
                        "container w" to "0.75",
                        "container h" to "0.375",
                        "barter x" to "0.25",
                        "barter y" to "0.0",
                        "barter w" to "0.75",
                        "barter h" to "0.375",
                        "companion x" to "0.25",
                        "companion y" to "0.0",
                        "companion w" to "0.75",
                        "companion h" to "0.375",

			// Game Mechanics
                        "toggle sneak" to if(prefs.getBoolean("gs_toggle_sneak", true)) "true" else "false",
                        "uncapped damage fatigue" to if(prefs.getBoolean("gs_uncapped_damage_fatigue", false)) "true" else "false",
                        "rebalance soul gem values" to if(prefs.getBoolean("gs_soulgem_values_rebalance", false)) "true" else "false",
                        "followers attack on sight" to if(prefs.getBoolean("gs_followers_defend_immediately", false)) "true" else "false",
                        "barter disposition change is permanent" to if(prefs.getBoolean("gs_permanent_barter_disposition_changes", false)) "true" else "false",
                        "NPCs avoid collisions" to if(prefs.getBoolean("gs_npc_avoid_collision", false)) "true" else "false",
                        "only appropriate ammunition bypasses resistance" to if(prefs.getBoolean("gs_only_weapon_bs", false)) "true" else "false",
                        "normalise race speed" to if(prefs.getBoolean("gs_racial_variation_in_speed_fix", false)) "true" else "false",
                        "swim upward correction" to if(prefs.getBoolean("gs_swim_upward_correction", false)) "true" else "false",
                        "can loot during death animation" to if(prefs.getBoolean("gs_can_loot_during_death_animation", true)) "true" else "false",
                        "enchanted weapons are magical" to if(prefs.getBoolean("gs_enchanted_weapons_are_magical", true)) "true" else "false",
                        "classic reflected absorb spells behavior" to if(prefs.getBoolean("gs_classic_reflected_absorb_spells_behavior", true)) "true" else "false",
                        "always allow stealing from knocked out actors" to if(prefs.getBoolean("gs_always_allow_stealing_from_knocked_out_actors", false)) "true" else "false",
                        "allow actors to follow over water surface" to if(prefs.getBoolean("gs_always_allow_npc_to_follow_over_water_surface", true)) "true" else "false",
                        "strength influences hand to hand" to prefs.getString("gs_factor_strength_into_hand-to-hand_combat", "0").toString(),

			// Visuals terrain
                        "object paging min size" to prefs.getString("gs_object_paging_min_size", "0.25").toString(),
                        "distant terrain" to if(prefs.getBoolean("gs_distant_land", false)) "true" else "false",
                        "object paging active grid" to if(prefs.getBoolean("gs_active_grid_object_paging", true)) "true" else "false",

			// Visuals graphics
                        //"antialiasing" to prefs.getString("gs_antialiasing", "0").toString(),
                        "framerate limit" to prefs.getString("gs_framerate_limit", "60").toString(),

			// Visuals shaders
                        "auto use object normal maps" to if(prefs.getBoolean("gs_auto_use_object_normal_maps", false)) "true" else "false",
                        "auto use object specular maps" to if(prefs.getBoolean("gs_auto_use_object_specular_maps", false)) "true" else "false",
                        "auto use terrain normal maps" to if(prefs.getBoolean("gs_auto_use_terrain_normal_maps", false)) "true" else "false",
                        "auto use terrain specular maps" to if(prefs.getBoolean("gs_auto_use_terrain_specular_maps", false)) "true" else "false",
                        "apply lighting to environment maps" to if(prefs.getBoolean("gs_bump_map_local_lighting", false)) "true" else "false",
                        //"soft particles" to if(prefs.getBoolean("gs_soft_particles", false)) "true" else "false",

			// Visuals fog
                        "radial fog" to if(prefs.getBoolean("gs_radial_fog", false)) "true" else "false",
                        "exponential fog" to if(prefs.getBoolean("gs_exponential_fog", false)) "true" else "false",
                        "sky blending" to if(prefs.getBoolean("gs_sky_blending", false)) "true" else "false",

			// Visuals PostProcessing
                        "soft particles" to if(prefs.getBoolean("gs_soft_particles", false)) "true" else "false",
                        "transparent postpass" to if(prefs.getBoolean("gs_transparent_postpass", false)) "true" else "false",

			// Animations
                        "use magic item animations" to if(prefs.getBoolean("gs_use_magic_item_animation", false)) "true" else "false",
                        "use additional anim sources" to if(prefs.getBoolean("gs_use_additional_animation_sources", false)) "true" else "false",
                        "weapon sheathing" to if(prefs.getBoolean("gs_weapon_sheating", false)) "true" else "false",
                        "shield sheathing" to if(prefs.getBoolean("gs_shield_sheating", false)) "true" else "false",
                        "graphic herbalism" to if(prefs.getBoolean("gs_enable_graphics_herbalism", true)) "true" else "false",
                        "smooth movement" to if(prefs.getBoolean("gs_smooth_movement", false)) "true" else "false",
                        "smooth animation transitions" to if(prefs.getBoolean("gs_smooth_animation_transitions", false)) "true" else "false",
                        "turn to movement direction" to if(prefs.getBoolean("gs_turn_to_movement_direction", false)) "true" else "false",

			// Animations FirstPerson
                        "hand inertia" to if(prefs.getBoolean("gs_hand_inertia", false)) "3.0" else "0.0",

			// Interface
                        "show owned" to prefs!!.getString("gs_show_owned", "0").toString(),
                        "show effect duration" to if(prefs.getBoolean("gs_show_effect_duration", false)) "true" else "false",
                        "show enchant chance" to if(prefs.getBoolean("gs_show_enchant_chance", false)) "true" else "false",
                        "show melee info" to if(prefs.getBoolean("gs_show_melee_info", false)) "true" else "false",
                        "show projectile damage" to if(prefs.getBoolean("gs_show_projectile_damage", false)) "true" else "false",
                        "color topic enable" to if(prefs.getBoolean("gs_change_dialogue_topic_color", false)) "true" else "false",
                        "stretch menu background" to if(prefs.getBoolean("gs_stretch_menu_background", false)) "true" else "false",
                        "allow zooming" to if(prefs.getBoolean("gs_can_zoom_on_maps", false)) "true" else "false",

			// Bug Fixes
                        "prevent merchant equipping" to if(prefs.getBoolean("gs_merchant_equipping_fix", false)) "true" else "false",
                        "trainers training skills based on base skill" to if(prefs.getBoolean("gs_trainers_bs", false)) "true" else "false",

			// Miscellaneous
                        "timeplayed" to if(prefs.getBoolean("gs_add_time_to_saves", false)) "true" else "false",
                        "max quicksaves" to prefs.getString("gs_maximum_quicksaves", "1").toString(),

			// Engine Settings
                        "enabled" to if(prefs.getString("gs_groundcover_handling", "0") == "2") "true" else "false",
                        "paging" to if(prefs.getString("gs_groundcover_handling", "0") == "1") "true" else "false",
                        "enable" to if(prefs.getBoolean("gs_build_navmesh", true)) "true" else "false",
                        "write to navmeshdb" to if(prefs.getBoolean("gs_write_navmesh", false)) "true" else "false",
                        "async nav mesh updater threads" to prefs.getString("gs_navmesh_threads", "1").toString(),
                        "async num threads" to prefs.getString("gs_physics_threads", "1").toString(),
                        "preload num threads" to prefs.getString("gs_preload_threads", "1").toString()

                ))

                runOnUiThread {
                    obtainFixedScreenResolution()
                    dialog?.dismiss()
                    runGame()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to prepare OpenMW launch.", e)
                runOnUiThread {
                    revealLauncherAfterSkipGui("launch preparation failed")
                    dialog?.dismiss()
                    AlertDialog.Builder(activity)
                        .setTitle(R.string.launch_failed_title)
                        .setMessage(e.message ?: getString(R.string.launch_failed_unknown))
                        .setPositiveButton(android.R.string.ok) { _, _ -> }
                        .show()
                }
            }
        }
        th.start()
    }

    // v14.1 launcher popup/about polish
    private data class AboutLicenseSection(
        val title: String,
        val body: String
    )

    // Cache the small section index once. Individual licence bodies are still
    // inflated lazily only when the user expands a section in About.
    private var cachedThirdPartyLicenseSections: List<AboutLicenseSection>? = null

    private fun launcherDp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun launcherThemeColor(attribute: Int, fallback: Int): Int {
        val value = android.util.TypedValue()
        if (!theme.resolveAttribute(attribute, value, true)) {
            return fallback
        }

        if (value.resourceId != 0) {
            return try {
                androidx.appcompat.content.res.AppCompatResources
                    .getColorStateList(this, value.resourceId)
                    ?.defaultColor ?: fallback
            } catch (_: Exception) {
                fallback
            }
        }

        return value.data
    }

    /**
     * The stock AppCompat overflow popup can overlap its three-dot anchor.
     * Install a launcher-owned overflow button instead so the popup is always
     * positioned BELOW the icon and can have a proper section heading.
     */
    private fun installUserConfigurationOverflow(
        toolbar: androidx.appcompat.widget.Toolbar
    ) {
        val overflow = android.widget.TextView(this).apply {
            text = "\u22ee"
            textSize = 29f
            gravity = android.view.Gravity.CENTER
            contentDescription = getString(R.string.user_configuration)
            isClickable = true
            isFocusable = true
            setTextColor(
                launcherThemeColor(
                    android.R.attr.textColorPrimary,
                    android.graphics.Color.WHITE
                )
            )

            val selectable = android.util.TypedValue()
            if (theme.resolveAttribute(
                    android.R.attr.selectableItemBackgroundBorderless,
                    selectable,
                    true
                ) && selectable.resourceId != 0
            ) {
                setBackgroundResource(selectable.resourceId)
            }

            layoutParams = androidx.appcompat.widget.Toolbar.LayoutParams(
                launcherDp(48),
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.Gravity.END
            )

            setOnClickListener { anchor ->
                showUserConfigurationPopup(anchor)
            }
        }

        toolbar.addView(overflow)
    }

    private fun launcherPopupRow(
        text: String,
        primaryColor: Int
    ): android.widget.TextView =
        android.widget.TextView(this).apply {
            this.text = text
            textSize = 16f
            gravity = android.view.Gravity.CENTER_VERTICAL
            setTextColor(primaryColor)
            setPadding(launcherDp(18), 0, launcherDp(18), 0)
            minHeight = launcherDp(48)
            isClickable = true
            isFocusable = true

            val selectable = android.util.TypedValue()
            if (theme.resolveAttribute(
                    android.R.attr.selectableItemBackground,
                    selectable,
                    true
                ) && selectable.resourceId != 0
            ) {
                setBackgroundResource(selectable.resourceId)
            }
        }

    private fun showLauncherPopup(
        anchor: android.view.View,
        title: String,
        entries: List<Pair<String, () -> Unit>>
    ) {
        val oledTheme = isOledLauncherTheme()
        val backgroundColor = if (oledTheme) {
            android.graphics.Color.BLACK
        } else {
            launcherThemeColor(
                android.R.attr.colorBackground,
                android.graphics.Color.WHITE
            )
        }
        val primaryColor = if (oledTheme) {
            android.graphics.Color.WHITE
        } else {
            launcherThemeColor(
                android.R.attr.textColorPrimary,
                android.graphics.Color.BLACK
            )
        }
        val secondaryColor = if (oledTheme) {
            android.graphics.Color.rgb(176, 176, 176)
        } else {
            launcherThemeColor(
                android.R.attr.textColorSecondary,
                primaryColor
            )
        }

        val container = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(0, launcherDp(6), 0, launcherDp(6))

            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(backgroundColor)
                cornerRadius = launcherDp(5).toFloat()
            }
        }

        val heading = android.widget.TextView(this).apply {
            text = title
            textSize = 13f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setTextColor(secondaryColor)
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(launcherDp(18), launcherDp(8), launcherDp(18), launcherDp(6))
        }
        container.addView(
            heading,
            android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        val divider = android.view.View(this).apply {
            setBackgroundColor(secondaryColor)
            alpha = 0.18f
        }
        container.addView(
            divider,
            android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                launcherDp(1)
            )
        )

        val popupWidth = launcherDp(286)
        lateinit var popup: android.widget.PopupWindow

        entries.forEach { entry ->
            val row = launcherPopupRow(entry.first, primaryColor)
            row.setOnClickListener {
                popup.dismiss()
                entry.second.invoke()
            }
            container.addView(
                row,
                android.widget.LinearLayout.LayoutParams(
                    android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    android.view.ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
        }

        popup = android.widget.PopupWindow(
            container,
            popupWidth,
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            true
        ).apply {
            isOutsideTouchable = true
            setBackgroundDrawable(
                android.graphics.drawable.ColorDrawable(
                    android.graphics.Color.TRANSPARENT
                )
            )
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
                elevation = launcherDp(8).toFloat()
            }
        }

        // Right-align with the three-dot anchor while keeping the popup entirely
        // below it. showAsDropDown(), unlike the standard overflow implementation,
        // does not intentionally overlap the anchor.
        val xOffset = anchor.width - popupWidth
        popup.showAsDropDown(anchor, xOffset, launcherDp(2))
    }

    private fun showUserConfigurationPopup(anchor: android.view.View) {
        val entries = mutableListOf<Pair<String, () -> Unit>>()

        entries += getString(R.string.action_reset_user_config) to {
            removeUserConfig()
            android.widget.Toast.makeText(
                this,
                getString(R.string.user_config_was_reset),
                android.widget.Toast.LENGTH_SHORT
            ).show()
        }

        entries += getString(R.string.action_reset_user_resources) to {
            removeStaticFiles()
            removeResourceFiles()
            android.widget.Toast.makeText(
                this,
                getString(R.string.user_resources_was_reset),
                android.widget.Toast.LENGTH_SHORT
            ).show()
        }

        entries += getString(R.string.action_theme_submenu) to {
            showThemePopup(anchor)
        }

        entries += getString(R.string.action_about) to {
            showAboutDialog()
        }

        if (MyApp.haveBugsnagApiKey) {
            entries += getString(R.string.action_bugsnag_consent) to {
                askBugsnagConsent()
            }
        }

        showLauncherPopup(anchor, getString(R.string.user_configuration), entries)
    }

    private fun setLauncherTheme(
        preferenceValue: Int,
        nightMode: Int,
        displayNameRes: Int
    ) {
        val previousPreference = prefs.getInt(getString(R.string.theme), 0)
        prefs.edit()
            .putInt(getString(R.string.theme), preferenceValue)
            .apply()

        if (previousPreference != preferenceValue) {
            if (androidx.appcompat.app.AppCompatDelegate.getDefaultNightMode() == nightMode) {
                // Dark and Black/OLED both use MODE_NIGHT_YES, so switching
                // between them otherwise would not recreate the launcher.
                recreate()
            } else {
                androidx.appcompat.app.AppCompatDelegate.setDefaultNightMode(nightMode)
            }
        }

        android.widget.Toast.makeText(
            this,
            getString(R.string.theme_set_to, getString(displayNameRes)),
            android.widget.Toast.LENGTH_SHORT
        ).show()
    }

    private fun showThemePopup(anchor: android.view.View) {
        showLauncherPopup(
            anchor,
            getString(R.string.action_theme),
            listOf(
                getString(R.string.action_theme_system) to {
                    setLauncherTheme(
                        0,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM,
                        R.string.action_theme_system
                    )
                },
                getString(R.string.action_theme_light) to {
                    setLauncherTheme(
                        1,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_NO,
                        R.string.action_theme_light
                    )
                },
                getString(R.string.action_theme_dark) to {
                    setLauncherTheme(
                        2,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES,
                        R.string.action_theme_dark
                    )
                },
                getString(R.string.action_theme_oled) to {
                    setLauncherTheme(
                        3,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES,
                        R.string.action_theme_oled
                    )
                }
            )
        )
    }

    /**
     * 3rdparty-licenses.txt contains concatenated licence texts. Most top-level
     * package headings use the common:
     *
     *     Package name
     *     ------------
     *
     * format. Convert those package blocks into collapsed accordion sections.
     * If a future generated licence file does not use that format, keep all text
     * accessible in one fallback section rather than dropping anything.
     */
    private fun parseThirdPartyLicenses(text: String): List<AboutLicenseSection> {
        val normalized = text.replace("\r\n", "\n").replace('\r', '\n')
        val lines = normalized.split('\n')
        val sections = mutableListOf<AboutLicenseSection>()
        val body = mutableListOf<String>()
        var title: String? = null

        fun flush() {
            val cleaned = body.joinToString("\n").trim()
            if (cleaned.isNotEmpty()) {
                sections += AboutLicenseSection(
                    title ?: getString(R.string.third_party_notices),
                    cleaned
                )
            }
            body.clear()
        }

        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            val trimmed = line.trim()

            // "===== Name =====" style headings.
            val decorated = Regex("""^[=-]{3,}\s*(.+?)\s*[=-]{3,}$""")
                .matchEntire(trimmed)
            if (decorated != null) {
                flush()
                val parsedTitle = decorated.groupValues[1].trim()
                // A long dashed separator in the generated licence bundle is
                // parsed as a single "-" by the generic decorated-heading regex.
                // Keep it as its own licence section with a meaningful heading.
                title = if (parsedTitle == "-") "GNU General Public License" else parsedTitle
                index += 1
                continue
            }

            // "Name" followed by "-----" or "=====".
            if (trimmed.isNotEmpty() && index + 1 < lines.size) {
                val underline = lines[index + 1].trim()
                if (underline.matches(Regex("""^[=-]{3,}$"""))) {
                    flush()
                    title = trimmed
                    index += 2
                    continue
                }
            }

            body += line
            index += 1
        }

        flush()

        if (sections.isEmpty() && normalized.isNotBlank()) {
            return listOf(
                AboutLicenseSection(
                    getString(R.string.third_party_notices),
                    normalized.trim()
                )
            )
        }

        return sections
    }

    private fun getThirdPartyLicenseSections(): List<AboutLicenseSection> {
        cachedThirdPartyLicenseSections?.let { return it }

        val licenseText = assets.open("libopenmw/3rdparty-licenses.txt")
            .bufferedReader()
            .use { it.readText() }
        return parseThirdPartyLicenses(licenseText).also {
            cachedThirdPartyLicenseSections = it
        }
    }

    private fun showAboutDialog() {
        val licenseSections = getThirdPartyLicenseSections()

        val primaryColor = launcherThemeColor(
            android.R.attr.textColorPrimary,
            android.graphics.Color.BLACK
        )
        val secondaryColor = launcherThemeColor(
            android.R.attr.textColorSecondary,
            primaryColor
        )

        val content = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(
                launcherDp(24),
                launcherDp(4),
                launcherDp(24),
                launcherDp(12)
            )
        }

        val versionInfo = android.widget.TextView(this).apply {
            text = "ARM64 \u2022 v${BuildConfig.VERSION_NAME}"
            textSize = 16f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            gravity = android.view.Gravity.START
            textAlignment = android.view.View.TEXT_ALIGNMENT_VIEW_START
            setTextColor(primaryColor)
            setPadding(0, launcherDp(8), 0, 0)
        }
        content.addView(versionInfo)

        val portInfo = android.widget.TextView(this).apply {
            text = getString(R.string.about_port_info)
            textSize = 16f
            gravity = android.view.Gravity.START
            textAlignment = android.view.View.TEXT_ALIGNMENT_VIEW_START
            setTextColor(primaryColor)
            setPadding(0, launcherDp(8), 0, launcherDp(14))
        }
        content.addView(portInfo)

        licenseSections.forEach { section ->
            var bodyView: android.widget.TextView? = null
            var expanded = false

            val header = launcherPopupRow(
                "\u25b8 ${section.title}",
                primaryColor
            ).apply {
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                setPadding(launcherDp(4), 0, launcherDp(4), 0)
            }

            header.setOnClickListener {
                val body = bodyView ?: android.widget.TextView(this).apply {
                    text = section.body
                    textSize = 13f
                    setTextColor(secondaryColor)
                    setPadding(
                        launcherDp(12),
                        launcherDp(2),
                        launcherDp(8),
                        launcherDp(14)
                    )
                    visibility = android.view.View.GONE
                    setTextIsSelectable(true)
                }.also { created ->
                    bodyView = created
                    content.addView(created, content.indexOfChild(header) + 1)
                }

                expanded = !expanded
                body.visibility =
                    if (expanded) android.view.View.VISIBLE else android.view.View.GONE
                header.text =
                    (if (expanded) "\u25be " else "\u25b8 ") + section.title
            }

            content.addView(header)
        }

        val scroll = android.widget.ScrollView(this).apply {
            isFillViewport = true
            addView(
                content,
                android.widget.FrameLayout.LayoutParams(
                    android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                    android.view.ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
        }

        android.app.AlertDialog.Builder(this)
            .setTitle(getString(R.string.about_title))
            .setView(scroll)
            .setPositiveButton(android.R.string.ok) { _, _ -> }
            .show()
    }
    override fun onPrepareOptionsMenu(menu: Menu): Boolean {
        // The launcher owns its overflow popup so it can stay below the three-dot anchor.
        menu.clear()
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            R.id.action_reset_user_config -> {
                removeUserConfig()
                Toast.makeText(this, getString(R.string.user_config_was_reset), Toast.LENGTH_SHORT).show()
                true
            }

            R.id.action_reset_user_resources -> {
                removeStaticFiles()
                removeResourceFiles()
                Toast.makeText(this, getString(R.string.user_resources_was_reset), Toast.LENGTH_SHORT).show()
                true
            }

            R.id.action_theme_system -> {
                with (prefs.edit()) {
                    putInt(getString(R.string.theme), 0)
                    apply()
                }

                AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)

                Toast.makeText(this, getString(R.string.theme_set_to, getString(R.string.action_theme_system)), Toast.LENGTH_SHORT).show()
                true
            }

            R.id.action_theme_light -> {
                with (prefs.edit()) {
                    putInt(getString(R.string.theme), 1)
                    apply()
                }

                AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_NO)

                Toast.makeText(this, getString(R.string.theme_set_to, getString(R.string.action_theme_light)), Toast.LENGTH_SHORT).show()
                true
            }

            R.id.action_theme_dark -> {
                setLauncherTheme(
                    2,
                    AppCompatDelegate.MODE_NIGHT_YES,
                    R.string.action_theme_dark
                )
                true
            }

            R.id.action_theme_oled -> {
                setLauncherTheme(
                    3,
                    AppCompatDelegate.MODE_NIGHT_YES,
                    R.string.action_theme_oled
                )
                true
            }

            R.id.action_about -> {
                showAboutDialog()
                true
            }

            R.id.action_bugsnag_consent -> {
                askBugsnagConsent()
                true
            }

            else -> super.onOptionsItemSelected(item)
        }
    }

    companion object {
        private const val TAG = "OpenMW-Launcher"

        // v11.x shared custom-resolution state. MouseCursor and GameActivity
        // both reference these fields, so they must remain in this companion.
        var resolutionX = 0
        var resolutionY = 0

        // OpenMW 0.51 Android OMWFX launcher preset state.
        private const val OMWFX_PRESET_VALUE = "omwfx"
        // Historical migration key: keep it stable so existing installations
        // are not reset to the OMWFX preset during release consolidation.
        private const val OMWFX_APPLIED_PRESET_KEY =
            "launcher_shader_preset_applied_v35_openmw051_gate_h5a"

        // Final Android/GL4ES chain. WetWorld runs first so its wet surfaces
        // feed the optical stack. RainLens remains last.
        private val OMWFX_RECOMMENDED_CHAIN = listOf(
            "wetworld_android_051_weather",
            "godrays_android_051_depthfixed_vivid",
            "lensflare_android_051_rayocc",
            "gateh_bloom051",
            "rainlens_android_051_v12_dense"
        )
    }
}
