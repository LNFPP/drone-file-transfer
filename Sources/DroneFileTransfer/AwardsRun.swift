import SwiftUI
import AppKit

struct LoadedAwardsCSV: Identifiable {
    let id = UUID()
    let url: URL
    let rows: [AwardRow]
}

/// An award whose folder wasn't found under the main folder.
struct AwardNeed: Identifiable {
    let id = UUID()
    let key: String            // AwardRow.folderKey
    let award: String
    let winner: String
    let clipCount: Int
    var path = ""
    var skip = false
}

/// One award folder in the preview.
struct AwardGroup: Identifiable {
    let id = UUID()
    let award: String
    let winner: String
    let speaker: String
    let folder: URL
    var clips: [Clip]
}

struct AwardsReport {
    var copied = 0
    var alreadyThere = 0
    var failed: [(String, String)] = []
    var noClip: [AwardRow] = []        // rows with no clip in their time
    var skipped: [String] = []         // awards you chose to skip
    var leftAlone = 0                  // clips not in any CSV row's time
}

final class AwardsModel: ObservableObject {
    @Published var cameraPath = ""
    @Published var csvs: [LoadedAwardsCSV] = []
    @Published var stage: Stage = .idle {
        didSet { CopyState.inProgress = (stage == .scanning || stage == .copying) }
    }
    @Published var status = ""
    @Published var progress = 0.0
    @Published var needs: [AwardNeed] = []
    @Published var groups: [AwardGroup] = []
    @Published var report = AwardsReport()
    @Published var error: String?

    private var rows: [AwardRow] { csvs.flatMap { $0.rows } }
    private var byRow: [UUID: [Clip]] = [:]
    private var leftAlone = 0
    private var chosen: [String: String] = [:]   // folderKey -> folder for this run
    private var skipped = Set<String>()

    func addCSVs(_ urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "csv" {
            if csvs.contains(where: { $0.url == u }) { continue }
            do {
                guard try CSVFile.kind(u) == .awards else {
                    error = "\(u.lastPathComponent) is a drone CSV \u{2014} drop it in the Drone section."
                    continue
                }
                csvs.append(LoadedAwardsCSV(url: u, rows: try AwardsLog.load(u)))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func removeCSV(_ c: LoadedAwardsCSV) { csvs.removeAll { $0.id == c.id } }

    func go(settings: AppSettings) {
        error = nil
        guard Folders.isFolder(cameraPath) else { error = "Camera folder not found. Is the card plugged in?"; return }
        guard Folders.isFolder(settings.awardsMainPath) else { error = "Set the Xmas-Awards main folder in Setup first (is the drive plugged in?)."; return }
        guard !rows.isEmpty else { error = "Add a Christmas Awards CSV first."; return }
        chosen = [:]; skipped = []
        stage = .scanning
        status = "Reading clips\u{2026}"
        let root = URL(fileURLWithPath: cameraPath), r = rows, tol = TimeInterval(settings.awardsTolerance)
        DispatchQueue.global(qos: .userInitiated).async {
            let clips = ClipReader.scan(root)
            let m = AwardsMatcher.match(clips, rows: r, tolerance: tol)
            DispatchQueue.main.async {
                self.byRow = m.byRow
                self.leftAlone = m.unused.count
                self.collectNeeds(settings: settings)
            }
        }
    }

    /// Folder for one row: chosen this run, else found under the main folder.
    private func folder(for r: AwardRow, _ all: [String]) -> String? {
        if let c = chosen[r.folderKey] { return AwardFolders.withSpeaker(c, r.speaker) }
        return AwardFolders.find(award: r.award, winner: r.winner, speaker: r.speaker, in: all)
    }

    private func collectNeeds(settings: AppSettings) {
        let all = AwardFolders.list(settings.awardsMainPath)
        var list: [AwardNeed] = []
        var seen = Set<String>()
        for r in rows where !(byRow[r.id] ?? []).isEmpty && !skipped.contains(r.folderKey) {
            guard folder(for: r, all) == nil, !seen.contains(r.folderKey) else { continue }
            seen.insert(r.folderKey)
            let n = rows.filter { $0.folderKey == r.folderKey }.reduce(0) { $0 + (byRow[$1.id]?.count ?? 0) }
            list.append(AwardNeed(key: r.folderKey, award: r.award, winner: r.winner, clipCount: n))
        }
        needs = list
        if list.isEmpty { buildPlan(all) } else { stage = .needPaths }
    }

    var needsComplete: Bool { needs.allSatisfy { $0.skip || Folders.isFolder(Folders.clean($0.path)) } }

    func applyNeeds(settings: AppSettings) {
        for n in needs {
            if n.skip { skipped.insert(n.key) } else { chosen[n.key] = Folders.clean(n.path) }
        }
        collectNeeds(settings: settings)
    }

    private func buildPlan(_ all: [String]) {
        var byFolder: [String: AwardGroup] = [:]
        var rep = AwardsReport()
        rep.leftAlone = leftAlone
        for r in rows {
            let clips = byRow[r.id] ?? []
            if clips.isEmpty { rep.noClip.append(r); continue }
            if skipped.contains(r.folderKey) {
                rep.skipped.append("\(r.award) \u{2014} \(r.speaker): \(clips.count) clip\(clips.count == 1 ? "" : "s")")
                continue
            }
            guard let f = folder(for: r, all) else { continue }
            var g = byFolder[f] ?? AwardGroup(award: r.award, winner: r.winner, speaker: r.speaker,
                                              folder: URL(fileURLWithPath: f), clips: [])
            g.clips += clips
            byFolder[f] = g
        }
        groups = byFolder.values.sorted { ($0.award, $0.speaker) < ($1.award, $1.speaker) }
        report = rep
        stage = .preview
    }

    func startCopy() {
        stage = .copying
        progress = 0
        let plan = groups, start = report
        let total = max(1, plan.reduce(0) { $0 + $1.clips.count })
        DispatchQueue.global(qos: .userInitiated).async {
            var rep = start
            var done = 0
            for g in plan {
                for c in g.clips {
                    DispatchQueue.main.async { self.status = "Copying \(c.file.name) \u{2192} \(g.award)" }
                    // Never renamed: keeps the camera's file name.
                    switch Sorter.copyVerified(c.file, to: g.folder) {
                    case .copied: rep.copied += 1
                    case .alreadyThere: rep.alreadyThere += 1
                    case .failed(let why): rep.failed.append((c.file.name, why))
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
        byRow = [:]
        status = ""
        progress = 0
    }
}

// MARK: - Run tab section

struct AwardsRunSection: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = AwardsModel()

    var body: some View {
        Group {
            switch model.stage {
            case .idle, .scanning: setup
            case .needPaths: needsView
            case .preview: preview
            case .copying: copying
            case .done: done
            }
            if let e = model.error {
                Text(e).foregroundColor(.red).textSelection(.enabled)
            }
        }
        .onAppear {
            if model.cameraPath.isEmpty && settings.rememberAwardsCamera { model.cameraPath = settings.awardsCameraPath }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox(label: Label("Camera files", systemImage: "video")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.cameraPath.isEmpty ? "No folder chosen" : model.cameraPath)
                            .foregroundColor(model.cameraPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose\u{2026}") {
                            if let p = Folders.choose(title: "Choose the camera card or clips folder",
                                                      startAt: model.cameraPath.isEmpty ? "/Volumes" : model.cameraPath) {
                                model.cameraPath = p
                                if settings.rememberAwardsCamera { settings.awardsCameraPath = p }
                            }
                        }
                    }
                    Toggle("Remember this path", isOn: $settings.rememberAwardsCamera)
                        .onChange(of: settings.rememberAwardsCamera) { on in
                            if on { settings.awardsCameraPath = model.cameraPath }
                        }
                }
                .padding(6)
            }

            GroupBox(label: Label("Christmas Awards CSV", systemImage: "doc.text")) {
                VStack(alignment: .leading, spacing: 10) {
                    CSVDropZone(text: "Drag Christmas Awards CSVs here", icon: "arrow.down.doc") { model.addCSVs($0) }
                    ForEach(model.csvs) { c in
                        HStack {
                            Image(systemName: "doc.text")
                            Text(c.url.lastPathComponent)
                            Text("\u{00B7} \(c.rows.count) clip\(c.rows.count == 1 ? "" : "s") \u{00B7} " + awards(c))
                                .foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            Button { model.removeCSV(c) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(6)
            }

            HStack {
                Button {
                    model.go(settings: settings)
                } label: {
                    Text(model.stage == .scanning ? model.status : "Go")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(SectionColor.blue)
                .disabled(model.stage == .scanning || model.cameraPath.isEmpty || model.csvs.isEmpty)
                if model.stage == .scanning { ProgressView().controlSize(.small) }
            }
        }
    }

    private func awards(_ c: LoadedAwardsCSV) -> String {
        var seen: [String] = []
        for r in c.rows where !seen.contains(r.award) { seen.append(r.award) }
        return seen.joined(separator: ", ")
    }

    private var needsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose folders before starting").font(.title2.bold())
            Text("These awards have clips, but no matching folder was found in \(settings.awardsMainPath).")
                .foregroundColor(.secondary)
            ForEach($model.needs) { $n in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(n.award).font(.headline)
                            if !n.winner.isEmpty { Text(n.winner).foregroundColor(.secondary) }
                            Text("\(n.clipCount) clip\(n.clipCount == 1 ? "" : "s")").foregroundColor(.secondary)
                            Spacer()
                            Toggle("Skip (don't copy)", isOn: $n.skip)
                        }
                        if !n.skip {
                            HStack {
                                TextField("Paste a folder path, or Choose\u{2026}", text: $n.path)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose\u{2026}") {
                                    if let p = Folders.choose(title: "Folder for \(n.award)",
                                                              startAt: n.path.isEmpty ? settings.awardsMainPath : n.path) { n.path = p }
                                }
                            }
                            if !n.path.isEmpty && !Folders.isFolder(Folders.clean(n.path)) {
                                Text("Folder not found").font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                    .padding(6)
                }
            }
            HStack {
                Button("Back") { model.reset() }
                Spacer()
                Button("Continue") { model.applyNeeds(settings: settings) }
                    .buttonStyle(.borderedProminent).tint(SectionColor.blue)
                    .disabled(!model.needsComplete)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to copy").font(.title2.bold())
            Text("Only clips that fall within a CSV row's Start\u{2013}Stop time are copied, with their camera names. Nothing on the card is moved or deleted.")
                .foregroundColor(.secondary)
            ForEach(model.groups) { g in
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "gift.fill").foregroundColor(SectionColor.blue)
                            Text(g.award).font(.headline)
                            if !g.winner.isEmpty { Text(g.winner).foregroundColor(.secondary) }
                            Spacer()
                            Text("\(g.clips.count) clip\(g.clips.count == 1 ? "" : "s")")
                        }
                        Text(g.folder.path).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        ForEach(g.clips, id: \.self) { c in
                            Text("\(c.file.name)  \u{00B7}  \(time(c.start)) \u{2013} \(time(c.end))")
                                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                }
            }
            if model.groups.isEmpty {
                Text("No clips on the card fall within the CSV times.").foregroundColor(.orange)
            }
            noClipBox
            if !model.report.skipped.isEmpty {
                Text("Skipped: " + model.report.skipped.joined(separator: "; ")).font(.callout).foregroundColor(.secondary)
            }
            if model.report.leftAlone > 0 {
                Text("\(model.report.leftAlone) clip\(model.report.leftAlone == 1 ? "" : "s") not in any CSV time will be left alone.")
                    .font(.callout).foregroundColor(.secondary)
            }
            HStack {
                Button("Back") { model.reset() }
                Spacer()
                let n = model.groups.reduce(0) { $0 + $1.clips.count }
                Button("Copy \(n) clip\(n == 1 ? "" : "s")") { model.startCopy() }
                    .buttonStyle(.borderedProminent).tint(SectionColor.blue)
                    .disabled(n == 0)
            }
        }
    }

    @ViewBuilder
    private var noClipBox: some View {
        if !model.report.noClip.isEmpty {
            GroupBox(label: Text("No clip found for (\(model.report.noClip.count))").foregroundColor(.orange)) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.report.noClip) { r in
                        Text("\(r.award) \u{2014} \(r.speaker) \u{00B7} \(time(r.start)) \u{2013} \(time(r.stop))")
                            .font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }

    private var copying: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copying\u{2026}").font(.title2.bold())
            ProgressView(value: model.progress).tint(SectionColor.blue)
            Text(model.status).font(.callout).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Text("Each clip is checked against the original after copying.").font(.caption).foregroundColor(.secondary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.report.failed.isEmpty ? "Done \u{2713}" : "Done, with problems").font(.title2.bold())
            Text("\(model.report.copied) copied  \u{00B7}  \(model.report.alreadyThere) were already there  \u{00B7}  \(model.report.failed.count) failed")
            if !model.report.failed.isEmpty {
                GroupBox(label: Text("Failed (not copied)").foregroundColor(.red)) {
                    VStack(alignment: .leading) {
                        ForEach(Array(model.report.failed.enumerated()), id: \.offset) { item in
                            Text("\(item.element.0) \u{2014} \(item.element.1)").font(.callout).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            noClipBox
            HStack {
                Menu("Open folder") {
                    ForEach(model.groups) { g in
                        Button("\(g.award) \u{2014} \(g.folder.lastPathComponent)") { NSWorkspace.shared.open(g.folder) }
                    }
                }
                .fixedSize()
                .disabled(model.groups.isEmpty)
                Spacer()
                Button("Start over") {
                    model.reset()
                    model.csvs = []
                }
                .buttonStyle(.borderedProminent).tint(SectionColor.blue)
            }
        }
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm:ss a"
        return f.string(from: d)
    }
}
