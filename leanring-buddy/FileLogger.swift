//
//  FileLogger.swift
//  leanring-buddy
//
//  Mirrors the most important diagnostic prints to ~/Desktop/ipop-ai.log
//  so we can `tail -f` from a Terminal window and see exactly what the
//  app is doing in real time, without needing to wrestle Xcode's
//  cramped debug console.
//
//  Anything passed to FileLogger.log() ALSO prints to stdout, so Xcode
//  console output is unchanged. The file write is async on a serial
//  queue so logging never blocks the main thread.
//

import Foundation

enum FileLogger {
    private static let logFileURL: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        return desktop.appendingPathComponent("ipop-ai.log")
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let writeQueue = DispatchQueue(label: "ai.ipop.filelogger")

    /// Lazily ensures the log file exists. Called once on first log call.
    private static let bootstrap: Void = {
        let separator = "\n========================================\n"
            + "==== SESSION START \(ISO8601DateFormatter().string(from: Date())) ====\n"
            + "========================================\n"
        appendStringToLogFile(separator)
        return ()
    }()

    /// Logs a message to both stdout (Xcode console) and ~/Desktop/ipop-ai.log.
    static func log(_ message: String) {
        // Always print so Xcode console is unaffected for users who can read it.
        print(message)

        // Async write to file so this never blocks the caller.
        _ = bootstrap
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        writeQueue.async {
            appendStringToLogFile(line)
        }
    }

    private static func appendStringToLogFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let url = logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }
        // Create file (or overwrite if FileHandle failed for some reason).
        try? data.write(to: url, options: .atomic)
    }
}
