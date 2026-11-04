import Foundation

/// Dock wrapper and CLI shim for a Grok Bot clone.
///
/// Grok Bot (`com.anysphere.sand`) takes its single-instance lock on the default
/// profile. `--user-data-dir` does not move that lock, so a second process finds
/// the running app and exits immediately. The process that stays up is the
/// official signed binary, with `SAND_USER_DATA_DIR` and `SAND_DATA_ROOT` set.
/// A re-signed bundle copy (what `TwoCursorsLauncher` execs for other apps) quits.
public enum GrokCloneScript {
    public static let executableName = "grokbot-clone.sh"
    /// Bump when the script body changes so existing Dock wrappers rebuild
    /// even if the Lots of Agents launcher binary hash is unchanged.
    public static let revision = "1"
    public static let revisionKey = "TwoCursorsGrokScriptRevision"

    public static let bundledExecutable = "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"

    public static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `true` when this wrapper is the script launcher, not `TwoCursorsLauncher`.
    public static func wrapperIsCurrent(executableName: String?, scriptSource: String?, revision: String?) -> Bool {
        guard executableName == Self.executableName,
              revision == Self.revision,
              let scriptSource else {
            return false
        }
        return scriptSource.contains("export \(CloneLaunchEnvironment.grokUserDataEnvironmentKey)=")
            && scriptSource.contains("export \(CloneLaunchEnvironment.grokDataRootEnvironmentKey)=")
            && !scriptSource.contains("--user-data-dir")
            && !scriptSource.contains("--use-mock-keychain")
    }

    /// Creates the profile directories and returns the wrapper script.
    /// The script itself also creates them, so a click works before Lots of Agents
    /// has rebuilt the wrapper.
    public static func source(profile: Profile, store: ProfileStore, officialExecutable: URL) throws -> String {
        let isolated = try CloneLaunchEnvironment.prepareGrokIsolation(profile: profile, store: store)
        let userData = shellQuote(isolated.userData.path)
        let dataRoot = shellQuote(isolated.dataRoot.path)
        let official = shellQuote(officialExecutable.path)
        let bundled = shellQuote(bundledExecutable)
        return """
        #!/bin/bash
        # Lots of Agents — isolated Grok Bot clone.
        # The official signed binary stays up only when these two variables are set.
        # A re-signed bundle copy quits on the default single-instance lock.
        unset ELECTRON_RUN_AS_NODE
        mkdir -p \(userData) \(dataRoot) || exit 1
        export \(CloneLaunchEnvironment.grokUserDataEnvironmentKey)=\(userData)
        export \(CloneLaunchEnvironment.grokDataRootEnvironmentKey)=\(dataRoot)
        GROK=\(official)
        if [ ! -x "$GROK" ]; then
          GROK=\(bundled)
        fi
        if [ ! -x "$GROK" ]; then
          GROK="$HOME/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"
        fi
        exec "$GROK" "$@"
        """
    }
}
