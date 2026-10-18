package chat.simplex.app

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import chat.ciphertext.app.BuildConfig
import chat.simplex.common.platform.Log
import chat.simplex.common.views.helpers.AlertManager
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * In-app updater for Ciphertext.
 *
 * On every cold start the app asks GitHub for the newest release
 * (https://api.github.com/repos/battlesbudz/ciphertext/releases?per_page=1)
 * and takes the first (newest) entry. The /releases/latest endpoint is NOT
 * used: it only returns non-prereleases, and every Ciphertext release is a
 * prerelease, so it 404s.
 * Release tags look like v7.0.4-ciphertext.58. When the release is newer
 * than the installed build an update dialog is shown with a one-tap Update
 * button: the release APK is downloaded with DownloadManager and installed
 * via the system package installer.
 *
 * Every failure (no network, API rate limit, unparsable response) is silent:
 * the update check never blocks app launch.
 */
object AppUpdateChecker {
  private const val RELEASES_LIST_URL = "https://api.github.com/repos/battlesbudz/ciphertext/releases?per_page=1"
  private const val APK_FILE_NAME = "ciphertext-update.apk"
  private const val APK_MIME_TYPE = "application/vnd.android.package-archive"

  internal data class ReleaseInfo(
    val tag: String,
    val versionName: String,
    val buildNumber: Int,
    val apkUrl: String
  )

  // Guards against prompting twice within one process (e.g. activity recreation).
  private var lastPromptedTag: String? = null

  /** Starts the update check on a background thread. Safe to call on every cold start. */
  fun checkForUpdates(activity: MainActivity) {
    CoroutineScope(Dispatchers.IO).launch {
      val release = try {
        fetchLatestRelease()
      } catch (e: Exception) {
        Log.d(TAG, "AppUpdateChecker: check failed: ${e.message}")
        null
      } ?: return@launch
      val installedVersionName = installedVersionName(activity) ?: return@launch
      val installedBuildNumber = BuildConfig.CIPHERTEXT_BUILD_NUMBER
      if (!AppUpdateVersion.isUpdateAvailable(installedVersionName, installedBuildNumber, release.versionName, release.buildNumber)) {
        Log.d(TAG, "AppUpdateChecker: up to date ($installedVersionName build $installedBuildNumber)")
        return@launch
      }
      if (lastPromptedTag == release.tag) return@launch
      lastPromptedTag = release.tag
      // Let the UI settle before showing the dialog.
      delay(1500)
      withContext(Dispatchers.Main) {
        AlertManager.shared.showAlertDialog(
          title = "Update available",
          text = "A new Ciphertext update is ready: ${release.tag}. Tap Update to download and install it now.",
          confirmText = "Update",
          onConfirm = { startUpdate(activity, release) },
          dismissText = "Later"
        )
      }
    }
  }

  private fun installedVersionName(activity: MainActivity): String? {
    return try {
      val pm = activity.packageManager
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(0)).versionName
      } else {
        @Suppress("DEPRECATION")
        pm.getPackageInfo(activity.packageName, 0).versionName
      }
    } catch (e: Exception) {
      Log.d(TAG, "AppUpdateChecker: cannot read installed version: ${e.message}")
      null
    }
  }

  /**
   * Parses a GET /repos/{owner}/{repo}/releases response body (a JSON array,
   * newest first) and returns the newest usable release, or null when the
   * list is empty, unparsable, or the newest entry has no Ciphertext tag or
   * no arm64 APK asset.
   *
   * Pure function with no Android dependencies: covered by local unit tests.
   */
  internal fun parseReleaseListResponse(body: String): ReleaseInfo? {
    val releases = try {
      JSONArray(body)
    } catch (e: Exception) {
      return null
    }
    if (releases.length() == 0) return null
    val json = try {
      releases.getJSONObject(0)
    } catch (e: Exception) {
      return null
    }
    val tag = json.optString("tag_name", "")
    val parsed = AppUpdateVersion.parseReleaseTag(tag) ?: return null
    val assets = json.optJSONArray("assets") ?: return null
    var apkUrl: String? = null
    for (i in 0 until assets.length()) {
      val asset = assets.optJSONObject(i) ?: continue
      val name = asset.optString("name", "")
      if (name.endsWith(".apk") && "arm64" in name) {
        apkUrl = asset.optString("browser_download_url", "").ifEmpty { null }
        break
      }
    }
    if (apkUrl == null) return null
    return ReleaseInfo(tag, parsed.versionName, parsed.buildNumber, apkUrl)
  }

  private fun fetchLatestRelease(): ReleaseInfo? {
    val conn = (URL(RELEASES_LIST_URL).openConnection() as HttpURLConnection).apply {
      connectTimeout = 8000
      readTimeout = 8000
      setRequestProperty("Accept", "application/vnd.github+json")
      setRequestProperty("User-Agent", "ciphertext-app-updater")
    }
    try {
      if (conn.responseCode != HttpURLConnection.HTTP_OK) {
        Log.d(TAG, "AppUpdateChecker: GitHub API HTTP ${conn.responseCode}")
        return null
      }
      val body = conn.inputStream.bufferedReader().readText()
      val release = parseReleaseListResponse(body)
      if (release == null) {
        Log.d(TAG, "AppUpdateChecker: no usable release in GitHub response")
      }
      return release
    } finally {
      conn.disconnect()
    }
  }

  private fun startUpdate(activity: MainActivity, release: ReleaseInfo) {
    val appContext = activity.applicationContext
    // Android 8+: the user must allow "install unknown apps" once for this app.
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
      !appContext.packageManager.canRequestPackageInstalls()
    ) {
      withMain {
        AlertManager.shared.showAlertDialog(
          title = "Allow app installs",
          text = "To update in one tap, allow Ciphertext to install apps: turn on \"Allow from this source\" on the next screen, then come back and tap Update again.",
          confirmText = "Open settings",
          onConfirm = {
            val intent = Intent(
              Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
              Uri.parse("package:${appContext.packageName}")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
          },
          dismissText = "Cancel"
        )
      }
      return
    }
    val dest = File(appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), APK_FILE_NAME)
    if (dest.exists()) dest.delete()
    val request = DownloadManager.Request(Uri.parse(release.apkUrl))
      .setTitle("Ciphertext update")
      .setDescription("Downloading ${release.tag}")
      .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
      .setDestinationInExternalFilesDir(appContext, Environment.DIRECTORY_DOWNLOADS, APK_FILE_NAME)
      .setMimeType(APK_MIME_TYPE)
    val dm = appContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    val downloadId = dm.enqueue(request)
    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        if (intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1) != downloadId) return
        try {
          appContext.unregisterReceiver(this)
        } catch (_: Exception) {
        }
        dm.query(DownloadManager.Query().setFilterById(downloadId)).use { cursor ->
          val ok = cursor.moveToFirst() &&
            cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) == DownloadManager.STATUS_SUCCESSFUL
          if (ok) {
            installApk(appContext, dest)
          } else {
            Log.d(TAG, "AppUpdateChecker: download did not complete successfully")
          }
        }
      }
    }
    val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      @Suppress("UnspecifiedRegisterReceiverFlag")
      appContext.registerReceiver(receiver, filter)
    }
  }

  private fun installApk(context: Context, apk: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.provider", apk)
    val intent = Intent(Intent.ACTION_VIEW).apply {
      setDataAndType(uri, APK_MIME_TYPE)
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    context.startActivity(intent)
  }

  private fun withMain(block: () -> Unit) {
    CoroutineScope(Dispatchers.Main).launch { block() }
  }
}
