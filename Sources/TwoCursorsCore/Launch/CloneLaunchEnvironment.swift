import Foundation

public enum CloneLaunchEnvironment {
    public static func make(
        profile: Profile,
        store: ProfileStore,
        recipe: any AppRecipe,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        var env = base
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        if profile.isolation == .fullHomeOverlay {
            let overlay = store.overlayHomeURL(for: profile)
            try HomeOverlay.prepare(
                overlayRoot: overlay,
                realHome: TwoCursorsPaths.accountHome(fileManager: store.fileManager),
                recipeID: profile.recipeID,
                fileManager: store.fileManager
            )
            env["HOME"] = overlay.path
            env["CURSOR_DATA_DIR"] = overlay.appendingPathComponent(".cursor").path
        }
        if recipe.id == ChatGPTRecipe().id {
            let home = profile.isolation == .fullHomeOverlay
                ? store.overlayHomeURL(for: profile)
                : TwoCursorsPaths.accountHome(fileManager: store.fileManager)
            env["CODEX_HOME"] = home.appendingPathComponent(".codex").path
            env["CODEX_ELECTRON_USER_DATA_PATH"] = store.userDataURL(for: profile).path
        }
        if recipe.id == GrokRecipe().id {
            // Grok Bot ignores `--user-data-dir` and resets its user-data path before Electron's
            // single-instance lock, so a clone started with only that flag sees the main instance
            // and exits 0. It honors these instead (`[sand] using isolated user-data dir`).
            // `SAND_DATA_ROOT` defaults to ~/.grokbot (machine credentials / daemon files); leave
            // it unset and every clone shares the main app's data root.
            // `open -n -a 'Grok Bot' --env …` does not apply them reliably. Callers must exec the
            // binary with this environment (the Dock wrapper does).
            let isolated = try prepareGrokIsolation(profile: profile, store: store)
            env[grokUserDataEnvironmentKey] = isolated.userData.path
            env[grokDataRootEnvironmentKey] = isolated.dataRoot.path
        }
        return env
    }

    public static let grokUserDataEnvironmentKey = "SAND_USER_DATA_DIR"
    public static let grokDataRootEnvironmentKey = "SAND_DATA_ROOT"

    /// `Profiles/<id>/user-data` and `Profiles/<id>/data-root`. Creates both directories.
    public static func prepareGrokIsolation(profile: Profile, store: ProfileStore) throws -> (userData: URL, dataRoot: URL) {
        let userData = store.userDataURL(for: profile)
        let dataRoot = grokDataRootURL(profile: profile, store: store)
        try store.fileManager.createDirectory(at: userData, withIntermediateDirectories: true)
        try store.fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        return (userData, dataRoot)
    }

    public static func grokDataRootURL(profile: Profile, store: ProfileStore) -> URL {
        store.profileRoot(for: profile).appendingPathComponent("data-root", isDirectory: true)
    }

    /// `--user-data-dir` to hand the app. For recipes with `needsShortUserDataPath`, a short symlink
    /// (`~/.lotsofagents/<recipe>-<slug>`) to the real profile folder.
    public static func userDataArgumentURL(profile: Profile, store: ProfileStore, recipe: any AppRecipe) throws -> URL {
        let real = store.userDataURL(for: profile)
        guard recipe.needsShortUserDataPath, !profile.adoptsDefaultData else { return real }
        let fm = store.fileManager
        let dir = TwoCursorsPaths.accountHome(fileManager: fm).appendingPathComponent(".lotsofagents", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("\(profile.recipeID)-\(profile.slug)")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != real.path {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
        }
        return link
    }

    public static func seedIfNeeded(recipe: any AppRecipe, profile: Profile, store: ProfileStore) throws {
        if recipe.seedsMarketplace {
            try ProfileSeeder.seedUserData(at: store.userDataURL(for: profile), icon: profile.icon)
        } else if recipe.seedsUpdateDisabled {
            try ProfileSeeder.seedUpdateDisabled(at: store.userDataURL(for: profile))
        }
    }
}
