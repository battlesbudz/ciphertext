package chat.simplex.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Local unit tests for the in-app updater's release-list parsing.
 *
 * The checker queries GET /releases?per_page=1 (a JSON array, newest first)
 * because /releases/latest 404s: it only returns non-prereleases, and every
 * Ciphertext release is a prerelease.
 * Runs on the JVM via :android:testFossReleaseUnitTest in CI.
 */
class AppUpdateCheckerTest {

  private fun releaseListJson(vararg releases: String): String =
    "[${releases.joinToString(",")}]"

  private fun releaseJson(tag: String, prerelease: Boolean, assetNames: List<String>): String {
    val assets = assetNames.joinToString(",") { name ->
      """{"name":"$name","browser_download_url":"https://github.com/battlesbudz/ciphertext/releases/download/$tag/$name"}"""
    }
    return """{"tag_name":"$tag","prerelease":$prerelease,"assets":[$assets]}"""
  }

  @Test
  fun parseReleaseListResponse_usesNewestPrereleaseEntry() {
    // Live shape: prerelease=true entries, newest first.
    val body = releaseListJson(
      releaseJson("v7.0.4-ciphertext.60", true, listOf("ciphertext-7.0.4-arm64.apk")),
      releaseJson("v7.0.4-ciphertext.59", true, listOf("ciphertext-7.0.4-arm64.apk"))
    )
    val info = AppUpdateChecker.parseReleaseListResponse(body)
    assertNotNull(info)
    assertEquals("v7.0.4-ciphertext.60", info!!.tag)
    assertEquals("7.0.4", info.versionName)
    assertEquals(60, info.buildNumber)
    assertTrue(info.apkUrl.endsWith("ciphertext-7.0.4-arm64.apk"))
  }

  @Test
  fun parseReleaseListResponse_emptyListReturnsNull() {
    assertNull(AppUpdateChecker.parseReleaseListResponse("[]"))
  }

  @Test
  fun parseReleaseListResponse_unparsableBodyReturnsNull() {
    assertNull(AppUpdateChecker.parseReleaseListResponse("not json"))
    assertNull(AppUpdateChecker.parseReleaseListResponse(""))
    assertNull(AppUpdateChecker.parseReleaseListResponse("""{"tag_name":"v7.0.4-ciphertext.60"}"""))
  }

  @Test
  fun parseReleaseListResponse_nonCiphertextTagReturnsNull() {
    val body = releaseListJson(
      releaseJson("v7.0.4", false, listOf("ciphertext-7.0.4-arm64.apk"))
    )
    assertNull(AppUpdateChecker.parseReleaseListResponse(body))
  }

  @Test
  fun parseReleaseListResponse_missingApkAssetReturnsNull() {
    val body = releaseListJson(
      releaseJson("v7.0.4-ciphertext.60", true, listOf("notes.txt"))
    )
    assertNull(AppUpdateChecker.parseReleaseListResponse(body))
  }

  @Test
  fun parseReleaseListResponse_picksArm64ApkAmongAssets() {
    val body = releaseListJson(
      releaseJson(
        "v7.0.4-ciphertext.60", true,
        listOf("ciphertext-7.0.4-universal.apk", "ciphertext-7.0.4-arm64.apk")
      )
    )
    val info = AppUpdateChecker.parseReleaseListResponse(body)
    assertNotNull(info)
    assertTrue(info!!.apkUrl.contains("arm64"))
  }
}
