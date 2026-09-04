import Foundation

final class AppLogStore {
    let logFileURL: URL
    private let fileManager: FileManager
    private let maxFileSizeBytes: UInt64
    private let maxArchives: Int
    private let retentionDays: Int
    private let checkInterval: TimeInterval
    private let checkAfterBytes: UInt64
    private let calendar: Calendar
    private var lastRotationCheckAt: Date = .distantPast
    private var bytesWrittenSinceLastCheck: UInt64 = 0

    private static let formatterLock = NSLock()
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(
        logFileURL: URL,
        fileManager: FileManager = .default,
        maxFileSizeBytes: UInt64 = 10 * 1024 * 1024,
        maxArchives: Int = 5,
        retentionDays: Int = 7,
        checkInterval: TimeInterval = 30,
        checkAfterBytes: UInt64 = 64 * 1024,
        calendar: Calendar = .current)
    {
        self.logFileURL = logFileURL
        self.fileManager = fileManager
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxArchives = max(1, maxArchives)
        self.retentionDays = max(1, retentionDays)
        self.checkInterval = max(1, checkInterval)
        self.checkAfterBytes = max(4 * 1024, checkAfterBytes)
        self.calendar = calendar
    }

    func ensureLogFileExists() {
        let createdLogFile: Bool
        if !self.fileManager.fileExists(atPath: self.logFileURL.path) {
            self.fileManager.createFile(atPath: self.logFileURL.path, contents: nil)
            createdLogFile = true
        } else {
            createdLogFile = false
        }

        if createdLogFile {
            self.bytesWrittenSinceLastCheck = 0
            self.lastRotationCheckAt = Date()
        } else if self.shouldRotateForDateBoundary() || (
            self.currentLogFileSize().map { $0 > self.maxFileSizeBytes } ?? false
        ) {
            self.rotateArchives()
        }

        self.cleanupArchivesIfNeeded(force: false)
    }

    func append(entries: [AppErrorLogEntry]) {
        self.append(records: entries.map {
            (timestamp: $0.timestamp, level: $0.level, message: $0.message)
        })
    }

    private func append(records: [(timestamp: Date, level: String, message: String)]) {
        guard !records.isEmpty else { return }
        self.ensureLogFileExists()
        let content = records.map {
            "[\(Self.timestampString(from: $0.timestamp))] [\($0.level.uppercased())] \($0.message)\n"
        }.joined()

        guard let data = content.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: logFileURL.path)
        else {
            return
        }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(data)
        self.bytesWrittenSinceLastCheck += UInt64(data.count)
        self.rotateIfNeededAfterAppend()
    }

    func clear() {
        self.bytesWrittenSinceLastCheck = 0
        self.lastRotationCheckAt = .distantPast

        if self.fileManager.fileExists(atPath: self.logFileURL.path) {
            try? Data().write(to: self.logFileURL, options: .atomic)
        } else {
            self.ensureLogFileExists()
        }

        for archiveURL in self.archivedLogURLs() {
            try? self.fileManager.removeItem(at: archiveURL)
        }
    }

    private static func timestampString(from date: Date) -> String {
        self.formatterLock.lock()
        defer { formatterLock.unlock() }
        return self.timestampFormatter.string(from: date)
    }

    private func rotateIfNeededAfterAppend() {
        let now = Date()
        let shouldCheckByTime = now.timeIntervalSince(self.lastRotationCheckAt) >= self.checkInterval
        let shouldCheckByBytes = self.bytesWrittenSinceLastCheck >= self.checkAfterBytes
        guard shouldCheckByTime || shouldCheckByBytes else { return }

        self.lastRotationCheckAt = now
        self.bytesWrittenSinceLastCheck = 0

        guard let currentFileSize = self.currentLogFileSize() else {
            self.cleanupArchivesIfNeeded(force: false)
            return
        }

        if self.shouldRotateForDateBoundary() || currentFileSize > self.maxFileSizeBytes {
            self.rotateArchives()
        }

        self.cleanupArchivesIfNeeded(force: false)
    }

    private func rotateArchives() {
        for index in stride(from: self.maxArchives, through: 1, by: -1) {
            let sourceURL = index == 1 ? self.logFileURL : self.archiveURL(index: index - 1)
            let destinationURL = self.archiveURL(index: index)

            guard self.fileManager.fileExists(atPath: sourceURL.path) else { continue }

            if self.fileManager.fileExists(atPath: destinationURL.path) {
                try? self.fileManager.removeItem(at: destinationURL)
            }

            try? self.fileManager.moveItem(at: sourceURL, to: destinationURL)
        }

        self.fileManager.createFile(atPath: self.logFileURL.path, contents: nil)
    }

    private func cleanupArchivesIfNeeded(force: Bool) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.retentionDays, to: Date()) ?? .distantPast
        let archivedURLs = self.archivedLogURLs()

        if archivedURLs.count > self.maxArchives {
            for url in archivedURLs.dropFirst(self.maxArchives) {
                try? self.fileManager.removeItem(at: url)
            }
        }

        for archiveURL in archivedURLs.prefix(self.maxArchives) {
            guard let values = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate
            else {
                continue
            }

            if modifiedAt < cutoffDate {
                try? self.fileManager.removeItem(at: archiveURL)
            }
        }

        if force {
            self.bytesWrittenSinceLastCheck = 0
            self.lastRotationCheckAt = Date()
        }
    }

    private func archivedLogURLs() -> [URL] {
        let directoryURL = self.logFileURL.deletingLastPathComponent().standardizedFileURL
        guard let entries = try? self.fileManager.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles])
        else {
            return []
        }

        let fileName = self.logFileURL.lastPathComponent
        let prefix = "\(fileName)."

        let archives: [(Int, URL)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            let suffix = String(name.dropFirst(prefix.count))
            guard let index = Int(suffix), index > 0 else { return nil }
            return (index, url)
        }

        return archives
            .sorted { lhs, rhs in lhs.0 < rhs.0 }
            .map { $0.1 }
    }

    private func archiveURL(index: Int) -> URL {
        self.logFileURL.appendingPathExtension(String(index))
    }

    private func currentLogFileSize() -> UInt64? {
        guard let attributes = try? self.fileManager.attributesOfItem(atPath: self.logFileURL.path),
              let fileSize = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return fileSize.uint64Value
    }

    private func shouldRotateForDateBoundary() -> Bool {
        guard let attributes = try? self.fileManager.attributesOfItem(atPath: self.logFileURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return false
        }

        return !self.calendar.isDate(modifiedAt, inSameDayAs: Date())
    }
}
