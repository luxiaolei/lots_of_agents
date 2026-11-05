import Foundation

/// Which running processes are the primary Grok Bot, a clone, or neither.
///
/// ShipIt (`SQRLInstallerErrorAppStillRunning`, code -9) counts a process only when its
/// bundle id is `com.anysphere.sand` AND its bundle URL is `/Applications/Grok Bot.app`.
/// A clone that has `exec`'d that exact binary is counted, so the update aborts. A clone
/// whose binary lives in its own wrapper is not.
public enum GrokInstances {
    public static let cloneBundlePrefix = "\(TwoCursorsPaths.wrapperBundlePrefix).grok."

    public struct Process: Equatable, Sendable {
        public var bundleIdentifier: String?
        public var bundleURL: URL?
        public var environment: [String: String]

        public init(bundleIdentifier: String?, bundleURL: URL?, environment: [String: String]) {
            self.bundleIdentifier = bundleIdentifier
            self.bundleURL = bundleURL
            self.environment = environment
        }
    }

    /// ShipIt's final check: same bundle id and same standardized bundle URL as the target.
    public static func blocksShipIt(bundleIdentifier: String?, bundleURL: URL?, officialAppURL: URL) -> Bool {
        guard bundleIdentifier == GrokRecipe.bundleIdentifier, let bundleURL else { return false }
        return samePath(bundleURL, officialAppURL)
    }

    public static func isCloneBundle(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix(cloneBundlePrefix)
    }

    /// A process that is using an isolated profile. The primary leaves this unset.
    public static func isIsolatedClone(environment: [String: String]) -> Bool {
        guard let dir = environment[CloneLaunchEnvironment.grokUserDataEnvironmentKey] else { return false }
        return !dir.isEmpty
    }

    /// Quit this process before an update. Includes the primary (it blocks ShipIt) and every
    /// clone (isolated env, or a wrapper bundle id).
    public static func shouldQuitForUpdate(
        bundleIdentifier: String?,
        bundleURL: URL?,
        environment: [String: String],
        officialAppURL: URL
    ) -> Bool {
        if isCloneBundle(bundleIdentifier) { return true }
        guard bundleIdentifier == GrokRecipe.bundleIdentifier else { return false }
        if blocksShipIt(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL, officialAppURL: officialAppURL) {
            return true
        }
        // Official bundle id but a different URL still holds the single-instance identity
        // macOS uses for Dock / `open -a` when the executable path is the official binary.
        return isIsolatedClone(environment: environment)
    }

    /// `open -n` is required when the only processes wearing the official bundle are clones.
    /// If nothing official is running, a normal open starts the primary. If the primary itself
    /// is running, a normal open should focus it rather than spawn a second default-profile window.
    public static func shouldForceNewPrimary(officialAppURL: URL, processes: [Process]) -> Bool {
        let holders = processes.filter {
            blocksShipIt(bundleIdentifier: $0.bundleIdentifier, bundleURL: $0.bundleURL, officialAppURL: officialAppURL)
        }
        guard !holders.isEmpty else { return false }
        let primaryRunning = holders.contains { !isIsolatedClone(environment: $0.environment) }
        return !primaryRunning
    }

    public static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        func normalize(_ url: URL) -> String {
            var path = url.resolvingSymlinksInPath().standardizedFileURL.path
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }
        return normalize(lhs).caseInsensitiveCompare(normalize(rhs)) == .orderedSame
    }
}
