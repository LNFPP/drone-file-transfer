import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RunView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = RunModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.stage {
                case .idle, .scanning: setupSection
                case .needPaths: needsSection
                case .preview: previewSection
                case .copying: copyingSection
                case .done: doneSection
                }
                if let e = model.error {
                    Text(e).foregroundColor(.red).textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if model.dronePath.isEmpty && settings.rememberDrone { model.dronePath = settings.dronePath }
        }
    }

    // MARK: 1. Drone folder, CSVs, Go

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox(label: Label("Drone files", systemImage: "externaldrive")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.dronePath.isEmpty ? "No folder chosen" : model.dronePath)
                            .foregroundColor(model.dronePath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose\u{2026}") {
                            if let p = Folders.choose(title: "Choose the drone's folder (e.g. DCIM)",
                                                      startAt: model.dronePath.isEmpty ? "/Volumes" : model.dronePath) {
                                model.dronePath = p
                                if settings.rememberDrone { settings.dronePath = p }
                            }
                        }
                    }
                    Toggle("Remember this path", isOn: $settings.rememberDrone)
                        .onChange(of: settings.rememberDrone) { on in
                            if on { settings.dronePath = model.dronePath }
                        }
                }
                .padding(6)
            }

            GroupBox(label: Label("Flight Log CSV", systemImage: "doc.text")) {
                VStack(alignment: .leading, spacing: 10) {
                    CSVDropZone(text: "Drag Flight Log CSVs here", icon: "arrow.down.doc") { model.addCSVs($0) }
                    ForEach(model.csvs) { c in
                        csvRow(c.url.lastPathComponent, places(c)) { model.removeCSV(c) }
                    }
                }
                .padding(6)
            }

            GroupBox(label: Label("360s Log CSV", systemImage: "globe")) {
                VStack(alignment: .leading, spacing: 10) {
                    CSVDropZone(text: "Drag 360s CSVs here", icon: "arrow.down.doc") { model.addCSVs($0) }
                    ForEach(model.panoCSVs) { c in
                        csvRow(c.url.lastPathComponent, panoSummary(c)) { model.remove360CSV(c) }
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
                .disabled(model.stage == .scanning || model.dronePath.isEmpty || (model.csvs.isEmpty && model.panoCSVs.isEmpty))
                if model.stage == .scanning { ProgressView().controlSize(.small) }
            }
        }
    }

    private func csvRow(_ name: String, _ info: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "doc.text")
            Text(name)
            Text("\u{00B7} " + info).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
        }
    }

    private func places(_ c: LoadedCSV) -> String {
        var seen: [String] = []
        for s in c.sessions where !seen.contains(s.place) { seen.append(s.place) }
        return seen.joined(separator: ", ")
    }

    private func panoSummary(_ c: Loaded360CSV) -> String {
        var seen: [String] = []
        for r in c.rows where !r.community.isEmpty && !seen.contains(r.community) { seen.append(r.community) }
        let dates = Set(c.rows.map { Sorter.folderName($0.date) }).sorted().joined(separator: ", ")
        return "\(seen.joined(separator: ", ")) \u{00B7} \(c.rows.count) rows \u{00B7} \(dates)"
    }

    // MARK: 2. Folders that need an answer

    private var needsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose folders before starting").font(.title2.bold())
            Text("These have files but their folder wasn't found. Nothing is created unless you pick Create.")
                .foregroundColor(.secondary)
            ForEach($model.needs) { $n in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(n.title).font(.headline)
                        Text(n.detail).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
                        let options = choices(for: n)
                        if options.count > 1 {
                            Picker("", selection: $n.choice) {
                                ForEach(options, id: \.self) { c in Text(label(c, n)).tag(c) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        switch n.choice {
                        case .create:
                            Text("Will create: \(n.createPath ?? "")").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        case .ignore:
                            Text(n.kind == .panoSub ? "Its 360s go to Unmatched 360s."
                                 : n.kind == .community ? "Its drone files go to Unsorted and its 360s to Unmatched 360s."
                                 : "Its files go to Unsorted.")
                                .font(.caption).foregroundColor(.secondary)
                        case .choose:
                            HStack {
                                TextField("Paste a folder path, or Choose\u{2026}", text: $n.path)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose\u{2026}") {
                                    if let p = Folders.choose(title: chooseTitle(n), startAt: n.path) { n.path = p }
                                }
                            }
                            if !n.path.isEmpty && !Folders.isFolder(Folders.clean(n.path)) {
                                Text("Folder not found").font(.caption).foregroundColor(.red)
                            }
                            if n.kind == .community || n.kind == .location {
                                Toggle("Save this folder for next time", isOn: $n.saveForNextTime).font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
            HStack {
                Button("Back") { model.reset() }
                Spacer()
                Button("Continue") { model.applyNeeds(settings: settings) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.needsComplete)
            }
        }
    }

    private func choices(for n: PathNeed) -> [PathNeed.Choice] {
        var c: [PathNeed.Choice] = []
        if n.createPath != nil { c.append(.create) }
        c.append(.choose)
        if n.canIgnore { c.append(.ignore) }
        return c
    }

    private func label(_ c: PathNeed.Choice, _ n: PathNeed) -> String {
        switch c {
        case .create: return "Create folder"
        case .choose: return "Choose folder"
        case .ignore: return n.kind == .panoSub ? "Send to Unmatched" : "Send to Unsorted"
        }
    }

    private func chooseTitle(_ n: PathNeed) -> String {
        switch n.kind {
        case .community: return "\(n.place)'s main folder (with \(settings.droneSubfolder) and \(settings.panoSubfolder) inside)"
        case .droneSub: return "Folder for \(n.place)'s drone files"
        case .panoSub: return "Folder for \(n.place)'s 360s"
        case .location: return "Folder for \(n.place)"
        case .unsorted: return "Unsorted folder"
        case .unmatched: return "Unmatched 360s folder"
        }
    }

    // MARK: 3. Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to copy").font(.title2.bold())
            Text("Nothing on the drone is moved or deleted. Check that the times line up before copying.")
                .foregroundColor(.secondary)
            ForEach(model.groups) { g in
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: icon(g.kind)).foregroundColor(color(g.kind))
                            Text(g.label).font(.headline)
                            if g.kind == .pano { Text("360s").foregroundColor(.secondary) }
                            Spacer()
                            Text(counts(g))
                        }
                        Text(g.folder.path).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        if g.kind == .pano {
                            Text(g.jobs.map { $0.name }.joined(separator: ", "))
                                .font(.caption).foregroundColor(.secondary).lineLimit(2)
                        } else if let first = g.jobs.map({ $0.file.time }).min(),
                                  let last = g.jobs.map({ $0.file.time }).max() {
                            Text("Shot \(time(first)) \u{2013} \(time(last))").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                }
            }
            if model.groups.isEmpty {
                Text("No files on the drone match these CSVs.").foregroundColor(.orange)
            }
            notFoundBox
            if model.report.otherDays > 0 {
                Text("\(model.report.otherDays) files from other days will be left alone.").font(.callout).foregroundColor(.secondary)
            }
            if model.report.left360 > 0 {
                Text("\(model.report.left360) 360s from days without a 360s CSV will be left alone.").font(.callout).foregroundColor(.secondary)
            }
            HStack {
                Button("Back") { model.reset() }
                Spacer()
                let n = model.groups.reduce(0) { $0 + $1.jobs.count }
                Button("Copy \(n) files") { model.startCopy() }
                    .buttonStyle(.borderedProminent)
                    .disabled(n == 0)
            }
        }
    }

    @ViewBuilder
    private var notFoundBox: some View {
        if !model.report.notFound.isEmpty {
            GroupBox(label: Text("360s not found on the drone (\(model.report.notFound.count))").foregroundColor(.orange)) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.report.notFound.enumerated()), id: \.offset) { item in
                        let r = item.element.0
                        Text("\(r.community) Lot \(r.lot.isEmpty ? "?" : r.lot) (\(Sorter.folderName(r.date))) \u{2014} \(item.element.1)")
                            .font(.callout).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }

    private func counts(_ g: PlanGroup) -> String {
        switch g.kind {
        case .pano, .unmatched: return "\(g.jobs.count) 360\(g.jobs.count == 1 ? "" : "s")"
        default: return "\(g.photos) photos  \u{00B7}  \(g.videos) videos"
        }
    }

    private func icon(_ k: PlanGroup.Kind) -> String {
        switch k {
        case .drone: return "mappin.circle.fill"
        case .pano: return "globe"
        case .location: return "mappin.and.ellipse"
        case .unmatched, .unsorted: return "questionmark.folder.fill"
        }
    }

    private func color(_ k: PlanGroup.Kind) -> Color {
        k == .unmatched || k == .unsorted ? .orange : .accentColor
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: d)
    }

    // MARK: 4. Copying + report

    private var copyingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copying\u{2026}").font(.title2.bold())
            ProgressView(value: model.progress)
            Text(model.status).font(.callout).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Text("Each file is checked against the original after copying.").font(.caption).foregroundColor(.secondary)
        }
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.report.failed.isEmpty ? "Done \u{2713}" : "Done, with problems").font(.title2.bold())
            Text("\(model.report.copied) copied  \u{00B7}  \(model.report.alreadyThere) were already there  \u{00B7}  \(model.report.failed.count) failed")
            if !model.report.failed.isEmpty {
                listBox("Failed (not copied)", .red, model.report.failed.map { "\($0.0) \u{2014} \($0.1)" })
            }
            notFoundBox
            if !model.report.unmatched360.isEmpty {
                listBox("Sent to Unmatched 360s (\(model.report.unmatched360.count))", .orange, model.report.unmatched360)
            }
            if !model.report.unsorted.isEmpty {
                listBox("Sent to Unsorted (\(model.report.unsorted.count))", .orange, model.report.unsorted)
            }
            HStack {
                Menu("Open folder") {
                    ForEach(model.groups) { g in
                        Button("\(g.label) \u{2014} \(g.folder.lastPathComponent)") { NSWorkspace.shared.open(g.folder) }
                    }
                }
                .fixedSize()
                .disabled(model.groups.isEmpty)
                Spacer()
                Button("Start over") {
                    model.reset()
                    model.csvs = []
                    model.panoCSVs = []
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func listBox(_ title: String, _ color: Color, _ lines: [String]) -> some View {
        GroupBox(label: Text(title).foregroundColor(color)) {
            VStack(alignment: .leading) {
                ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.callout).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}

/// A dashed drop area for CSVs, with a "choose…" link. Takes several at once.
struct CSVDropZone: View {
    let text: String
    let icon: String
    let onURLs: ([URL]) -> Void
    @State private var hover = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                .foregroundColor(hover ? .accentColor : .secondary)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Color.accentColor.opacity(0.08) : Color.clear))
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 24))
                Text(text)
                Button("or choose\u{2026}") { choose() }.buttonStyle(.link)
            }
            .foregroundColor(.secondary)
        }
        .frame(height: 100)
        .onDrop(of: [UTType.fileURL], isTargeted: $hover) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { onURLs([url]) } }
                }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { onURLs(panel.urls) }
    }
}
