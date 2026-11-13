import SwiftUI
import AppKit

struct SetupView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Setup").font(.title.bold())
                Text("Each community or location gets a folder. Footage goes into a dated folder inside it (e.g. 11.12.26/Photos, 11.12.26/Videos).")
                    .foregroundColor(.secondary)

                GroupBox(label: Label("Communities & locations", systemImage: "mappin.and.ellipse")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($settings.places) { $p in
                            placeRow($p)
                            Divider()
                        }
                        HStack {
                            TextField("New community or location name", text: $newName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addPlace)
                            Button("Add", action: addPlace).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text("Names must match the names in your Lot Shots Flight Log (capital letters don't matter).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("Unsorted folder", systemImage: "questionmark.folder")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Files shot outside every Start\u{2013}Stop time, and places you choose to Ignore, go here.")
                            .font(.callout).foregroundColor(.secondary)
                        pathControls(path: $settings.unsortedPath, title: "Unsorted folder")
                    }
                    .padding(6)
                }

                GroupBox(label: Label("Time buffer", systemImage: "clock")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper("\(settings.bufferMinutes) minutes before Start and after Stop",
                                value: $settings.bufferMinutes, in: 0...60)
                        Text("Catches shots taken just before you hit Start or just after Stop.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("Remembered drone path", systemImage: "externaldrive")) {
                    HStack {
                        Text(settings.dronePath.isEmpty ? "None" : settings.dronePath)
                            .foregroundColor(settings.dronePath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reset") { settings.dronePath = "" }.disabled(settings.dronePath.isEmpty)
                    }
                    .padding(6)
                }

                if let m = message { Text(m).foregroundColor(.orange) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addPlace() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if settings.place(named: n) != nil {
            message = "\(n) is already in the list."
            return
        }
        settings.places.append(PlaceConfig(name: n, path: "", alwaysAsk: false))
        newName = ""
        message = nil
    }

    @ViewBuilder
    private func placeRow(_ p: Binding<PlaceConfig>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.wrappedValue.name).font(.headline)
                Spacer()
                Toggle("Always ask for folder", isOn: p.alwaysAsk).font(.callout)
                Button(role: .destructive) {
                    let id = p.wrappedValue.id
                    settings.places.removeAll { $0.id == id }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove \(p.wrappedValue.name)")
            }
            if p.wrappedValue.alwaysAsk {
                Text("You'll pick a folder each time this place shows up.").font(.caption).foregroundColor(.secondary)
            } else {
                pathControls(path: p.path, title: "Folder for \(p.wrappedValue.name)")
            }
        }
    }

    /// Path display + Choose… (Finder, searchable) + Paste path + Reset.
    @ViewBuilder
    private func pathControls(path: Binding<String>, title: String) -> some View {
        HStack {
            Image(systemName: Folders.isFolder(path.wrappedValue) ? "folder.fill" : "folder.badge.questionmark")
                .foregroundColor(Folders.isFolder(path.wrappedValue) ? .accentColor : .secondary)
            Text(path.wrappedValue.isEmpty ? "No folder yet" : path.wrappedValue)
                .foregroundColor(path.wrappedValue.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Choose\u{2026}") {
                if let c = Folders.choose(title: title, startAt: path.wrappedValue) { path.wrappedValue = c }
            }
            Button("Paste path") {
                guard let c = Folders.pasteboardPath() else { message = "Nothing to paste \u{2014} copy a folder path first."; return }
                if Folders.isFolder(c) {
                    path.wrappedValue = c
                    message = nil
                } else {
                    message = "That folder wasn't found: \(c)"
                }
            }
            Button("Reset") { path.wrappedValue = "" }.disabled(path.wrappedValue.isEmpty)
        }
        if !path.wrappedValue.isEmpty && !Folders.isFolder(path.wrappedValue) {
            Text("Folder not found \u{2014} is the drive plugged in?").font(.caption).foregroundColor(.red)
        }
    }
}
