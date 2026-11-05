import Foundation

/// Dock wrapper and CLI shim for a Grok Bot clone.
///
/// Grok Bot takes its single-instance lock on the default profile. `--user-data-dir` does not
/// move that lock. `SAND_USER_DATA_DIR` and `SAND_DATA_ROOT` do.
///
/// The script execs the `Grok Bot` binary inside this wrapper (an APFS clone of the official
/// app), not `/Applications/Grok Bot.app`. After `exec`, macOS attributes the process to the
/// wrapper's bundle id. The Dock icon and `open -a "Grok Bot"` can still start the primary,
/// and ShipIt will not count the clone as a running instance of the official bundle.
/// Falling back to the official binary keeps isolation, but that process is the primary app.
public enum GrokCloneScript {
    public static let executableName = "grokbot-clone.sh"
    /// Bump when the script body changes so existing Dock wrappers rebuild
    /// even if the Lots of Agents launcher binary hash is unchanged.
    public static let revision = "2"
    public static let revisionKey = "TwoCursorsGrokScriptRevision"

    public static let bundledExecutable = "/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"
    public static let siblingBinaryName = "Grok Bot"

    /// `GROK="$DIR/Grok Bot"` — the binary next to this script, inside the wrapper.
    public static var siblingLaunchAssignment: String {
        "GROK=\"$DIR/\(siblingBinaryName)\""
    }

    public static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `true` when this wrapper execs its own binary with `SAND_*` and the current revision.
    public static func wrapperIsCurrent(executableName: String?, scriptSource: String?, revision: String?) -> Bool {
        guard executableName == Self.executableName,
              revision == Self.revision,
              let scriptSource else {
            return false
        }
        return scriptSource.contains("export \(CloneLaunchEnvironment.grokUserDataEnvironmentKey)=")
            && scriptSource.contains("export \(CloneLaunchEnvironment.grokDataRootEnvironmentKey)=")
            && scriptSource.contains(siblingLaunchAssignment)
            && scriptSource.contains("exec \"$GROK\" --use-mock-keychain \"$@\"")
            && !scriptSource.contains("--user-data-dir")
    }

    /// Script embedded in the wrapper. Creates the profile directories and execs the sibling binary.
    /// The ad-hoc-signed copy uses `--use-mock-keychain` so a rebuilt wrapper does not prompt
    /// for the official app's keychain item. The official-binary fallback does not: that flag
    /// would change the primary's credential store.
    public static func wrapperSource(profile: Profile, store: ProfileStore, officialExecutable: URL) throws -> String {
        try shellScript(
            profile: profile,
            store: store,
            launch: """
            DIR="$(cd "$(dirname "$0")" && pwd)"
            \(siblingLaunchAssignment)
            if [ -x "$GROK" ]; then
              exec "$GROK" --use-mock-keychain "$@"
            fi
            GROK=\(shellQuote(officialExecutable.path))
            if [ ! -x "$GROK" ]; then
              GROK=\(shellQuote(bundledExecutable))
            fi
            exec "$GROK" "$@"
            """
        )
    }

    /// CLI shim. The shim is not inside the wrapper, so it execs the wrapper's binary by path.
    public static func shimSource(
        profile: Profile,
        store: ProfileStore,
        wrapperExecutable: URL,
        officialExecutable: URL
    ) throws -> String {
        try shellScript(
            profile: profile,
            store: store,
            launch: """
            GROK=\(shellQuote(wrapperExecutable.path))
            if [ -x "$GROK" ]; then
              exec "$GROK" --use-mock-keychain "$@"
            fi
            GROK=\(shellQuote(officialExecutable.path))
            if [ ! -x "$GROK" ]; then
              GROK=\(shellQuote(bundledExecutable))
            fi
            exec "$GROK" "$@"
            """
        )
    }

    private static func shellScript(profile: Profile, store: ProfileStore, launch: String) throws -> String {
        let isolated = try CloneLaunchEnvironment.prepareGrokIsolation(profile: profile, store: store)
        let userData = shellQuote(isolated.userData.path)
        let dataRoot = shellQuote(isolated.dataRoot.path)
        return """
        #!/bin/bash
        # Lots of Agents — isolated Grok Bot clone.
        # These two variables are what keep this instance off the primary profile.
        # Prefer the binary in this wrapper so Dock and ShipIt still see the primary as its own app.
        unset ELECTRON_RUN_AS_NODE
        mkdir -p \(userData) \(dataRoot) || exit 1
        export \(CloneLaunchEnvironment.grokUserDataEnvironmentKey)=\(userData)
        export \(CloneLaunchEnvironment.grokDataRootEnvironmentKey)=\(dataRoot)
        \(launch)
        """
    }
}
