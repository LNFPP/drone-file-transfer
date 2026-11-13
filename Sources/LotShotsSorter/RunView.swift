import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct RunView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = RunModel()
    @State private var dropHover = false

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
                            if let p = Folders.choose(title: "Choose the drone's folder (e.g. DCIM)", startAt: model.dronePath) {
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
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                            .foregroundColor(dropHover ? .accentColor : .secondary)
                            .background(RoundedRectangle(cornerRadius: 10).fill(dropHover ? Color.accentColor.opacity(0.08) : Color.clear))
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc").font(.system(size: 28))
                            Text("Drag Flight Log CSVs here")
                            Button("or choose\u{2026}") { chooseCSVs() }.buttonStyle(.link)
                        }
                        .foregroundColor(.secondary)
                    }
                    .frame(height: 120)
                    .onDrop(of: [UTType.fileURL], isTargeted: $dropHover) { providers in
                        for p in providers {
                            _ = p.loadObject(ofClass: URL.self) { url, _ in
                                if let url = url { DispatchQueue.main.async { model.addCSVs([url]) } }
                            }
                        }
                        return true
                    }

                    ForEach(model.csvs) { c in
                        HStack {
                            Image(systemName: "doc.text")
                            Text(c.url.lastPathComponent)
                            Text("\u{00B7} " + places(c)).foregroundColor(.secondary).lineLimit(1)
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
                .disabled(model.stage == .scanning || model.dronePath.isEmpty || model.csvs.isEmpty)
                if model.stage == .scanning { ProgressView().controlSize(.small) }
            }
        }
    }

    private func places(_ c: LoadedCSV) -> String {
        var seen: [String] = []
        for s in c.sessions where !seen.contains(s.place) { seen.append(s.place) }
        return seen.joined(separator: ", ")
    }

    private func chooseCSVs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.addCSVs(panel.urls) }
    }

    // MARK: 2. Places without a folder

    private var needsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose folders before starting").font(.title2.bold())
            Text("These places have footage but no folder yet. Choose or paste a folder, or Ignore to send them to Unsorted.")
                .foregroundColor(.secondary)
            ForEach($model.needs) { $n in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(n.place).font(.headline)
                            Text("\(n.fileCount) file\(n.fileCount == 1 ? "" : "s")").foregroundColor(.secondary)
                            Spacer()
                            if !n.isUnsorted {
                                Toggle("Ignore (send to Unsorted)", isOn: $n.ignore)
                                    .onChange(of: n.ignore) { _ in model.addUnsortedRowIfNeeded(settings: settings) }
                            }
                        }
                        if !n.ignore {
                            HStack {
                                TextField("Paste a folder path, or Choose\u{2026}", text: $n.path)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose\u{2026}") {
                                    if let p = Folders.choose(title: "Folder for \(n.place)") { n.path = p }
                                }
                            }
                            if !n.path.isEmpty && !Folders.isFolder(Folders.clean(n.path)) {
                                Text("Folder not found").font(.caption).foregroundColor(.red)
                            }
                            if !n.isUnsorted {
                                Toggle("Save this folder for next time", isOn: $n.saveForNextTime).font(.callout)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.needsComplete)
            }
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
                            Image(systemName: g.isPlace ? "mappin.circle.fill" : "questionmark.folder.fill")
                                .foregroundColor(g.isPlace ? .accentColor : .orange)
                            Text(g.label).font(.headline)
                            Spacer()
                            Text("\(g.photos.count) photos  \u{00B7}  \(g.videos.count) videos")
                        }
                        Text(g.folder.path).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        if let first = (g.photos + g.videos).map({ $0.time }).min(),
                           let last = (g.photos + g.videos).map({ $0.time }).max() {
                            Text("Shot \(time(first)) \u{2013} \(time(last))").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                }
            }
            if model.groups.isEmpty {
                Text("No photos or videos on the drone match these Flight Log dates.").foregroundColor(.orange)
            }
            if model.report.otherDays > 0 {
                Text("\(model.report.otherDays) files from other days will be left alone.").font(.callout).foregroundColor(.secondary)
            }
            HStack {
                Button("Back") { model.reset() }
                Spacer()
                let n = model.groups.reduce(0) { $0 + $1.photos.count + $1.videos.count }
                Button("Copy \(n) files") { model.startCopy() }
                    .buttonStyle(.borderedProminent)
                    .disabled(n == 0)
            }
        }
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
                GroupBox(label: Text("Failed (not copied)").foregroundColor(.red)) {
                    VStack(alignment: .leading) {
                        ForEach(Array(model.report.failed.enumerated()), id: \.offset) { item in
                            Text("\(item.element.0) \u{2014} \(item.element.1)").font(.callout).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            if !model.report.unsorted.isEmpty {
                GroupBox(label: Text("Sent to Unsorted (\(model.report.unsorted.count))").foregroundColor(.orange)) {
                    VStack(alignment: .leading) {
                        ForEach(model.report.unsorted, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            HStack {
                ForEach(model.groups.filter { $0.isPlace }) { g in
                    Button("Open \(g.label)") { NSWorkspace.shared.open(g.folder) }
                }
                Spacer()
                Button("Start over") {
                    model.reset()
                    model.csvs = []
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
