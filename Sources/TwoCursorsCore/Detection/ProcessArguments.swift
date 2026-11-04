import Darwin
import Foundation

public enum ProcessArguments {
    /// argv plus the environment that follows it in the `KERN_PROCARGS2` buffer.
    public struct Snapshot: Equatable, Sendable {
        public var arguments: [String]
        public var environment: [String: String]

        public init(arguments: [String], environment: [String: String]) {
            self.arguments = arguments
            self.environment = environment
        }
    }

    /// Reads argv for `pid` via KERN_PROCARGS2. Returns [] if the process is gone or inaccessible.
    public static func arguments(for pid: Int32) -> [String] {
        snapshot(for: pid).arguments
    }

    /// Environment of `pid`. Grok Bot clones do not put the profile on argv; it is `SAND_USER_DATA_DIR`.
    public static func environment(for pid: Int32) -> [String: String] {
        snapshot(for: pid).environment
    }

    /// Reads argv and environment for `pid`. Returns empty fields if the process is gone.
    public static func snapshot(for pid: Int32) -> Snapshot {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        var result = sysctl(&mib, u_int(mib.count), nil, &size, nil, 0)
        guard result == 0, size > 4 else { return Snapshot(arguments: [], environment: [:]) }

        var buffer = [UInt8](repeating: 0, count: size)
        result = buffer.withUnsafeMutableBufferPointer { ptr in
            sysctl(&mib, u_int(mib.count), ptr.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 4 else { return Snapshot(arguments: [], environment: [:]) }

        let argc = buffer.prefix(4).withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return Snapshot(arguments: [], environment: [:]) }

        var index = 4
        while index < buffer.count, buffer[index] != 0 {
            index += 1
        }
        while index < buffer.count, buffer[index] == 0 {
            index += 1
        }

        var strings: [String] = []
        var current: [UInt8] = []
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0 {
                if !current.isEmpty {
                    strings.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
            index += 1
        }
        if !current.isEmpty {
            strings.append(String(decoding: current, as: UTF8.self))
        }

        let argCount = min(Int(argc), strings.count)
        let arguments = Array(strings.prefix(argCount))
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(argCount) {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: separator)...])
        }
        return Snapshot(arguments: arguments, environment: environment)
    }

    /// Profile directory a clone is using: Chromium's `--user-data-dir`, or Grok Bot's
    /// `SAND_USER_DATA_DIR` when that flag is absent.
    public static func isolatedUserDataDir(in snapshot: Snapshot) -> String? {
        if let dir = userDataDir(from: snapshot.arguments) {
            return dir
        }
        if let dir = snapshot.environment[CloneLaunchEnvironment.grokUserDataEnvironmentKey], !dir.isEmpty {
            return dir
        }
        return nil
    }

    public static func userDataDir(from arguments: [String]) -> String? {
        value(named: "--user-data-dir", in: arguments)
    }

    public static func value(named flag: String, in arguments: [String]) -> String? {
        for (index, arg) in arguments.enumerated() {
            if arg == flag, index + 1 < arguments.count {
                return arguments[index + 1]
            }
            let prefix = flag + "="
            if arg.hasPrefix(prefix) {
                return String(arg.dropFirst(prefix.count))
            }
        }
        return nil
    }
}
