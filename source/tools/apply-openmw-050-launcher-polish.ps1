$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ManifestPath = Join-Path $ProjectRoot 'app\src\main\AndroidManifest.xml'

if (-not (Test-Path $ManifestPath)) {
    throw "AndroidManifest.xml not found: $ManifestPath"
}

$MainActivityCandidates = @(
    (Join-Path $ProjectRoot 'app\src\main\java\ui\activity\MainActivity.kt'),
    (Join-Path $ProjectRoot 'app\src\main\kotlin\ui\activity\MainActivity.kt')
)

$MainActivityPath = $MainActivityCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $MainActivityPath) {
    $MainActivityPath = Get-ChildItem -Path (Join-Path $ProjectRoot 'app\src\main') -Recurse -Filter 'MainActivity.kt' |
        Where-Object { $_.FullName -match '[\\/]ui[\\/]activity[\\/]MainActivity\.kt$' } |
        Select-Object -ExpandProperty FullName -First 1
}
if (-not $MainActivityPath) {
    throw 'Could not locate ui/activity/MainActivity.kt.'
}

function Read-Lf([string]$Path) {
    return [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Write-Utf8Lf([string]$Path, [string]$Text) {
    $Text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Backup-Once([string]$Path) {
    $backup = "$Path.before-v14.1-launcher-polish"
    if (-not (Test-Path $backup)) {
        Copy-Item $Path $backup
    }
}

Write-Host "OpenMW 0.50 launcher polish v14.1.1" -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot"
Write-Host "MainActivity: $MainActivityPath"
Write-Host ''

# -----------------------------------------------------------------------------
# 1. Android game classification
# -----------------------------------------------------------------------------
Backup-Once $ManifestPath
$manifest = Read-Lf $ManifestPath

if ($manifest -match 'android:appCategory\s*=') {
    $manifest = [regex]::Replace(
        $manifest,
        'android:appCategory\s*=\s*"[^"]*"',
        'android:appCategory="game"',
        1
    )
} else {
    $applicationMatches = [regex]::Matches($manifest, '<application\b')
    if ($applicationMatches.Count -ne 1) {
        throw "Expected exactly one <application> element in AndroidManifest.xml; found $($applicationMatches.Count)."
    }
    $manifest = $manifest.Insert(
        $applicationMatches[0].Index + $applicationMatches[0].Length,
        "`n        android:appCategory=`"game`""
    )
}

# Non-restrictive controller declaration. It does not make a gamepad mandatory,
# but gives Android/OEM game surfaces an accurate capability hint.
if ($manifest -notmatch 'android:name\s*=\s*"android\.hardware\.gamepad"') {
    $applicationIndex = $manifest.IndexOf('<application')
    if ($applicationIndex -lt 0) {
        throw 'Could not find <application> insertion point for gamepad feature.'
    }
    $feature = '    <uses-feature android:name="android.hardware.gamepad" android:required="false" />' + "`n`n"
    $manifest = $manifest.Insert($applicationIndex, $feature)
}

Write-Utf8Lf $ManifestPath $manifest
Write-Host 'OK: Android manifest now declares android:appCategory="game".' -ForegroundColor Green

# -----------------------------------------------------------------------------
# 2. Launcher overflow popup + expandable About screen
# -----------------------------------------------------------------------------
Backup-Once $MainActivityPath
$main = Read-Lf $MainActivityPath

$marker = '// v14.1 launcher popup/about polish'
if ($main.Contains($marker)) {
    Write-Host 'MainActivity launcher polish is already applied; leaving it unchanged.' -ForegroundColor Yellow
} else {
    $oldToolbar = '        setSupportActionBar(findViewById(R.id.main_toolbar))'
    $newToolbar = @'
        val launcherToolbar =
            findViewById<androidx.appcompat.widget.Toolbar>(R.id.main_toolbar)
        setSupportActionBar(launcherToolbar)
        installUserConfigurationOverflow(launcherToolbar)
'@

    $toolbarCount = ([regex]::Matches($main, [regex]::Escape($oldToolbar))).Count
    if ($toolbarCount -ne 1) {
        throw "Expected one MainActivity toolbar setup anchor; found $toolbarCount."
    }
    $main = $main.Replace($oldToolbar, $newToolbar.TrimEnd())

    $helper = @'
    // v14.1 launcher popup/about polish
    private data class AboutLicenseSection(
        val title: String,
        val body: String
    )

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
            contentDescription = "User Configuration"
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
        val backgroundColor = launcherThemeColor(
            android.R.attr.colorBackground,
            android.graphics.Color.WHITE
        )
        val primaryColor = launcherThemeColor(
            android.R.attr.textColorPrimary,
            android.graphics.Color.BLACK
        )
        val secondaryColor = launcherThemeColor(
            android.R.attr.textColorSecondary,
            primaryColor
        )

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

        entries += "Reset user configuration" to {
            removeUserConfig()
            android.widget.Toast.makeText(
                this,
                getString(R.string.user_config_was_reset),
                android.widget.Toast.LENGTH_SHORT
            ).show()
        }

        entries += "Reset user resources" to {
            removeStaticFiles()
            removeResourceFiles()
            android.widget.Toast.makeText(
                this,
                getString(R.string.user_resources_was_reset),
                android.widget.Toast.LENGTH_SHORT
            ).show()
        }

        entries += "Theme \u203a" to {
            showThemePopup(anchor)
        }

        entries += "About" to {
            showAboutDialog()
        }

        if (MyApp.haveBugsnagApiKey) {
            entries += "Crash reporting" to {
                askBugsnagConsent()
            }
        }

        showLauncherPopup(anchor, "User Configuration", entries)
    }

    private fun setLauncherTheme(
        preferenceValue: Int,
        nightMode: Int,
        displayName: String
    ) {
        prefs.edit()
            .putInt(getString(R.string.theme), preferenceValue)
            .apply()

        androidx.appcompat.app.AppCompatDelegate.setDefaultNightMode(nightMode)

        android.widget.Toast.makeText(
            this,
            "Theme set to $displayName",
            android.widget.Toast.LENGTH_SHORT
        ).show()
    }

    private fun showThemePopup(anchor: android.view.View) {
        showLauncherPopup(
            anchor,
            "Theme",
            listOf(
                "System" to {
                    setLauncherTheme(
                        0,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM,
                        "system"
                    )
                },
                "Light" to {
                    setLauncherTheme(
                        1,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_NO,
                        "light"
                    )
                },
                "Dark" to {
                    setLauncherTheme(
                        2,
                        androidx.appcompat.app.AppCompatDelegate.MODE_NIGHT_YES,
                        "dark"
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
                    title ?: "Third-party notices",
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
                title = decorated.groupValues[1].trim()
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
                    "Third-party notices",
                    normalized.trim()
                )
            )
        }

        return sections
    }

    private fun showAboutDialog() {
        val licenseText = assets.open("libopenmw/3rdparty-licenses.txt")
            .bufferedReader()
            .use { it.readText() }

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
                launcherDp(20),
                launcherDp(4),
                launcherDp(20),
                launcherDp(12)
            )
        }

        val portInfo = android.widget.TextView(this).apply {
            text =
                "This port by Andreas \"Andiweli\" Stürmer\n" +
                "Based on a port of CaveBros\n" +
                "OpenMW by the OpenMW Team since 2008"
            textSize = 16f
            setTextColor(primaryColor)
            setPadding(0, launcherDp(8), 0, launcherDp(14))
        }
        content.addView(portInfo)

        parseThirdPartyLicenses(licenseText).forEach { section ->
            val body = android.widget.TextView(this).apply {
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
            }

            val header = launcherPopupRow(
                "\u25b8 ${section.title}",
                primaryColor
            ).apply {
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                setPadding(launcherDp(4), 0, launcherDp(4), 0)

                setOnClickListener {
                    val expand = body.visibility != android.view.View.VISIBLE
                    body.visibility =
                        if (expand) android.view.View.VISIBLE else android.view.View.GONE
                    text =
                        (if (expand) "\u25be " else "\u25b8 ") + section.title
                }
            }

            content.addView(header)
            content.addView(body)
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

'@

    $prepareAnchor = '    override fun onPrepareOptionsMenu(menu: Menu): Boolean {'
    $prepareIndex = $main.IndexOf($prepareAnchor)
    if ($prepareIndex -lt 0) {
        throw 'Could not find onPrepareOptionsMenu() anchor in MainActivity.kt.'
    }
    $main = $main.Insert($prepareIndex, $helper)

    # Do not inflate the stock AppCompat overflow; our custom anchor/menu replaces
    # it so there is only one three-dot icon.
    $preparePattern = '(?s)    override fun onPrepareOptionsMenu\(menu: Menu\): Boolean \{.*?\n    \}\n\n    override fun onOptionsItemSelected'
    $prepareMatches = [regex]::Matches($main, $preparePattern)
    if ($prepareMatches.Count -ne 1) {
        throw "Expected one onPrepareOptionsMenu block; found $($prepareMatches.Count)."
    }
    $prepareReplacement = @'
    override fun onPrepareOptionsMenu(menu: Menu): Boolean {
        menu.clear()
        return true
    }

    override fun onOptionsItemSelected
'@
    $main = [regex]::Replace($main, $preparePattern, $prepareReplacement, 1)

    # Keep the existing handler useful as a fallback (e.g. future accessibility
    # or toolbar changes), but route About through the new expandable dialog.
    $aboutPattern = '(?s)            R\.id\.action_about -> \{.*?\n                true\n            \}\n\n            R\.id\.action_bugsnag_consent'
    $aboutMatches = [regex]::Matches($main, $aboutPattern)
    if ($aboutMatches.Count -eq 1) {
        $aboutReplacement = @'
            R.id.action_about -> {
                showAboutDialog()
                true
            }

            R.id.action_bugsnag_consent
'@
        $main = [regex]::Replace($main, $aboutPattern, $aboutReplacement, 1)
    } elseif ($aboutMatches.Count -gt 1) {
        throw "Found more than one action_about handler; refusing an ambiguous patch."
    }

    Write-Utf8Lf $MainActivityPath $main
    Write-Host 'OK: custom below-anchor User Configuration popup installed.' -ForegroundColor Green
    Write-Host 'OK: About dialog now uses collapsed per-license sections.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Launcher polish v14.1.1: SUCCESS' -ForegroundColor Green
Write-Host 'No native OpenMW rebuild is required.' -ForegroundColor Green
Write-Host 'Build with: .\gradlew.bat :app:assembleMainlineDebug' -ForegroundColor Cyan
