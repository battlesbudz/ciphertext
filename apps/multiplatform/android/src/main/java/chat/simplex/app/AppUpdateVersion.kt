package chat.simplex.app

/**
 * Pure version logic for the Ciphertext in-app updater.
 *
 * Release tags look like v7.0.4-ciphertext.58, i.e.
 * v<versionName>-ciphertext.<buildNumber>, where <buildNumber> is the
 * GitHub Actions run number of the release build. It lets the updater tell
 * newer builds of the same version apart (e.g. .58 is newer than .54).
 *
 * No Android dependencies: covered by local unit tests.
 */
object AppUpdateVersion {
  data class ParsedTag(val versionName: String, val buildNumber: Int)

  private val TAG_REGEX = Regex("^v([0-9]+(?:\\.[0-9]+)*)-ciphertext\\.([0-9]+)$")

  /** Parses a release tag, or null when it is not a Ciphertext release tag. */
  fun parseReleaseTag(tag: String): ParsedTag? {
    val match = TAG_REGEX.matchEntire(tag.trim()) ?: return null
    val buildNumber = match.groupValues[2].toIntOrNull() ?: return null
    return ParsedTag(versionName = match.groupValues[1], buildNumber = buildNumber)
  }

  /**
   * Compares dotted numeric version names segment by segment.
   * Returns negative, zero, or positive. "7.0.10" is newer than "7.0.9";
   * "7.0" and "7.0.0" are equal.
   */
  fun compareVersionNames(a: String, b: String): Int {
    val pa = a.split(".")
    val pb = b.split(".")
    for (i in 0 until maxOf(pa.size, pb.size)) {
      val x = pa.getOrNull(i)?.toIntOrNull() ?: 0
      val y = pb.getOrNull(i)?.toIntOrNull() ?: 0
      if (x != y) return x.compareTo(y)
    }
    return 0
  }

  /**
   * True when the release is newer than the installed build: either a newer
   * versionName, or the same versionName with a higher build number.
   */
  fun isUpdateAvailable(
    installedVersionName: String,
    installedBuildNumber: Int,
    releaseVersionName: String,
    releaseBuildNumber: Int
  ): Boolean {
    val cmp = compareVersionNames(installedVersionName.trim(), releaseVersionName.trim())
    if (cmp != 0) return cmp < 0
    return releaseBuildNumber > installedBuildNumber
  }
}
