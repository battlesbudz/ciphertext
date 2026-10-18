package chat.simplex.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Local unit tests for the in-app updater's version logic.
 * Runs on the JVM via :android:testFossReleaseUnitTest in CI.
 */
class AppUpdateVersionTest {

  @Test
  fun parseReleaseTag_validTag() {
    val parsed = AppUpdateVersion.parseReleaseTag("v7.0.4-ciphertext.58")
    assertNotNull(parsed)
    assertEquals("7.0.4", parsed!!.versionName)
    assertEquals(58, parsed.buildNumber)
  }

  @Test
  fun parseReleaseTag_rejectsNonReleaseTags() {
    assertNull(AppUpdateVersion.parseReleaseTag(""))
    assertNull(AppUpdateVersion.parseReleaseTag("v7.0.4"))
    assertNull(AppUpdateVersion.parseReleaseTag("7.0.4-ciphertext.58"))
    assertNull(AppUpdateVersion.parseReleaseTag("v7.0.4-ciphertext."))
    assertNull(AppUpdateVersion.parseReleaseTag("v7.0.4-ciphertext.x"))
    assertNull(AppUpdateVersion.parseReleaseTag("v7.0.4-simplex.58"))
    assertNull(AppUpdateVersion.parseReleaseTag("not a tag"))
  }

  @Test
  fun compareVersionNames_ordersNumerically() {
    assertTrue(AppUpdateVersion.compareVersionNames("7.0.4", "7.0.5") < 0)
    assertTrue(AppUpdateVersion.compareVersionNames("7.0.5", "7.0.4") > 0)
    assertEquals(0, AppUpdateVersion.compareVersionNames("7.0.4", "7.0.4"))
    // Numeric, not lexicographic: 10 > 9
    assertTrue(AppUpdateVersion.compareVersionNames("7.0.10", "7.0.9") > 0)
    assertTrue(AppUpdateVersion.compareVersionNames("7.10.0", "7.9.9") > 0)
    // Missing segments count as zero
    assertEquals(0, AppUpdateVersion.compareVersionNames("7.0", "7.0.0"))
  }

  @Test
  fun isUpdateAvailable_newerBuildOfSameVersion() {
    assertTrue(AppUpdateVersion.isUpdateAvailable("7.0.4", 54, "7.0.4", 58))
  }

  @Test
  fun isUpdateAvailable_newerVersionName() {
    assertTrue(AppUpdateVersion.isUpdateAvailable("7.0.4", 58, "7.0.5", 1))
    assertTrue(AppUpdateVersion.isUpdateAvailable("7.0.4", 999, "7.0.5", 1))
  }

  @Test
  fun isUpdateAvailable_sameOrOlderIsNotAnUpdate() {
    assertFalse(AppUpdateVersion.isUpdateAvailable("7.0.4", 58, "7.0.4", 58))
    assertFalse(AppUpdateVersion.isUpdateAvailable("7.0.4", 59, "7.0.4", 58))
    assertFalse(AppUpdateVersion.isUpdateAvailable("7.0.5", 1, "7.0.4", 99))
  }

  @Test
  fun isUpdateAvailable_devBuildWithoutBuildNumberSeesReleaseAsNewer() {
    // Local/dev builds embed build number 0, so any published release is newer.
    assertTrue(AppUpdateVersion.isUpdateAvailable("7.0.4", 0, "7.0.4", 58))
  }
}
