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
    /// Every column except the Start/Stop times, in CSV order: used to find the folders.
    let values: [String]

    /// Rows with the same values share a folder.
    var folderKey: String { values.map(AppSettings.key).joined(separator: "|") }
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
            let values = header.indices.filter { !header[$0].hasPrefix("start") && !header[$0].hasPrefix("stop") }
                .map { get($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            out.append(AwardRow(speaker: get(iSpeaker), award: get(iAward), winner: get(iWinner),
                                date: date, start: start, stop: max(stop, start), values: values))
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
    struct Result {
        var byRow: [UUID: [Clip]] = [:]
        var unused: [Clip] = []
        var error: [URL: Double] = [:]   // seconds between a clip's start and its row's Start (after clock fix)
        var clockOffset: Double = 0      // camera clock minus phone clock, in seconds
    }

    /// The Tracker starts/stops the camera over Bluetooth, so each row's Start Time is when its clip started.
    /// 1. Works out how far the camera clock is from the phone clock (the typical gap between
    ///    each row's Start and the nearest clip start).
    /// 2. Pairs each row with ONE clip: the closest start (stop as a tie-breaker), within `tolerance`
    ///    seconds after the clock fix. Closest pairs are made first; each clip is used once.
    static func match(_ clips: [Clip], rows: [AwardRow], tolerance: TimeInterval) -> Result {
        var r = Result()
        guard !clips.isEmpty, !rows.isEmpty else { r.unused = clips; return r }

        // 1. Clock offset: median of nearest-start gaps that are within 10 minutes.
        var gaps: [Double] = []
        for row in rows {
            if let d = clips.map({ $0.start.timeIntervalSince(row.start) }).min(by: { abs($0) < abs($1) }), abs(d) <= 600 {
                gaps.append(d)
            }
        }
        if !gaps.isEmpty {
            let g = gaps.sorted()
            r.clockOffset = g.count % 2 == 1 ? g[g.count / 2] : (g[g.count / 2 - 1] + g[g.count / 2]) / 2
        }

        // 2. All candidate pairs within tolerance, closest first.
        var pairs: [(row: AwardRow, clip: Clip, startErr: Double, score: Double)] = []
        for row in rows {
            for c in clips {
                let startErr = c.start.timeIntervalSince(row.start) - r.clockOffset
                guard abs(startErr) <= tolerance else { continue }
                let stopErr = abs(c.end.timeIntervalSince(row.stop) - r.clockOffset)
                pairs.append((row, c, startErr, abs(startErr) + 0.25 * stopErr))
            }
        }
        pairs.sort { $0.score < $1.score }
        var usedRows = Set<UUID>(), usedClips = Set<URL>()
        for p in pairs where !usedRows.contains(p.row.id) && !usedClips.contains(p.clip.file.url) {
            usedRows.insert(p.row.id)
            usedClips.insert(p.clip.file.url)
            r.byRow[p.row.id] = [p.clip]
            r.error[p.clip.file.url] = p.startErr
        }
        r.unused = clips.filter { !usedClips.contains($0.file.url) }
        return r
    }
}

// MARK: - Finding each clip's folder

enum AwardFolders {
    /// Starts at the main folder. At each level, looks for a folder named like any of the row's
    /// CSV values not used yet (Speaker, Award Name, Winner, ... in any order), goes into it, and repeats
    /// until no folder matches. The clip goes in the deepest folder reached.
    /// Exact names win over partial ones. Returns nil if not even the first level matched.
    static func resolve(values: [String], main: String) -> (path: String?, matched: [String], missing: String) {
        let d = Folders.descend(values, from: main)
        if d.matched.isEmpty {
            return (nil, [], "No folder in \(main) is named like any of: \(values.joined(separator: ", "))")
        }
        return (d.path, d.matched, "")
    }
}
