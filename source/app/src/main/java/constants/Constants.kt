/*
    Copyright (C) 2015, 2016 sandstranger
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

package constants

object Constants {
    const val APP_PREFERENCES = "settings"
    const val HIDE_CONTROLS = "pref_hide_controls"

    // User-owned OpenMW data root.
    //
    // This is initialized from Context.getExternalFilesDir(null) by MyApp:
    //   /storage/emulated/0/Android/data/com.ast.openmw/files/OpenMW
    //
    // It contains saves, screenshots, user config, custom control icons,
    // the writable resource mirror, navmesh.db and other engine user data.
    var USER_FILE_STORAGE = ""

    // Internal APK-provided/default configuration.
    // e.g. /data/user/0/com.ast.openmw/files/config/defaults.bin
    var DEFAULTS_BIN = ""

    // Generated launcher configuration used as global config.
    // e.g. /data/user/0/com.ast.openmw/files/config/openmw.cfg
    var OPENMW_CFG = ""

    var OPENMW_BASE_CFG = ""
    var OPENMW_FALLBACK_CFG = ""

    // Internal engine resource payload copied from APK assets.
    // e.g. /data/user/0/com.ast.openmw/files/resources
    var RESOURCES = ""

    // Internal global config directory.
    // e.g. /data/user/0/com.ast.openmw/files/config
    var GLOBAL_CONFIG = ""

    // User config directory below USER_FILE_STORAGE.
    // e.g. .../Android/data/com.ast.openmw/files/OpenMW/config
    var USER_CONFIG = ""

    // User-editable OpenMW config below USER_CONFIG.
    var USER_OPENMW_CFG = ""

    // Contains app version code for currently deployed internal resources.
    var VERSION_STAMP = ""
}
