import Darwin
import Foundation

/// WRITES THE MINUTE LINE (HostLoadHistory.swift has the format), from the sample the host watch
/// already takes. App only; it adds no timer and no subprocess.
///
/// `open(O_APPEND)` AND ONE `write(2)`, NOT `FileHandle.seekToEnd` THEN `write`: two builds can be
/// running at once and the seek-then-write pair lets one overwrite the other's line. A line is
/// about 85 bytes, far under `PIPE_BUF`, and an `O_APPEND` write of that size is not interleaved.
/// The reader drops the second line of a minute, so the writers need no coordination.
///
/// EVERY FAILURE IS SWALLOWED: no folder, a full disk, a refused open. The next minute tries again,
/// and the alarm and the report publish that share this task are never held up by it.
enum HostLoadHistoryWriter {
    /// Days kept besides today: eight files, about 1 MB.
    static let keepDays = 7
    /// A day is about 120 KB; past this the file stops growing (a runaway or many writers).
    static let fileByteLimit: off_t = 512 * 1024

    static func append(_ sample: HostLoadSample,
                       in directory: URL = hostLoadDirectory(unshipped: BuildVariant.isUnshipped),
                       timeZone: TimeZone = .current) {
        let file = directory.appendingPathComponent(hostLoadFileName(for: sample.at, timeZone: timeZone))
        if !FileManager.default.fileExists(atPath: file.path) {
            // Today's first line: make the folder and drop the days that have aged out.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            prune(directory, today: sample.at, timeZone: timeZone)
        }
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size < fileByteLimit else { return }
        let bytes = Array(hostLoadLine(sample, timeZone: timeZone).utf8)
        _ = write(descriptor, bytes, bytes.count)
    }

    /// Delete day files older than `keepDays` calendar days. Only names that match the day-file
    /// pattern are touched; ISO dates sort as strings, so the cutoff is a name comparison.
    static func prune(_ directory: URL, today: Date, timeZone: TimeZone) {
        let calendar = hostLoadCalendar(timeZone: timeZone)
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: today),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let oldest = hostLoadFileName(for: cutoff, timeZone: timeZone)
        for name in names where isHostLoadFileName(name) && name < oldest {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
