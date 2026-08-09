package utils

import android.app.Application
import android.content.pm.PackageManager
import android.os.Environment
import android.preference.PreferenceManager
import android.util.Base64
import android.util.Log
import com.bugsnag.android.Bugsnag
import com.bugsnag.android.Configuration
import constants.Constants
import java.io.File
import java.security.MessageDigest

class MyApp : Application() {

    var defaultScaling = 0f

    override fun onCreate() {
        app = this

        super.onCreate()

        setupPaths()

        // Enable Bugsnag only when an API key is provided and we have user consent.
        // Also don't enable Bugsnag in debug builds.
        if (isProductionBuild() && BugsnagApiKey.API_KEY.isNotEmpty() && !com.libopenmw.openmw.BuildConfig.DEBUG) {
            haveBugsnagApiKey = true

            val prefs = PreferenceManager.getDefaultSharedPreferences(this)
            if (prefs.getString("bugsnag_consent", "false") == "true") {
                val config = Configuration(BugsnagApiKey.API_KEY)
                config.buildUUID = ""
                Bugsnag.init(this, config)
                reportCrashes = true
            }
        }
    }

    private fun setupPaths() {
        // Android-conform app-specific external storage. Do not construct
        // /storage/emulated/0/Android/data paths manually; Android supplies
        // the correct volume/package path here (also on ChromeOS).
        val externalBase = getExternalFilesDir(null)
        val userRoot = if (externalBase != null) {
            File(externalBase, USER_STORAGE_DIRECTORY)
        } else {
            // Very unusual fallback when shared/external storage is unavailable.
            // OpenMW can still run with an internal user-data directory.
            Log.w(TAG, "getExternalFilesDir(null) returned null; using internal user storage.")
            File(filesDir, "user/$USER_STORAGE_DIRECTORY")
        }

        Constants.USER_FILE_STORAGE = userRoot.absolutePath

        // With the canonical applicationId com.ast.openmw this normally resolves to:
        // /storage/emulated/0/Android/data/com.ast.openmw/files/OpenMW
        Constants.USER_CONFIG = File(userRoot, "config").absolutePath
        Constants.USER_OPENMW_CFG = File(userRoot, "config/openmw.cfg").absolutePath

        Constants.DEFAULTS_BIN = File(filesDir, "config/defaults.bin").absolutePath
        Constants.OPENMW_CFG = File(filesDir, "config/openmw.cfg").absolutePath
        Constants.OPENMW_BASE_CFG = File(filesDir, "config/openmw.base.cfg").absolutePath
        Constants.OPENMW_FALLBACK_CFG = File(filesDir, "config/openmw.fallback.cfg").absolutePath
        Constants.RESOURCES = File(filesDir, "resources").absolutePath
        Constants.GLOBAL_CONFIG = File(filesDir, "config").absolutePath
        Constants.VERSION_STAMP = File(filesDir, "stamp").absolutePath

        Log.i(TAG, "OpenMW user storage: ${Constants.USER_FILE_STORAGE}")
    }

    /**
     * One-time migration of the old public /storage/emulated/0/omw tree.
     *
     * This is intentionally called from MainActivity.onResume(), rather than
     * Application.onCreate(), because an existing installation may still need
     * to grant legacy shared-storage permission before the old tree is readable.
     *
     * The migration includes saves, screenshots, config, icons, resources and
     * navmesh.db. The old tree is deleted only after a verified successful copy.
     */
    @Synchronized
    fun migrateLegacyUserStorageIfPossible() {
        val target = File(Constants.USER_FILE_STORAGE)

        try {
            val legacy = File(Environment.getExternalStorageDirectory(), LEGACY_USER_STORAGE_DIRECTORY)

            if (!legacy.isDirectory) {
                target.mkdirs()
                return
            }

            // Never attempt to migrate if paths unexpectedly resolve to the same place.
            if (legacy.canonicalFile == target.canonicalFile) {
                target.mkdirs()
                return
            }

            target.parentFile?.mkdirs()

            // Fast path: a rename preserves timestamps and avoids copying large saves/resources.
            if (!target.exists() && legacy.renameTo(target)) {
                Log.i(TAG, "Migrated legacy OpenMW storage by rename: ${legacy.absolutePath} -> ${target.absolutePath}")
                return
            }

            // Fallback for FUSE/scoped-storage implementations where rename across
            // directory classes is rejected. Legacy data wins during this one-time
            // migration; the launcher will refresh generated resources afterwards.
            if (!target.exists() && !target.mkdirs()) {
                Log.w(TAG, "Could not create OpenMW user storage at ${target.absolutePath}")
                return
            }

            val copied = legacy.copyRecursively(
                target = target,
                overwrite = true,
                onError = { file, exception ->
                    Log.e(TAG, "Failed migrating ${file.absolutePath}", exception)
                    kotlin.io.OnErrorAction.TERMINATE
                }
            )

            if (!copied || !verifyMigration(legacy, target)) {
                Log.w(
                    TAG,
                    "Legacy OpenMW storage migration was incomplete; keeping ${legacy.absolutePath} as a safety copy."
                )
                return
            }

            if (legacy.deleteRecursively()) {
                Log.i(TAG, "Legacy OpenMW storage migrated and removed: ${legacy.absolutePath}")
            } else {
                Log.w(
                    TAG,
                    "Migration succeeded, but the old directory could not be removed: ${legacy.absolutePath}"
                )
            }
        } catch (e: SecurityException) {
            // Expected on a first launch before legacy storage permission is granted.
            Log.w(TAG, "Legacy /omw migration is not permitted yet; it will be retried.", e)
            target.mkdirs()
        } catch (e: Exception) {
            Log.e(TAG, "Legacy /omw migration failed; keeping the old directory untouched.", e)
            target.mkdirs()
        }
    }

    private fun verifyMigration(source: File, target: File): Boolean {
        return try {
            source.walkTopDown()
                .filter { it.isFile }
                .all { sourceFile ->
                    val relative = sourceFile.relativeTo(source).path
                    val targetFile = File(target, relative)
                    targetFile.isFile && targetFile.length() == sourceFile.length()
                }
        } catch (e: Exception) {
            Log.e(TAG, "Could not verify legacy OpenMW storage migration.", e)
            false
        }
    }

    private fun isProductionBuild(): Boolean {
        val packageInfo = applicationContext.packageManager.getPackageInfo(
            applicationContext.packageName,
            PackageManager.GET_SIGNATURES
        )
        val sig = packageInfo.signatures?.firstOrNull() ?: return false
        val digest = MessageDigest.getInstance("SHA-256")
        val hashBytes = digest.digest(sig.toByteArray())
        val hash = Base64.encodeToString(hashBytes, Base64.NO_WRAP)
        return hash == "cOqSYH3ucLraOQ7wyg/v8UKTGHlxP8N8JTN6UXO7rV0="
    }

    companion object {
        private const val TAG = "OpenMW-Storage"
        private const val USER_STORAGE_DIRECTORY = "OpenMW"
        private const val LEGACY_USER_STORAGE_DIRECTORY = "omw"

        var reportCrashes = false
        var haveBugsnagApiKey = false
        lateinit var app: MyApp
    }
}
