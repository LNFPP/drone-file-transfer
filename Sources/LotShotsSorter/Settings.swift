import Foundation
import AppKit

/// A community or location and the folder its footage goes to.
struct PlaceConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    /// Ask for a folder every run (e.g. "Schellville Event").
    var alwaysAsk: Bool
}

/// Everything set up on the Setup tab. Saved automatically.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var places: [PlaceConfig] { didSet { save() } }
    @Published var unsortedPath: String { didSet { save() } }
    @Published var bufferMinutes: Int { didSet { save() } }
    @Published var dronePath: String { didSet { save() } }
    @Published var rememberDrone: Bool { didSet { save() } }

    init() {
        if let data = d.data(forKey: "places"), let p = try? JSONDecoder().decode([PlaceConfig].self, from: data) {
            places = p
        } else {
            places = [PlaceConfig(name: "Schellville Event", path: "", alwaysAsk: true)]
        }
        unsortedPath = d.string(forKey: "unsortedPath") ?? ""
        bufferMinutes = d.object(forKey: "bufferMinutes") as? Int ?? 5
        dronePath = d.string(forKey: "dronePath") ?? ""
        rememberDrone = d.object(forKey: "rememberDrone") as? Bool ?? true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(places) { d.set(data, forKey: "places") }
        d.set(unsortedPath, forKey: "unsortedPath")
        d.set(bufferMinutes, forKey: "bufferMinutes")
        d.set(rememberDrone ? dronePath : "", forKey: "dronePath")
        d.set(rememberDrone, forKey: "rememberDrone")
    }

    static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    func place(named name: String) -> PlaceConfig? {
        let k = AppSettings.key(name)
        return places.first { AppSettings.key($0.name) == k }
    }

    /// Adds the place if new, otherwise updates its folder.
    func setPath(_ path: String, for name: String) {
        let k = AppSettings.key(name)
        if let i = places.firstIndex(where: { AppSettings.key($0.name) == k }) {
            places[i].path = path
        } else {
            places.append(PlaceConfig(name: name.trimmingCharacters(in: .whitespaces), path: path, alwaysAsk: false))
        }
    }
}

// MARK: - Folder helpers shared by both tabs

enum Folders {
    /// Finder "choose a folder" window (it has its own search box).
    static func choose(title: String, startAt: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !startAt.isEmpty { panel.directoryURL = URL(fileURLWithPath: startAt) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Turns whatever was pasted (a path, ~/..., file:// URL, quotes) into a clean folder path.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("file://"), let u = URL(string: s) { s = u.path }
        s = s.replacingOccurrences(of: "\\ ", with: " ")
        return (s as NSString).expandingTildeInPath
    }

    static func pasteboardPath() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string) else { return nil }
        let p = clean(s)
        return p.isEmpty ? nil : p
    }

    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}
