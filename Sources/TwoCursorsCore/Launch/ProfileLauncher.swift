import AppKit
import Combine
import Foundation

public struct ProfileLauncher {
    public var fileManager: FileManager
    public var workspace: NSWorkspace

    public init(fileManager: FileManager = .default, workspace: NSWorkspace = .shared) {
        self.fileManager = fileManager
        self.workspace = workspace
    }

    public func launch(
        _ profile: Profile,
        store: ProfileStore,
        recipe: any AppRecipe,
        status: AppStatus,
        preferWrapper: Bool = true
    ) throws {
        guard status.isInstalled, let appURL = status.appURL, let executable = status.executableURL else {
            throw TwoCursorsError.appNotInstalled(recipe.displayName)
        }
        guard status.isExecutable || fileManager.isExecutableFile(atPath: executable.path) else {
            throw TwoCursorsError.executableMissing(executable)
        }

        try store.prepareDirectories(for: profile)
        try CloneLaunchEnvironment.seedIfNeeded(recipe: recipe, profile: profile, store: store)

        let wrapperURL = TwoCursorsPaths.wrappersDirectory(fileManager: fileManager)
            .appendingPathComponent(profile.wrapperFileName)
        // Open the Dock wrapper. Grok's `grokbot-clone.sh` exports SAND_* and execs the binary
        // inside the wrapper, so this bundle — not `/Applications/Grok Bot.app` — is the running
        // app. `open -n -a 'Grok Bot' --env` does not deliver those variables.
        if preferWrapper, fileManager.fileExists(atPath: wrapperURL.path) {
            if recipe.id == GrokRecipe().id {
                for scheme in recipe.urlSchemes {
                    LSSetDefaultHandlerForURLScheme(scheme as CFString, profile.wrapperBundleIdentifier as CFString)
                }
            }
            let config = NSWorkspace.OpenConfiguration()
            // A real bundle (Grok script host, or a Cursor/Claude/ChatGPT clone) should focus
            // the running copy. Only a thin wrapper that exits needs a brand-new instance.
            config.createsNewApplicationInstance = !(recipe.clonesAppBundle || recipe.launchesOfficialBinary)
            config.activates = true
            workspace.openApplication(at: wrapperURL, configuration: config) { _, error in
                if let error {
                    NSLog("TwoCursors wrapper launch failed: \(error.localizedDescription)")
                }
            }
            return
        }

        try launchExecutable(executable, appURL: appURL, profile: profile, store: store, recipe: recipe)
    }

    public func launchExecutable(
        _ executable: URL,
        appURL: URL,
        profile: Profile,
        store: ProfileStore,
        recipe: any AppRecipe
    ) throws {
        let userData = try CloneLaunchEnvironment.userDataArgumentURL(profile: profile, store: store, recipe: recipe)
        let extensions = store.extensionsURL(for: profile)
        let env = try CloneLaunchEnvironment.make(profile: profile, store: store, recipe: recipe)

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        config.arguments = recipe.launchArguments(userData: userData, extensions: extensions)
        config.environment = env
        workspace.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                NSLog("TwoCursors launch failed: \(error.localizedDescription)")
            }
        }
        _ = executable
    }

    public func quit(profile: Profile, store: ProfileStore) {
        let userData = store.userDataURL(for: profile).resolvingSymlinksInPath()
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            let snapshot = ProcessArguments.snapshot(for: app.processIdentifier)
            guard let dir = ProcessArguments.isolatedUserDataDir(in: snapshot) else { continue }
            if URL(fileURLWithPath: dir).resolvingSymlinksInPath() == userData {
                app.terminate()
            }
        }
    }

    public func openOfficialAppForUpdate(status: AppStatus) throws {
        guard let appURL = status.appURL else {
            throw TwoCursorsError.appNotInstalled(status.displayName)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        config.activates = true
        workspace.openApplication(at: appURL, configuration: config)
    }

    /// Opens the official Grok Bot even when clones are running.
    ///
    /// Clones that still `exec` the official binary wear its bundle id, so a plain `open` only
    /// focuses them. `createsNewApplicationInstance` starts the default-profile primary beside them.
    /// After wrappers are rebuilt, clones have their own bundle and a plain open is enough.
    public func openGrokPrimary(appURL: URL) {
        LSSetDefaultHandlerForURLScheme("sand" as CFString, GrokRecipe.bundleIdentifier as CFString)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = GrokInstances.shouldForceNewPrimary(
            officialAppURL: appURL,
            processes: grokProcesses()
        )
        workspace.openApplication(at: appURL, configuration: config)
    }

    /// Quits every process ShipIt would treat as Grok Bot.app, plus clone wrappers.
    /// `force` is SIGKILL, used after a normal quit did not exit.
    public func quitAllGrokInstances(officialAppURL: URL, force: Bool) {
        for app in workspace.runningApplications {
            let environment = ProcessArguments.environment(for: app.processIdentifier)
            guard GrokInstances.shouldQuitForUpdate(
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                environment: environment,
                officialAppURL: officialAppURL
            ) else { continue }
            if force {
                app.forceTerminate()
            } else {
                app.terminate()
            }
        }
    }

    private func grokProcesses() -> [GrokInstances.Process] {
        workspace.runningApplications.map { app in
            GrokInstances.Process(
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                environment: ProcessArguments.environment(for: app.processIdentifier)
            )
        }
    }
}

public enum RunningCloneDetector {
    public static func runningProfileIDs(
        profiles: [Profile],
        store: ProfileStore,
        applications: [RunningApplicationInfo]? = nil
    ) -> Set<UUID> {
        let apps = applications ?? WorkspaceRunningApps().runningApplications()
        var live: Set<UUID> = []
        for app in apps {
            let snapshot = ProcessArguments.snapshot(for: app.processIdentifier)
            guard let dir = ProcessArguments.isolatedUserDataDir(in: snapshot) else { continue }
            let standardized = URL(fileURLWithPath: dir).resolvingSymlinksInPath()
            for profile in profiles {
                let expected = store.userDataURL(for: profile).resolvingSymlinksInPath()
                if expected == standardized {
                    live.insert(profile.id)
                }
            }
        }
        return live
    }
}

@MainActor
public final class SignInCoordinator: ObservableObject {
    @Published public private(set) var isSigningIn = false
    @Published public private(set) var profileID: UUID?
    @Published public private(set) var pausedIDs: [UUID] = []
    @Published public private(set) var displayName = "Grok Bot"
    @Published public private(set) var urlScheme = "sand"

    public init() {}

    public func begin(
        profile: Profile,
        store: ProfileStore,
        launcher: ProfileLauncher,
        recipe: any AppRecipe,
        status: AppStatus
    ) throws {
        let live = RunningCloneDetector.runningProfileIDs(profiles: store.profiles, store: store)
        pausedIDs = live.filter { id in
            id != profile.id && store.profile(id: id)?.recipeID == profile.recipeID
        }.sorted { $0.uuidString < $1.uuidString }
        for id in pausedIDs {
            if let other = store.profile(id: id) {
                launcher.quit(profile: other, store: store)
            }
        }
        displayName = recipe.displayName
        urlScheme = recipe.urlSchemes.first ?? "app"
        isSigningIn = true
        profileID = profile.id
        try launcher.launch(profile, store: store, recipe: recipe, status: status)
    }

    public func finish(store: ProfileStore, launcher: ProfileLauncher, detector: InstalledAppDetector) {
        for id in pausedIDs {
            if let other = store.profile(id: id),
               let otherRecipe = RecipeRegistry.recipe(id: other.recipeID) {
                let status = otherRecipe.detect(using: detector)
                try? launcher.launch(other, store: store, recipe: otherRecipe, status: status)
            }
        }
        pausedIDs = []
        isSigningIn = false
        profileID = nil
    }

    public func cancel() {
        pausedIDs = []
        isSigningIn = false
        profileID = nil
    }
}
