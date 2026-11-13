import Foundation
import CryptoKit

// MARK: - Flight Log CSV

/// One row of a Lot Shots Flight Log: time spent at one place.
struct Session: Hashable {
    let date: String        // "2026-11-12" (from the CSV)
    let type: String        // Community / Location
    let place: String
    let start: Date
    let stop: Date?
}

enum FlightLog {
    /// Splits one CSV line, respecting "quoted, fields".
    static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 } else { inQuotes = false }
                } else { cur.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { out.append(cur); cur = "" }
                else { cur.append(c) }
            }
            i += 1
        }
        out.append(cur)
        chars.removeAll()
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parseDate(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func load(_ url: URL) throws -> [Session] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return [] }
        let header = fields(lines.removeFirst()).map { $0.lowercased() }
        func col(_ name: String) -> Int? { header.firstIndex { $0.hasPrefix(name) } }
        guard let iDate = col("date"), let iPlace = col("place"), let iStart = col("start") else {
            throw NSError(domain: "LotShots", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't a Lot Shots Flight Log CSV"])
        }
        let iType = col("type"), iStop = col("stop")
        var out: [Session] = []
        for line in lines {
            let f = fields(line)
            func get(_ i: Int?) -> String { guard let i = i, i < f.count else { return "" }; return f[i] }
            guard let start = parseDate(get(iStart)) else { continue }
            out.append(Session(date: get(iDate), type: get(iType), place: get(iPlace), start: start, stop: parseDate(get(iStop))))
        }
        return out
    }
}

// MARK: - Drone files

struct MediaFile: Hashable {
    let url: URL
    let time: Date
    let isVideo: Bool
    let size: Int64
    var name: String { url.lastPathComponent }
}

enum Assignment: Hashable {
    case place(String, String)  // (place name from the CSV, CSV date "yyyy-MM-dd")
    case unsorted
    case otherDay               // shot on a day that isn't in any loaded CSV: left alone
}

enum Sorter {
    static let photoExt: Set<String> = ["jpg", "jpeg", "dng"]
    static let videoExt: Set<String> = ["mp4", "mov"]

    private static let djiName = try! NSRegularExpression(pattern: "(\\d{14})")

    /// When the file was shot: from DJI's file name (DJI_20261112141530_...), else the file's own date.
    static func shotTime(_ url: URL, _ v: URLResourceValues) -> Date {
        let n = url.lastPathComponent
        if let m = djiName.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
           let r = Range(m.range(at: 1), in: n) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyyMMddHHmmss"
            if let d = f.date(from: String(n[r])) { return d }
        }
        return v.creationDate ?? v.contentModificationDate ?? Date.distantPast
    }

    /// Every JPG / DNG / MP4 / MOV under the drone folder. Skips the PANORAMA folder (360 frames).
    static func scan(_ root: URL) -> [MediaFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [MediaFile] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if url.lastPathComponent.uppercased().contains("PANORAMA") { e.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            let isPhoto = photoExt.contains(ext), isVideo = videoExt.contains(ext)
            guard isPhoto || isVideo, !url.lastPathComponent.hasPrefix("._") else { continue }
            out.append(MediaFile(url: url, time: shotTime(url, v), isVideo: isVideo, size: Int64(v.fileSize ?? 0)))
        }
        return out.sorted { $0.time < $1.time }
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "2026-11-12" -> "11.12.26"
    static func folderName(_ csvDate: String) -> String {
        let p = csvDate.split(separator: "-")
        guard p.count == 3, p[0].count == 4 else { return csvDate }
        return "\(p[1]).\(p[2]).\(p[0].suffix(2))"
    }

    /// Matches each file to the place whose time window it falls in (with the buffer on both sides).
    /// A timer that was never stopped runs until the next place's start, or the end of that day.
    static func assign(_ files: [MediaFile], sessions: [Session], bufferMinutes: Int) -> [(MediaFile, Assignment)] {
        let sorted = sessions.sorted { $0.start < $1.start }
        var windows: [(s: Session, from: Date, to: Date)] = []
        for (i, s) in sorted.enumerated() {
            var end = s.stop
            if end == nil {
                end = sorted[(i + 1)...].first(where: { $0.start > s.start })?.start
            }
            if end == nil {
                end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: s.start)
            }
            windows.append((s, s.start, max(end ?? s.start, s.start)))
        }
        let buffer = TimeInterval(bufferMinutes * 60)
        let days = Set(sessions.map { $0.date })

        return files.map { f in
            let hits = windows.filter { f.time >= $0.from.addingTimeInterval(-buffer) && f.time <= $0.to.addingTimeInterval(buffer) }
            if hits.isEmpty {
                return (f, days.contains(dayString(f.time)) ? .unsorted : .otherDay)
            }
            // Prefer the window it's actually inside; otherwise the closest one.
            let best = hits.min { a, b in distance(f.time, a.from, a.to) < distance(f.time, b.from, b.to) }!
            return (f, .place(best.s.place, best.s.date))
        }
    }

    private static func distance(_ t: Date, _ from: Date, _ to: Date) -> TimeInterval {
        if t < from { return from.timeIntervalSince(t) }
        if t > to { return t.timeIntervalSince(to) }
        return 0
    }

    // MARK: - Safe copy

    enum CopyResult { case copied, alreadyThere, failed(String) }

    static func sha256(_ url: URL) throws -> SHA256Digest {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = try h.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    /// Copies (never moves or deletes) into `dir`, checks the copy matches byte-for-byte, then names it.
    /// A file with the same name and size already there is skipped, so running twice won't duplicate.
    static func copyVerified(_ f: MediaFile, to dir: URL) -> CopyResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(f.name)
            if fm.fileExists(atPath: dest.path) {
                let existing = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
                if existing == f.size { return .alreadyThere }
                let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
                var n = 2
                repeat {
                    dest = dir.appendingPathComponent("\(base)_\(n).\(ext)")
                    n += 1
                } while fm.fileExists(atPath: dest.path)
            }
            let tmp = dir.appendingPathComponent(".copying-\(dest.lastPathComponent)")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: f.url, to: tmp)
            let copiedSize = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? -1
            guard copiedSize == f.size, try sha256(f.url) == sha256(tmp) else {
                try? fm.removeItem(at: tmp)
                return .failed("copy didn't match the original")
            }
            try fm.moveItem(at: tmp, to: dest)
            return .copied
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
