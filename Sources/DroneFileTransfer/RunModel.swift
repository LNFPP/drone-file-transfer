import Foundation
import SwiftUI

struct LoadedCSV: Identifiable {
    let id = UUID()
    let url: URL
    let sessions: [Session]
}

struct Loaded360CSV: Identifiable {
    let id = UUID()
    let url: URL
    let rows: [PanoRow]
}

/// Something that needs a folder before copying can start.
struct PathNeed: Identifiable {
    enum Kind { case community, droneSub, panoSub, location, unsorted, unmatched }
    enum Choice: Hashable { case create, choose, ignore }

    let id = UUID()
    let kind: Kind
    let place: String          // community / location name, or "" for Unsorted / Unmatched
    let title: String
    let detail: String
    let createPath: String?    // folder that Create would make (nil = Create not offered)
    var choice: Choice
    var path = ""
    var saveForNextTime: Bool

    var canIgnore: Bool { kind != .unsorted && kind != .unmatched }
}

/// One file to copy, where to, and under what name.
struct CopyJob {
    let file: MediaFile
    let dir: URL
    let name: String
}

/// One dated destination folder in the preview.
struct PlanGroup: Identifiable {
    enum Kind: Int { case drone = 0, pano = 1, location = 2, unmatched = 3, unsorted = 4 }
    let id = UUID()
    let label: String
    let kind: Kind
    let folder: URL            // .../Drone/11.13.26 or .../360's/11.13.26
    var makeDirs: [URL] = []   // Photos + Videos for drone/location folders
    var jobs: [CopyJob] = []

    var photos: Int { jobs.filter { !$0.file.isVideo }.count }
    var videos: Int { jobs.filter { $0.file.isVideo }.count }
}

struct Report {
    var copied = 0
    var alreadyThere = 0
    var failed: [(String, String)] = []
    var unsorted: [String] = []
    var unmatched360: [String] = []
    var notFound: [(PanoRow, String)] = []
    var otherDays = 0
    var left360 = 0            // 360 JPEGs left alone because no 360s CSV covers their day
}

enum Stage { case idle, scanning, needPaths, preview, copying, done }

final class RunModel: ObservableObject {
    @Published var dronePath = ""
    @Published var csvs: [LoadedCSV] = []
    @Published var panoCSVs: [Loaded360CSV] = []
    @Published var stage: Stage = .idle {
        didSet { CopyState.inProgress = (stage == .scanning || stage == .copying) }
    }
    @Published var status = ""
    @Published var progress = 0.0
    @Published var needs: [PathNeed] = []
    @Published var groups: [PlanGroup] = []
    @Published var report = Report()
    @Published var error: String?

    // Results of the scan
    private var assignments: [(MediaFile, Assignment)] = []
    private var panoMatched: [(row: PanoRow, file: MediaFile, name: String)] = []
    private var panoUnmatched: [MediaFile] = []
    private var panoNotFound: [(PanoRow, String)] = []
    private var left360 = 0

    // Choices made for this run (from the "Choose folders" screen)
    private var communityDir: [String: String] = [:]
    private var subDir: [String: String] = [:]          // "drone|walden" / "pano|walden"
    private var locationDir: [String: String] = [:]
    private var ignoredDrone = Set<String>()
    private var ignored360 = Set<String>()

    private var sessions: [Session] { csvs.flatMap { $0.sessions } }
    private var panoRows: [PanoRow] { panoCSVs.flatMap { $0.rows } }

    // MARK: CSVs

    /// Either drop zone accepts either kind; each CSV goes to the right list by its header.
    func addCSVs(_ urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "csv" {
            if csvs.contains(where: { $0.url == u }) || panoCSVs.contains(where: { $0.url == u }) { continue }
            do {
                switch try CSVFile.kind(u) {
                case .flightLog: csvs.append(LoadedCSV(url: u, sessions: try FlightLog.load(u)))
                case .threeSixty: panoCSVs.append(Loaded360CSV(url: u, rows: try ThreeSixtyLog.load(u)))
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func removeCSV(_ c: LoadedCSV) { csvs.removeAll { $0.id == c.id } }
    func remove360CSV(_ c: Loaded360CSV) { panoCSVs.removeAll { $0.id == c.id } }

    // MARK: Go

    func go(settings: AppSettings) {
        error = nil
        guard Folders.isFolder(dronePath) else { error = "Drone folder not found. Is the drone (or its card) plugged in?"; return }
        guard !sessions.isEmpty || !panoRows.isEmpty else { error = "Add a Flight Log or 360s CSV first."; return }
        communityDir = [:]; subDir = [:]; locationDir = [:]; ignoredDrone = []; ignored360 = []
        stage = .scanning
        status = "Reading drone files\u{2026}"
        let root = URL(fileURLWithPath: dronePath), sess = sessions, rows = panoRows, buffer = settings.bufferMinutes
        DispatchQueue.global(qos: .userInitiated).async {
            let files = Sorter.scan(root)

            // 360s first, so the Flight Log sort can skip them.
            let m = Sorter.match360(rows, files: files)
            let panoDays = Set(rows.map { $0.date })
            var isPano = m.claimed
            for f in files where f.looksLike360 { isPano.insert(f.url) }

            // Name them Community_Lot12.jpg, then _2, _3 for more in the same lot.
            var named: [(row: PanoRow, file: MediaFile, name: String)] = []
            var unmatched: [MediaFile] = []
            var counts: [String: Int] = [:]
            for (row, f) in m.matched.sorted(by: { $0.file.time < $1.file.time }) {
                if row.community.isEmpty || row.lot.isEmpty { unmatched.append(f); continue }
                let base = "\(Sorter.safe(row.community))_Lot\(Sorter.safe(row.lot))"
                let k = "\(AppSettings.key(row.community))|\(row.lot.lowercased())|\(row.date)"
                let n = (counts[k] ?? 0) + 1
                counts[k] = n
                named.append((row, f, n == 1 ? "\(base).jpg" : "\(base)_\(n).jpg"))
            }
            var left = 0
            for f in files where f.looksLike360 && !m.claimed.contains(f.url) {
                if panoDays.contains(Sorter.dayString(f.time)) { unmatched.append(f) } else { left += 1 }
            }

            let others = files.filter { !isPano.contains($0.url) }
            let a = sess.isEmpty ? [] : Sorter.assign(others, sessions: sess, bufferMinutes: buffer)

            DispatchQueue.main.async {
                self.assignments = a
                self.panoMatched = named
                self.panoUnmatched = unmatched
                self.panoNotFound = m.notFound.map { ($0.row, $0.reason) }
                self.left360 = left
                self.collectNeeds(settings: settings)
            }
        }
    }

    // MARK: Where things go

    private func communityFolder(_ name: String, _ settings: AppSettings) -> String? {
        let k = AppSettings.key(name)
        if let o = communityDir[k] { return o }
        if let cfg = settings.place(named: name) {
            if cfg.alwaysAsk { return nil }
            if !cfg.path.isEmpty { return Folders.isFolder(cfg.path) ? cfg.path : nil }
        }
        return Folders.findChild(named: name, in: settings.communitiesPath)
    }

    private func subFolder(_ name: String, pano: Bool, _ settings: AppSettings) -> String? {
        let k = (pano ? "pano|" : "drone|") + AppSettings.key(name)
        if let o = subDir[k] { return o }
        guard let c = communityFolder(name, settings) else { return nil }
        return Folders.findChild(named: pano ? settings.panoSubfolder : settings.droneSubfolder, in: c)
    }

    private func locationFolder(_ name: String, _ settings: AppSettings) -> String? {
        let k = AppSettings.key(name)
        if let o = locationDir[k] { return o }
        guard let cfg = settings.place(named: name), !cfg.alwaysAsk, Folders.isFolder(cfg.path) else { return nil }
        return cfg.path
    }

    // MARK: Ask about anything missing

    private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// Which folders need an answer before we can start. Runs again after each Continue,
    /// so fixing a community folder can then ask about its Drone / 360's subfolder.
    private func collectNeeds(settings: AppSettings) {
        var droneCount: [String: (name: String, n: Int)] = [:]
        var locCount: [String: (name: String, n: Int)] = [:]
        var panoCount: [String: (name: String, n: Int)] = [:]
        var unsortedCount = 0
        var unmatchedCount = panoUnmatched.count

        for (_, a) in assignments {
            switch a {
            case .place(let p, _, let isLoc):
                let k = AppSettings.key(p)
                if ignoredDrone.contains(k) { unsortedCount += 1; continue }
                if isLoc { locCount[k] = (locCount[k]?.name ?? p, (locCount[k]?.n ?? 0) + 1) }
                else { droneCount[k] = (droneCount[k]?.name ?? p, (droneCount[k]?.n ?? 0) + 1) }
            case .unsorted: unsortedCount += 1
            case .otherDay: break
            }
        }
        for m in panoMatched {
            let k = AppSettings.key(m.row.community)
            if ignored360.contains(k) { unmatchedCount += 1; continue }
            panoCount[k] = (panoCount[k]?.name ?? m.row.community, (panoCount[k]?.n ?? 0) + 1)
        }

        var list: [PathNeed] = []
        let communities = Set(droneCount.keys).union(panoCount.keys).sorted()
        let canCreateCommunity = Folders.isFolder(settings.communitiesPath)

        for k in communities {
            let name = droneCount[k]?.name ?? panoCount[k]?.name ?? k
            let dn = droneCount[k]?.n ?? 0, pn = panoCount[k]?.n ?? 0
            let what = [dn > 0 ? plural(dn, "drone file") : nil, pn > 0 ? plural(pn, "360") : nil].compactMap { $0 }.joined(separator: " \u{00B7} ")
            let alwaysAsk = settings.place(named: name)?.alwaysAsk == true

            guard let cf = communityFolder(name, settings) else {
                let detail = alwaysAsk ? "Set to always ask. Choose its main folder (the one with \(settings.droneSubfolder) and \(settings.panoSubfolder) inside)."
                    : canCreateCommunity ? "No folder called \(name) in \(settings.communitiesPath)."
                    : "Set your Communities folder in Setup, or choose this community's main folder."
                list.append(PathNeed(kind: .community, place: name, title: "\(name) \u{2014} \(what)", detail: detail,
                                     createPath: canCreateCommunity && !alwaysAsk ? (settings.communitiesPath as NSString).appendingPathComponent(name) : nil,
                                     choice: .choose, saveForNextTime: !alwaysAsk))
                continue
            }
            if dn > 0 && subFolder(name, pano: false, settings) == nil {
                list.append(PathNeed(kind: .droneSub, place: name, title: "\(name) \u{2014} \(plural(dn, "drone file"))",
                                     detail: "No \(settings.droneSubfolder) folder in \(cf).",
                                     createPath: (cf as NSString).appendingPathComponent(settings.droneSubfolder),
                                     choice: .create, saveForNextTime: false))
            }
            if pn > 0 && subFolder(name, pano: true, settings) == nil {
                list.append(PathNeed(kind: .panoSub, place: name, title: "\(name) \u{2014} \(plural(pn, "360"))",
                                     detail: "No \(settings.panoSubfolder) folder in \(cf).",
                                     createPath: (cf as NSString).appendingPathComponent(settings.panoSubfolder),
                                     choice: .create, saveForNextTime: false))
            }
        }
        for v in locCount.values.sorted(by: { $0.name < $1.name }) where locationFolder(v.name, settings) == nil {
            let alwaysAsk = settings.place(named: v.name)?.alwaysAsk == true
            list.append(PathNeed(kind: .location, place: v.name, title: "\(v.name) \u{2014} \(plural(v.n, "drone file"))",
                                 detail: alwaysAsk ? "Set to always ask." : "This location doesn't have a folder yet.",
                                 createPath: nil, choice: .choose, saveForNextTime: !alwaysAsk))
        }
        if unsortedCount > 0 && !Folders.isFolder(settings.unsortedPath) {
            list.append(PathNeed(kind: .unsorted, place: "", title: "Unsorted \u{2014} \(plural(unsortedCount, "file"))",
                                 detail: "Drone files outside every Start\u{2013}Stop time (and places you Ignore) go here.",
                                 createPath: nil, choice: .choose, saveForNextTime: true))
        }
        if unmatchedCount > 0 && !Folders.isFolder(settings.unmatched360Path) {
            list.append(PathNeed(kind: .unmatched, place: "", title: "Unmatched 360s \u{2014} \(plural(unmatchedCount, "360"))",
                                 detail: "360s on the drone that no 360s CSV row claims (and 360s you Ignore) go here.",
                                 createPath: nil, choice: .choose, saveForNextTime: true))
        }

        needs = list
        if list.isEmpty { buildPlan(settings: settings) } else { stage = .needPaths }
    }

    var needsComplete: Bool {
        needs.allSatisfy { n in
            switch n.choice {
            case .ignore, .create: return true
            case .choose: return Folders.isFolder(Folders.clean(n.path))
            }
        }
    }

    func applyNeeds(settings: AppSettings) {
        error = nil
        for n in needs {
            let k = AppSettings.key(n.place)
            var path = Folders.clean(n.path)
            if n.choice == .create, let c = n.createPath {
                do { try FileManager.default.createDirectory(atPath: c, withIntermediateDirectories: false) }
                catch { if !Folders.isFolder(c) { self.error = "Couldn't create \(c): \(error.localizedDescription)"; return } }
                path = c
            }
            switch (n.kind, n.choice) {
            case (.community, .ignore):
                ignoredDrone.insert(k); ignored360.insert(k)
            case (.community, _):
                communityDir[k] = path
                if n.choice == .choose && n.saveForNextTime { settings.setPath(path, for: n.place) }
            case (.droneSub, .ignore): ignoredDrone.insert(k)
            case (.droneSub, _): subDir["drone|" + k] = path
            case (.panoSub, .ignore): ignored360.insert(k)
            case (.panoSub, _): subDir["pano|" + k] = path
            case (.location, .ignore): ignoredDrone.insert(k)
            case (.location, _):
                locationDir[k] = path
                if n.saveForNextTime { settings.setPath(path, for: n.place) }
            case (.unsorted, _): settings.unsortedPath = path
            case (.unmatched, _): settings.unmatched360Path = path
            }
        }
        collectNeeds(settings: settings)
    }

    // MARK: Plan + preview

    private func buildPlan(settings: AppSettings) {
        error = nil
        var byFolder: [String: PlanGroup] = [:]
        var otherDays = 0

        func dated(_ base: String, _ date: String) -> URL {
            URL(fileURLWithPath: base).appendingPathComponent(Sorter.folderName(date))
        }
        func addDrone(_ f: MediaFile, label: String, kind: PlanGroup.Kind, base: String, date: String) {
            let folder = dated(base, date)
            var g = byFolder[folder.path] ?? PlanGroup(label: label, kind: kind, folder: folder,
                                                       makeDirs: [folder.appendingPathComponent("Photos"), folder.appendingPathComponent("Videos")])
            g.jobs.append(CopyJob(file: f, dir: folder.appendingPathComponent(f.isVideo ? "Videos" : "Photos"), name: f.name))
            byFolder[folder.path] = g
        }
        func addPano(_ f: MediaFile, label: String, kind: PlanGroup.Kind, base: String, date: String, name: String) {
            let folder = dated(base, date)
            var g = byFolder[folder.path] ?? PlanGroup(label: label, kind: kind, folder: folder)
            g.jobs.append(CopyJob(file: f, dir: folder, name: name))
            byFolder[folder.path] = g
        }

        for (f, a) in assignments {
            switch a {
            case .otherDay:
                otherDays += 1
            case .unsorted:
                addDrone(f, label: "Unsorted", kind: .unsorted, base: settings.unsortedPath, date: Sorter.dayString(f.time))
            case .place(let p, let date, let isLoc):
                if ignoredDrone.contains(AppSettings.key(p)) {
                    addDrone(f, label: "Unsorted", kind: .unsorted, base: settings.unsortedPath, date: Sorter.dayString(f.time))
                } else if isLoc {
                    addDrone(f, label: p, kind: .location, base: locationFolder(p, settings) ?? "", date: date)
                } else {
                    addDrone(f, label: p, kind: .drone, base: subFolder(p, pano: false, settings) ?? "", date: date)
                }
            }
        }
        for m in panoMatched {
            if ignored360.contains(AppSettings.key(m.row.community)) {
                addPano(m.file, label: "Unmatched 360s", kind: .unmatched, base: settings.unmatched360Path, date: m.row.date, name: m.file.name)
            } else {
                addPano(m.file, label: m.row.community, kind: .pano, base: subFolder(m.row.community, pano: true, settings) ?? "",
                        date: m.row.date, name: m.name)
            }
        }
        for f in panoUnmatched {
            addPano(f, label: "Unmatched 360s", kind: .unmatched, base: settings.unmatched360Path, date: Sorter.dayString(f.time), name: f.name)
        }

        // Safety: every destination's main folder must exist (catches an unplugged drive).
        let missing = Set(byFolder.values.map { $0.folder.deletingLastPathComponent().path }).filter { !Folders.isFolder($0) }
        if !missing.isEmpty {
            error = "These folders weren't found \u{2014} is the drive plugged in?\n" + missing.sorted().joined(separator: "\n")
            stage = .idle
            return
        }

        groups = byFolder.values.sorted { ($0.kind.rawValue, $0.label, $0.folder.path) < ($1.kind.rawValue, $1.label, $1.folder.path) }
        report = Report()
        report.otherDays = otherDays
        report.left360 = left360
        report.notFound = panoNotFound
        report.unsorted = groups.filter { $0.kind == .unsorted }.flatMap { $0.jobs }.map { $0.name }
        report.unmatched360 = groups.filter { $0.kind == .unmatched }.flatMap { $0.jobs }.map { $0.name }
        stage = .preview
    }

    // MARK: Copy

    func startCopy() {
        stage = .copying
        progress = 0
        let plan = groups
        let startReport = report
        let total = max(1, plan.reduce(0) { $0 + $1.jobs.count })
        DispatchQueue.global(qos: .userInitiated).async {
            var rep = startReport
            var done = 0
            for g in plan {
                for d in g.makeDirs { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
                for j in g.jobs {
                    DispatchQueue.main.async { self.status = "Copying \(j.file.name) \u{2192} \(g.label)" }
                    switch Sorter.copyVerified(j.file, to: j.dir, as: j.name) {
                    case .copied: rep.copied += 1
                    case .alreadyThere: rep.alreadyThere += 1
                    case .failed(let why): rep.failed.append((j.file.name, why))
                    }
                    done += 1
                    let p = Double(done) / Double(total)
                    DispatchQueue.main.async { self.progress = p }
                }
            }
            DispatchQueue.main.async {
                self.report = rep
                self.stage = .done
                self.status = ""
            }
        }
    }

    func reset() {
        stage = .idle
        needs = []
        groups = []
        assignments = []
        panoMatched = []
        panoUnmatched = []
        panoNotFound = []
        status = ""
        progress = 0
    }
}
