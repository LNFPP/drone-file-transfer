import Foundation

// MARK: - Christmas Awards Tracker CSV

/// One row: one person talking about one award, with when the clip started and stopped.
struct AwardRow: Identifiable, Hashable {
    let id = UUID()
    let speaker: String
    let award: String
    let winner: String
    let date: String       // "2026-11-18"
    let start: Date
    let stop: Date

    /// Rows for the same award + winner share a folder.
    var folderKey: String { AppSettings.key(award) + "|" + AppSettings.key(winner) }
}

enum AwardsLog {
    static func load(_ url: URL) throws -> [AwardRow] {
        var lines = try CSVFile.lines(url)
        guard !lines.isEmpty else { return [] }
        let header = FlightLog.fields(lines.removeFirst()).map { $0.lowercased() }
        func col(_ name: String) -> Int? { header.firstIndex { $0.hasPrefix(name) } }
        guard let iAward = col("award"), let iStart = col("start") else {
            throw NSError(domain: "LotShots", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't a Christmas Awards CSV"])
        }
        let iSpeaker = col("speaker"), iWinner = col("winner"), iDate = col("date"), iStop = col("stop")
        var out: [AwardRow] = []
        for line in lines {
            let f = FlightLog.fields(line)
            func get(_ i: Int?) -> String { guard let i = i, i < f.count else { return "" }; return f[i] }
            guard let start = FlightLog.parseDate(get(iStart)) else { continue }
            let stop = FlightLog.parseDate(get(iStop)) ?? start
            var date = get(iDate)
            if date.isEmpty { date = String(get(iStart).prefix(10)) }
            out.append(AwardRow(speaker: get(iSpeaker), award: get(iAward), winner: get(iWinner),
                                date: date, start: start, stop: max(stop, start)))
        }
        return out
    }
}

// MARK: - Camera clips (Sony FX3 and other MP4 / MOV)

struct Clip: Hashable {
    let file: MediaFile
    let start: Date
    let end: Date
}

enum ClipReader {
    static let videoExt: Set<String> = ["mp4", "mov"]

    /// Every MP4 / MOV under `root` with its recording start and length.
    static func scan(_ root: URL) -> [Clip] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [Clip] = []
        for case let url as URL in e {
            guard videoExt.contains(url.pathExtension.lowercased()), !url.lastPathComponent.hasPrefix("._"),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            let info = read(url)
            let start = info.start ?? v.creationDate ?? v.contentModificationDate ?? .distantPast
            let mf = MediaFile(url: url, time: start, isVideo: true, size: Int64(v.fileSize ?? 0),
                               created: v.creationDate, isJPEG: false, looksLike360: false)
            out.append(Clip(file: mf, start: start, end: start.addingTimeInterval(info.duration ?? 0)))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Recording start and length from the file itself.
    /// Start: Sony's metadata (CreationDate value="2026-11-18T16:46:50-05:00"), else the movie header's creation time.
    /// Length: the movie header (mvhd).
    static func read(_ url: URL) -> (start: Date?, duration: Double?) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0

        var start: Date?
        var duration: Double?
        var offset: UInt64 = 0
        // Walk the top-level boxes: ftyp, uuid, mdat, moov, meta ...
        while offset + 8 <= size {
            guard (try? h.seek(toOffset: offset)) != nil, let head = try? h.read(upToCount: 16), head.count >= 8 else { break }
            var boxSize = UInt64(be32(head, 0))
            let type = String(bytes: head[4..<8], encoding: .ascii) ?? ""
            var headerLen: UInt64 = 8
            if boxSize == 1, head.count >= 16 { boxSize = be64(head, 8); headerLen = 16 }
            if boxSize == 0 { boxSize = size - offset }
            if boxSize < headerLen { break }

            if (type == "moov" || type == "meta" || type == "uuid" || type == "udta") && boxSize < 64 * 1024 * 1024 {
                try? h.seek(toOffset: offset)
                if let data = try? h.read(upToCount: Int(boxSize)) {
                    if start == nil { start = sonyCreationDate(data) }
                    if type == "moov", let m = mvhd(data) {
                        duration = m.duration
                        if start == nil { start = m.created }
                    }
                }
            }
            offset += boxSize
        }
        return (start, duration)
    }

    private static func sonyCreationDate(_ data: Data) -> Date? {
        guard let r = data.range(of: Data("CreationDate value=\"".utf8)) else { return nil }
        let rest = data[r.upperBound...]
        guard let q = rest.firstIndex(of: UInt8(ascii: "\"")),
              let s = String(data: rest[rest.startIndex..<q], encoding: .utf8) else { return nil }
        return FlightLog.parseDate(s)
    }

    /// Movie header inside moov: creation time (seconds since 1904, UTC) and duration.
    private static func mvhd(_ moov: Data) -> (created: Date?, duration: Double)? {
        guard let r = moov.range(of: Data("mvhd".utf8)) else { return nil }
        let p = r.upperBound - moov.startIndex
        let b = Data(moov)
        guard p + 32 <= b.count else { return nil }
        let version = b[p]
        let created: UInt64, timescale: UInt32, dur: UInt64
        if version == 1 {
            guard p + 36 <= b.count else { return nil }
            created = be64(b, p + 4); timescale = be32(b, p + 20); dur = be64(b, p + 24)
        } else {
            created = UInt64(be32(b, p + 4)); timescale = be32(b, p + 12); dur = UInt64(be32(b, p + 16))
        }
        guard timescale > 0 else { return nil }
        let date: Date? = created > 0 ? Date(timeIntervalSince1970: Double(created) - 2_082_844_800) : nil
        return (date, Double(dur) / Double(timescale))
    }

    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        let s = d.startIndex + i
        return d[s..<s + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    private static func be64(_ d: Data, _ i: Int) -> UInt64 {
        let s = d.startIndex + i
        return d[s..<s + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

// MARK: - Matching clips to rows

enum AwardsMatcher {
    /// Each clip goes to the row whose Start–Stop time it overlaps the most
    /// (both widened by `tolerance` seconds for small clock differences).
    /// If it overlaps none, it's not copied.
    static func match(_ clips: [Clip], rows: [AwardRow], tolerance: TimeInterval) -> (byRow: [UUID: [Clip]], unused: [Clip]) {
        var byRow: [UUID: [Clip]] = [:]
        var unused: [Clip] = []
        for c in clips {
            var best: (row: AwardRow, overlap: Double, distance: Double)?
            for r in rows {
                let from = r.start.addingTimeInterval(-tolerance), to = r.stop.addingTimeInterval(tolerance)
                let overlap = min(c.end, to).timeIntervalSince(max(c.start, from))
                guard overlap >= 0 else { continue }
                let distance = abs(c.start.timeIntervalSince(r.start))
                if best == nil || overlap > best!.overlap || (overlap == best!.overlap && distance < best!.distance) {
                    best = (r, overlap, distance)
                }
            }
            if let b = best { byRow[b.row.id, default: []].append(c) } else { unused.append(c) }
        }
        return (byRow, unused)
    }
}

// MARK: - Finding each award's folder

enum AwardFolders {
    /// All folders up to 3 levels under the main folder.
    static func list(_ main: String, depth: Int = 3) -> [String] {
        var out: [String] = []
        var level = [main]
        for _ in 0..<depth {
            var next: [String] = []
            for dir in level {
                guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for n in items where !n.hasPrefix(".") {
                    let p = (dir as NSString).appendingPathComponent(n)
                    if Folders.isFolder(p) { next.append(p) }
                }
            }
            out += next
            level = next
        }
        return out
    }

    /// The folder for an award: named like the award (e.g. "Field First" or "Field First - Phil Doppel"),
    /// or failing that, named like the winner. Inside it, a folder named like the speaker is used if there is one.
    /// Returns nil when nothing (or more than one folder) fits, so the app can ask.
    static func find(award: String, winner: String, speaker: String, in folders: [String]) -> String? {
        let a = Folders.simple(award), w = Folders.simple(winner)
        func name(_ p: String) -> String { Folders.simple((p as NSString).lastPathComponent) }
        func pick(_ list: [String]) -> String? {
            guard !list.isEmpty else { return nil }
            if list.count == 1 { return list[0] }
            // Prefer the one that also names the winner, then the shallowest.
            if !w.isEmpty {
                let both = list.filter { name($0).contains(w) }
                if both.count == 1 { return both[0] }
            }
            let depths = list.map { $0.components(separatedBy: "/").count }
            let top = list.enumerated().filter { depths[$0.offset] == depths.min()! }.map { $0.element }
            return top.count == 1 ? top[0] : nil
        }
        var awardFolder: String?
        if !a.isEmpty {
            awardFolder = pick(folders.filter { name($0) == a }) ?? pick(folders.filter { name($0).contains(a) })
        }
        if awardFolder == nil && !w.isEmpty {
            awardFolder = pick(folders.filter { name($0) == w }) ?? pick(folders.filter { name($0).contains(w) })
        }
        guard let base = awardFolder else { return nil }
        return withSpeaker(base, speaker)
    }

    /// Uses a speaker folder inside `base` if one exists.
    static func withSpeaker(_ base: String, _ speaker: String) -> String {
        guard !speaker.isEmpty, let s = Folders.findChild(named: speaker, in: base),
              Folders.simple((s as NSString).lastPathComponent).hasPrefix(Folders.simple(speaker)) else { return base }
        return s
    }
}
