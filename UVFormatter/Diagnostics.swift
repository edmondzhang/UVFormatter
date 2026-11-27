import AppKit
import Foundation

@MainActor
final class DiagnosticsStore {
    static let shared = DiagnosticsStore()

    private static let enabledKey = "diagnosticsEnabled"
    private static let fileName = "diagnostics.jsonl"
    private static let maximumSourceBytes = 4 * 1024 * 1024

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let maximumBytes: Int
    let directoryURL: URL
    private(set) var storageError: String?

    init(
        directoryURL: URL? = nil,
        defaults: UserDefaults = .standard,
        maximumBytes: Int = 100 * 1024 * 1024,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.maximumBytes = maximumBytes
        self.directoryURL = directoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UVFormatter", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
    }

    var logFileURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    /// Changes whether future parser events are written to the local diagnostics file.
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// Records JSONC/JSON5 success and parser failures for local parser improvement.
    /// Original input is Base64-encoded, limited to the formatter's selection cap, and never uploaded.
    func record(source: String, targetBundleID: String?, formatted: FormattedSelection? = nil, error: Error? = nil) {
        guard isEnabled else { return }
        let dialect = formatted?.dialect ?? (error as? FormatterIssue)?.dialect
        guard error != nil || dialect == .jsonc || dialect == .json5 else { return }

        let sourceData = Data(source.utf8)
        let issue = error as? FormatterIssue
        var record = Record(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            kind: error == nil ? "parsed" : "parse-error",
            dialect: dialect?.rawValue,
            targetBundleID: targetBundleID,
            originalByteCount: sourceData.count,
            originalBase64: sourceData.count <= Self.maximumSourceBytes ? sourceData.base64EncodedString() : nil,
            line: issue?.line,
            column: issue?.column,
            reason: issue?.reason ?? error?.localizedDescription,
            candidates: issue?.candidates ?? []
        )
        guard let encoded = encode(record) else { return }
        if encoded.count > maximumBytes {
            record.originalBase64 = nil
        }
        guard let data = encode(record), data.count <= maximumBytes else { return }
        append(data)
    }

    /// Removes the current local JSONL file after the user chooses Clear in Settings.
    func clear() throws {
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            storageError = nil
            return
        }
        do {
            try fileManager.removeItem(at: logFileURL)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            throw error
        }
    }

    /// Opens the local diagnostics folder from Settings without sending its contents elsewhere.
    func openDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        guard NSWorkspace.shared.open(directoryURL) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directoryURL.path])
        }
    }

    private func encode(_ record: Record) -> Data? {
        guard var data = try? JSONEncoder().encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Appends one bounded JSONL record and removes the oldest complete records when the cap is exceeded.
    /// The file and containing directory are restricted to the current macOS user.
    private func append(_ record: Data) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            if !fileManager.fileExists(atPath: logFileURL.path) {
                guard fileManager.createFile(atPath: logFileURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logFileURL.path])
                }
            }
            guard record.count <= maximumBytes else { return }
            let currentSize = (try fileManager.attributesOfItem(atPath: logFileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if currentSize <= maximumBytes, record.count <= maximumBytes - currentSize {
                let handle = try FileHandle(forWritingTo: logFileURL)
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: record)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                storageError = nil
                return
            }
            let existing = try Data(contentsOf: logFileURL, options: .mappedIfSafe)
            var combined = existing
            combined.append(record)
            if combined.count > maximumBytes {
                let excess = combined.count - maximumBytes
                if excess < combined.count,
                   let newline = combined.range(of: Data([0x0A]), in: excess..<combined.count) {
                    combined.removeSubrange(..<newline.upperBound)
                } else {
                    combined = record
                }
            }
            try combined.write(to: logFileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
        } catch {
            storageError = error.localizedDescription
        }
    }
}

private struct Record: Encodable {
    let timestamp: String
    let kind: String
    let dialect: String?
    let targetBundleID: String?
    let originalByteCount: Int
    var originalBase64: String?
    let line: Int?
    let column: Int?
    let reason: String?
    let candidates: [String]
}
