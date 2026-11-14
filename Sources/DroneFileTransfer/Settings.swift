import Foundation
import AppKit

/// A location and the folder its footage goes to, or a community whose folder
/// isn't found automatically (path = its main folder, the one with Drone and 360's inside).
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
    /// e.g. /Volumes/Drive/Video/Communities: each community's folder is found in here by name.
    @Published var communitiesPath: String { didSet { save(); Folders.defaultStart = communitiesPath } }
    @Published var droneSubfolder: String { didSet { save() } }
    @Published var panoSubfolder: String { didSet { save() } }
    @Published var unsortedPath: String { didSet { save() } }
    @Published var unmatched360Path: String { didSet { save() } }
    @Published var bufferMinutes: Int { didSet { save() } }
    @Published var dronePath: String { didSet { save() } }
    @Published var rememberDrone: Bool { didSet { save() } }

    init() {
        if let data = d.data(forKey: "places"), let p = try? JSONDecoder().decode([PlaceConfig].self, from: data) {
            places = p
        } else {
            places = [PlaceConfig(name: "Schellville Event", path: "", alwaysAsk: true)]
        }
        communitiesPath = d.string(forKey: "communitiesPath") ?? ""
        droneSubfolder = d.string(forKey: "droneSubfolder") ?? "Drone"
        panoSubfolder = d.string(forKey: "panoSubfolder") ?? "360's"
        unsortedPath = d.string(forKey: "unsortedPath") ?? ""
        unmatched360Path = d.string(forKey: "unmatched360Path") ?? ""
        bufferMinutes = d.object(forKey: "bufferMinutes") as? Int ?? 5
        dronePath = d.string(forKey: "dronePath") ?? ""
        rememberDrone = d.object(forKey: "rememberDrone") as? Bool ?? true
        Folders.defaultStart = communitiesPath
    }

    private func save() {
        if let data = try? JSONEncoder().encode(places) { d.set(data, forKey: "places") }
        d.set(communitiesPath, forKey: "communitiesPath")
        d.set(droneSubfolder, forKey: "droneSubfolder")
        d.set(panoSubfolder, forKey: "panoSubfolder")
        d.set(unsortedPath, forKey: "unsortedPath")
        d.set(unmatched360Path, forKey: "unmatched360Path")
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
    /// Where Choose… opens when there's no folder yet: the Communities folder.
    static var defaultStart = ""

    /// Finder "choose a folder" window (it has its own search box).
    static func choose(title: String, startAt: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let start = isFolder(startAt) ? startAt : defaultStart
        if isFolder(start) { panel.directoryURL = URL(fileURLWithPath: start) }
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

    /// Lowercase letters and numbers only, so "360's" = "360s" and "Walden " = "walden".
    static func simple(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Finds the folder inside `parent` that matches `name`, ignoring capitals, spaces and punctuation.
    /// Exact match first; otherwise a single folder that starts with, then contains, the name.
    static func findChild(named name: String, in parent: String) -> String? {
        let want = simple(name)
        guard !want.isEmpty, isFolder(parent),
              let items = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return nil }
        let dirs = items.filter { !$0.hasPrefix(".") && isFolder((parent as NSString).appendingPathComponent($0)) }
        let full = { (n: String) in (parent as NSString).appendingPathComponent(n) }
        if let exact = dirs.first(where: { simple($0) == want }) { return full(exact) }
        let starts = dirs.filter { simple($0).hasPrefix(want) }
        if starts.count == 1 { return full(starts[0]) }
        let contains = dirs.filter { simple($0).contains(want) }
        if contains.count == 1 { return full(contains[0]) }
        return nil
    }

    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}
