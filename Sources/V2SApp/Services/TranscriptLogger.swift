import Foundation

/// Persists the live transcript (source + translation) to disk while a session runs,
/// so the whole conversation is saved as it happens instead of living only in memory.
///
/// Each session writes a folder under `~/Documents/v2s Transcripts/<timestamp>/` with:
///   - `transcript.md`   human-readable, Obsidian-friendly (frontmatter + timestamped lines)
///   - `transcript.srt`  subtitle file (can feed batch correction / re-transcription tools)
///   - `session.jsonl`   one JSON object per line (machine-readable)
///
/// The logger keeps its own append-only model keyed by entry id. New ids are appended,
/// existing ids are updated in place (handles late translations / revisions), and entries
/// are never removed — so clearing the in-memory transcript does not erase the saved file.
@MainActor
final class TranscriptLogger {
    private struct LogEntry {
        let id: UUID
        var source: String
        var translation: String
        let startMs: Int
        var endMs: Int
    }

    private struct JSONLine: Encodable {
        let i: Int
        let start_ms: Int
        let end_ms: Int
        let source: String
        let translation: String
        let src_lang: String
        let tgt_lang: String
    }

    private static let writeDebounce: TimeInterval = 0.4

    private let ioQueue = DispatchQueue(label: "com.franklioxygen.v2s.transcript-logger", qos: .utility)

    private var sessionDirectory: URL?
    private var startDate: Date?
    private var sourceLanguageID = ""
    private var targetLanguageID = ""
    private var order: [UUID] = []
    private var entriesByID: [UUID: LogEntry] = [:]
    private var writeTask: Task<Void, Never>?

    /// The folder for the active session, if any (exposed so the UI can reveal it in Finder).
    private(set) var currentSessionDirectory: URL?

    // MARK: - Lifecycle

    func startSession(sourceLanguageID: String, targetLanguageID: String, startedAt: Date = Date()) {
        // Flush and close any session that was still open.
        finishSession()

        self.startDate = startedAt
        self.sourceLanguageID = sourceLanguageID
        self.targetLanguageID = targetLanguageID
        self.order = []
        self.entriesByID = [:]

        guard let directory = Self.makeSessionDirectory(startedAt: startedAt) else {
            sessionDirectory = nil
            currentSessionDirectory = nil
            return
        }

        sessionDirectory = directory
        currentSessionDirectory = directory

        // Seed the markdown file immediately so the folder exists and is discoverable.
        let header = Self.renderMarkdown(
            [],
            startedAt: startedAt,
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID
        )
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? header.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
    }

    /// Merge the current transcript entries into the saved model and schedule a write.
    /// `entries` is the full in-memory transcript; the logger reconciles by id.
    func record(entries: [TranscriptEntry], at now: Date = Date()) {
        guard let startDate, sessionDirectory != nil else { return }
        let elapsedMs = max(0, Int(now.timeIntervalSince(startDate) * 1000))

        var changed = false
        for entry in entries {
            let source = entry.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = entry.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty && translation.isEmpty { continue }

            if var existing = entriesByID[entry.id] {
                if existing.source != source || existing.translation != translation {
                    existing.source = source
                    existing.translation = translation
                    existing.endMs = max(existing.endMs, elapsedMs)
                    entriesByID[entry.id] = existing
                    changed = true
                }
            } else {
                entriesByID[entry.id] = LogEntry(
                    id: entry.id,
                    source: source,
                    translation: translation,
                    startMs: elapsedMs,
                    endMs: elapsedMs
                )
                order.append(entry.id)
                changed = true
            }
        }

        if changed {
            scheduleWrite()
        }
    }

    /// Flush a final copy and close the session.
    func finishSession() {
        writeTask?.cancel()
        writeTask = nil
        guard sessionDirectory != nil else { return }
        flush(synchronous: true)
        sessionDirectory = nil
        startDate = nil
        order = []
        entriesByID = [:]
    }

    // MARK: - Writing

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.writeDebounce * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.flush(synchronous: false)
        }
    }

    private func flush(synchronous: Bool) {
        guard let directory = sessionDirectory, let startDate else { return }

        // Snapshot + render on the main actor (cheap string building), then hand pure
        // value types to the I/O queue so file writing never touches actor state.
        let ordered = order.compactMap { entriesByID[$0] }
        let markdown = Self.renderMarkdown(
            ordered,
            startedAt: startDate,
            sourceLanguageID: sourceLanguageID,
            targetLanguageID: targetLanguageID
        )
        let srt = Self.renderSRT(ordered)
        let jsonl = Self.renderJSONL(ordered, sourceLanguageID: sourceLanguageID, targetLanguageID: targetLanguageID)

        let write: @Sendable () -> Void = {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? markdown.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try? srt.write(to: directory.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            try? jsonl.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        }

        if synchronous {
            ioQueue.sync(execute: write)
        } else {
            ioQueue.async(execute: write)
        }
    }

    // MARK: - Paths

    private static func makeSessionDirectory(startedAt: Date) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let root = documents.appendingPathComponent("v2s Transcripts", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folderName = formatter.string(from: startedAt)
        return root.appendingPathComponent(folderName, isDirectory: true)
    }

    // MARK: - Rendering

    private static func renderMarkdown(
        _ entries: [LogEntry],
        startedAt: Date,
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("---")
        lines.append("type: transcript")
        lines.append("source: v2s-live")
        lines.append("date: \(formatter.string(from: startedAt))")
        lines.append("input_language: \(sourceLanguageID)")
        lines.append("output_language: \(targetLanguageID)")
        lines.append("entries: \(entries.count)")
        lines.append("---")
        lines.append("")
        lines.append("# v2s 逐字稿 \(sourceLanguageID) → \(targetLanguageID)")
        lines.append("")

        if entries.isEmpty {
            lines.append("_(尚無內容 / no content yet)_")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for entry in entries {
            let time = clockTimestamp(entry.startMs)
            if entry.source.isEmpty == false {
                lines.append("- **[\(time)]** \(entry.source)")
            } else {
                lines.append("- **[\(time)]**")
            }
            if entry.translation.isEmpty == false {
                lines.append("  - \(entry.translation)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func renderSRT(_ entries: [LogEntry]) -> String {
        guard entries.isEmpty == false else { return "" }

        var blocks: [String] = []
        for (index, entry) in entries.enumerated() {
            let start = entry.startMs
            var end = max(entry.endMs, start + 1200)
            if index + 1 < entries.count {
                let nextStart = entries[index + 1].startMs
                if nextStart > start + 200 {
                    end = min(end, nextStart - 50)
                }
            }
            if end <= start {
                end = start + 800
            }

            var textLines: [String] = []
            if entry.source.isEmpty == false { textLines.append(entry.source) }
            if entry.translation.isEmpty == false { textLines.append(entry.translation) }
            if textLines.isEmpty { continue }

            blocks.append("""
            \(index + 1)
            \(srtTimestamp(start)) --> \(srtTimestamp(end))
            \(textLines.joined(separator: "\n"))
            """)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func renderJSONL(
        _ entries: [LogEntry],
        sourceLanguageID: String,
        targetLanguageID: String
    ) -> String {
        guard entries.isEmpty == false else { return "" }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines: [String] = []
        for (index, entry) in entries.enumerated() {
            let line = JSONLine(
                i: index + 1,
                start_ms: entry.startMs,
                end_ms: max(entry.endMs, entry.startMs),
                source: entry.source,
                translation: entry.translation,
                src_lang: sourceLanguageID,
                tgt_lang: targetLanguageID
            )
            if let data = try? encoder.encode(line), let string = String(data: data, encoding: .utf8) {
                lines.append(string)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func srtTimestamp(_ milliseconds: Int) -> String {
        let ms = max(0, milliseconds)
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    private static func clockTimestamp(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
