import Foundation
import SwiftUI

struct LoadedCSV: Identifiable {
    let id = UUID()
    let url: URL
    let sessions: [Session]
}

/// A place that has footage but no folder yet (or is set to "always ask").
struct PathNeed: Identifiable {
    let id = UUID()
    let place: String          // name as written in the CSV, or "Unsorted"
    let isUnsorted: Bool
    let fileCount: Int
    var path: String
    var ignore: Bool = false   // send this place's files to Unsorted instead
    var saveForNextTime: Bool
}

/// One destination folder in the preview.
struct PlanGroup: Identifiable {
    let id = UUID()
    let label: String          // place name or "Unsorted"
    let folder: URL            // .../<place path>/11.12.26
    let isPlace: Bool
    var photos: [MediaFile] = []
    var videos: [MediaFile] = []
}

struct Report {
    var copied = 0
    var alreadyThere = 0
    var failed: [(String, String)] = []
    var unsorted: [String] = []
    var otherDays = 0
}

enum Stage { case idle, scanning, needPaths, preview, copying, done }

final class RunModel: ObservableObject {
    @Published var dronePath = ""
    @Published var csvs: [LoadedCSV] = []
    @Published var stage: Stage = .idle
    @Published var status = ""
    @Published var progress = 0.0
    @Published var needs: [PathNeed] = []
    @Published var groups: [PlanGroup] = []
    @Published var report = Report()
    @Published var error: String?

    private var assignments: [(MediaFile, Assignment)] = []
    private var sessions: [Session] { csvs.flatMap { $0.sessions } }

    // MARK: CSVs

    func addCSVs(_ urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "csv" {
            if csvs.contains(where: { $0.url == u }) { continue }
            do {
                let s = try FlightLog.load(u)
                csvs.append(LoadedCSV(url: u, sessions: s))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func removeCSV(_ c: LoadedCSV) { csvs.removeAll { $0.id == c.id } }

    // MARK: Go

    func go(settings: AppSettings) {
        error = nil
        guard Folders.isFolder(dronePath) else { error = "Drone folder not found. Is the drone (or its card) plugged in?"; return }
        guard !sessions.isEmpty else { error = "Add a Flight Log CSV first."; return }
        stage = .scanning
        status = "Reading drone files\u{2026}"
        let root = URL(fileURLWithPath: dronePath), sess = sessions, buffer = settings.bufferMinutes
        DispatchQueue.global(qos: .userInitiated).async {
            let files = Sorter.scan(root)
            let a = Sorter.assign(files, sessions: sess, bufferMinutes: buffer)
            DispatchQueue.main.async {
                self.assignments = a
                self.collectNeeds(settings: settings)
            }
        }
    }

    /// Which places need a folder before we can start.
    private func collectNeeds(settings: AppSettings) {
        var counts: [String: (name: String, n: Int)] = [:]
        var unsortedCount = 0
        for (_, a) in assignments {
            switch a {
            case .place(let p, _):
                let k = AppSettings.key(p)
                counts[k] = (counts[k]?.name ?? p, (counts[k]?.n ?? 0) + 1)
            case .unsorted: unsortedCount += 1
            case .otherDay: break
            }
        }
        var list: [PathNeed] = []
        for (_, v) in counts.sorted(by: { $0.key < $1.key }) {
            let cfg = settings.place(named: v.name)
            let saved = cfg?.path ?? ""
            if cfg?.alwaysAsk == true || saved.isEmpty {
                list.append(PathNeed(place: v.name, isUnsorted: false, fileCount: v.n, path: "", saveForNextTime: cfg?.alwaysAsk != true))
            }
        }
        if unsortedCount > 0 && settings.unsortedPath.isEmpty {
            list.append(PathNeed(place: "Unsorted", isUnsorted: true, fileCount: unsortedCount, path: "", saveForNextTime: true))
        }
        needs = list
        if list.isEmpty { buildPlan(settings: settings) } else { stage = .needPaths }
    }

    /// If you ignore a place, its files go to Unsorted, so Unsorted needs a folder too.
    func addUnsortedRowIfNeeded(settings: AppSettings) {
        let anyIgnored = needs.contains { $0.ignore }
        let hasRow = needs.contains { $0.isUnsorted }
        if anyIgnored && !hasRow && settings.unsortedPath.isEmpty {
            let n = needs.filter { $0.ignore }.reduce(0) { $0 + $1.fileCount }
            needs.append(PathNeed(place: "Unsorted", isUnsorted: true, fileCount: n, path: "", saveForNextTime: true))
        }
    }

    /// Every row has a usable folder (or is ignored).
    var needsComplete: Bool {
        needs.allSatisfy { $0.ignore || Folders.isFolder(Folders.clean($0.path)) }
    }

    func applyNeeds(settings: AppSettings) {
        for n in needs where !n.ignore {
            let p = Folders.clean(n.path)
            if n.isUnsorted {
                settings.unsortedPath = p
            } else if n.saveForNextTime {
                settings.setPath(p, for: n.place)
            }
        }
        buildPlan(settings: settings)
    }

    // MARK: Plan + preview

    private func buildPlan(settings: AppSettings) {
        error = nil
        var overrides: [String: String] = [:]   // place key -> folder for this run only
        var ignored = Set<String>()
        for n in needs where !n.isUnsorted {
            if n.ignore { ignored.insert(AppSettings.key(n.place)) } else { overrides[AppSettings.key(n.place)] = Folders.clean(n.path) }
        }
        let unsortedBase = needs.first(where: { $0.isUnsorted }).map { Folders.clean($0.path) } ?? settings.unsortedPath

        var byFolder: [String: PlanGroup] = [:]
        var otherDays = 0
        var missing: [String] = []

        func add(_ f: MediaFile, label: String, base: String, date: String, isPlace: Bool) {
            let folder = URL(fileURLWithPath: base).appendingPathComponent(Sorter.folderName(date))
            var g = byFolder[folder.path] ?? PlanGroup(label: label, folder: folder, isPlace: isPlace)
            if f.isVideo { g.videos.append(f) } else { g.photos.append(f) }
            byFolder[folder.path] = g
        }

        for (f, a) in assignments {
            switch a {
            case .otherDay:
                otherDays += 1
            case .unsorted:
                add(f, label: "Unsorted", base: unsortedBase, date: Sorter.dayString(f.time), isPlace: false)
            case .place(let p, let date):
                let k = AppSettings.key(p)
                if ignored.contains(k) {
                    add(f, label: "Unsorted", base: unsortedBase, date: Sorter.dayString(f.time), isPlace: false)
                } else {
                    let base = overrides[k] ?? settings.place(named: p)?.path ?? ""
                    add(f, label: p, base: base, date: date, isPlace: true)
                }
            }
        }

        // Safety: every destination's main folder must exist (catches an unplugged drive).
        let bases = Set(byFolder.values.map { $0.folder.deletingLastPathComponent().path })
        for b in bases where !Folders.isFolder(b) { missing.append(b) }
        if !missing.isEmpty {
            error = "These folders weren't found \u{2014} is the drive plugged in?\n" + missing.sorted().joined(separator: "\n")
            stage = .idle
            return
        }

        groups = byFolder.values.sorted { ($0.isPlace ? 0 : 1, $0.label, $0.folder.path) < ($1.isPlace ? 0 : 1, $1.label, $1.folder.path) }
        report = Report()
        report.otherDays = otherDays
        report.unsorted = groups.filter { !$0.isPlace }.flatMap { $0.photos + $0.videos }.map { $0.name }
        stage = .preview
    }

    // MARK: Copy

    func startCopy() {
        stage = .copying
        progress = 0
        let plan = groups
        let startReport = report
        let total = max(1, plan.reduce(0) { $0 + $1.photos.count + $1.videos.count })
        DispatchQueue.global(qos: .userInitiated).async {
            var rep = startReport
            var done = 0
            let fm = FileManager.default
            for g in plan {
                let photos = g.folder.appendingPathComponent("Photos")
                let videos = g.folder.appendingPathComponent("Videos")
                // Place folders always get Photos/Edited (empty, for your edits) and Videos.
                if g.isPlace {
                    try? fm.createDirectory(at: photos.appendingPathComponent("Edited"), withIntermediateDirectories: true)
                    try? fm.createDirectory(at: videos, withIntermediateDirectories: true)
                }
                for (f, dir) in g.photos.map({ ($0, photos) }) + g.videos.map({ ($0, videos) }) {
                    DispatchQueue.main.async { self.status = "Copying \(f.name) \u{2192} \(g.label)" }
                    switch Sorter.copyVerified(f, to: dir) {
                    case .copied: rep.copied += 1
                    case .alreadyThere: rep.alreadyThere += 1
                    case .failed(let why): rep.failed.append((f.name, why))
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
        status = ""
        progress = 0
    }
}
