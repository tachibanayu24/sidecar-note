import AppKit
import Combine

private enum Stamp {
    static let noteName = formatter("yyyy-MM-dd HHmmss")
    static let compact = formatter("yyyyMMdd-HHmmss")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

/// A file name in `folder` that doesn't exist yet: "base.md", "base 2.md", "base 3.md", …
private func availableURL(in folder: URL, base: String, isTaken: (URL) -> Bool = { _ in false }) -> URL {
    var url = folder.appendingPathComponent(base + ".md")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) || isTaken(url) {
        url = folder.appendingPathComponent("\(base) \(n).md")
        n += 1
    }
    return url
}

/// One Markdown file on disk, with its own editor instance so undo history and selection survive tab switches.
final class Note: ObservableObject, Identifiable {
    let id = UUID()
    private(set) var url: URL
    @Published private(set) var title: String = ""
    let editor: EditorController
    /// Any edit (the store uses it to forget "undo close").
    var onEdit: (() -> Void)?

    /// Files are written back in the encoding they were read with (e.g. Shift_JIS stays Shift_JIS).
    private var encoding: String.Encoding
    private var savedText: String
    private var savedModificationDate: Date?
    private var saveWork: DispatchWorkItem?

    init(url: URL, text: String, encoding: String.Encoding = .utf8, styler: MarkdownStyler) {
        self.url = url
        self.encoding = encoding
        savedText = text
        savedModificationDate = Note.modificationDate(of: url)
        editor = EditorController(text: text, styler: styler)
        title = Note.makeTitle(from: text as NSString)
        editor.onTextChange = { [weak self] in self?.textDidChange() }
    }

    var fileName: String { url.lastPathComponent }
    /// Nothing but whitespace.
    var isBlank: Bool {
        editor.storage.mutableString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func textDidChange() {
        onEdit?()
        let newTitle = Note.makeTitle(from: editor.storage.mutableString)
        if newTitle != title { title = newTitle }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Writes pending changes. Returns false only when the file could not be written.
    @discardableResult
    func save() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        let current = editor.text
        guard current != savedText else { return true }
        if current.isEmpty && !FileManager.default.fileExists(atPath: url.path) {
            savedText = current
            return true
        }
        preserveExternalEdits()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if current.data(using: encoding) == nil {
                // New text can't be represented in the file's legacy encoding: keep the original, switch to UTF-8.
                backUp(suffix: "original")
                encoding = .utf8
            }
            try current.write(to: url, atomically: true, encoding: encoding)
            savedText = current
            savedModificationDate = Note.modificationDate(of: url)
            return true
        } catch {
            NSLog("Failed to save \(url.path): \(error)")
            return false
        }
    }

    /// If another app changed the file since we last read it, keep that version as a sibling file instead of overwriting it.
    private func preserveExternalEdits() {
        guard let date = Note.modificationDate(of: url), date != savedModificationDate,
              let disk = Note.read(url)?.text, disk != savedText, disk != editor.text else { return }
        backUp(suffix: "conflict \(Stamp.compact.string(from: date))")
    }

    private func backUp(suffix: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let base = url.deletingPathExtension().lastPathComponent + " (\(suffix))"
        try? FileManager.default.copyItem(at: url, to: availableURL(in: url.deletingLastPathComponent(), base: base))
    }

    /// Reads a note: UTF-8, or a detected / common Japanese legacy encoding. Nil when it isn't readable text.
    static func read(_ url: URL) -> (text: String, encoding: String.Encoding)? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return (s, .utf8) }
        var detected = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &detected) { return (s, detected) }
        for candidate in [String.Encoding.shiftJIS, .japaneseEUC] {
            if let s = try? String(contentsOf: url, encoding: candidate) { return (s, candidate) }
        }
        return nil
    }

    /// Picks up edits made by other apps while we weren't looking (only when there is nothing unsaved here).
    func reloadIfChangedOnDisk() {
        guard editor.text == savedText, let date = Note.modificationDate(of: url), date != savedModificationDate,
              let disk = Note.read(url) else { return }
        savedText = disk.text
        encoding = disk.encoding
        savedModificationDate = date
        editor.replaceText(disk.text)
        title = Note.makeTitle(from: disk.text as NSString)
    }

    /// Brings back the file of a closed note (from the Trash, or rewritten if the Trash was emptied),
    /// never over another file that has taken its name meanwhile.
    func restoreFile(from trashed: URL?, isTaken: (URL) -> Bool) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) || isTaken(url) {
            url = availableURL(in: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent,
                               isTaken: isTaken)
        }
        if let trashed, fm.fileExists(atPath: trashed.path), (try? fm.moveItem(at: trashed, to: url)) != nil {
            savedModificationDate = Note.modificationDate(of: url)
            return
        }
        savedText = ""   // force the next save to write the text
        savedModificationDate = nil
        save()
    }

    func moved(to newURL: URL) {
        url = newURL
        savedModificationDate = Note.modificationDate(of: newURL)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The first meaningful line, without Markdown markers. Stops at that line, so it stays cheap per keystroke.
    static func makeTitle(from text: NSString) -> String {
        var title = ""
        text.enumerateLines { raw, stop in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("~~~") { return }
            for prefix in ["#", ">", "- [ ]", "- [x]", "- [X]", "* ", "- ", "+ "] {
                while line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !line.isEmpty {
                title = String(line.prefix(28))
                stop.pointee = true
            }
        }
        return title
    }
}

final class NoteStore: ObservableObject {
    enum CloseResult { case closed, reopenable, failed }

    /// Closed notes that ⌘Z can bring back, most recent last. Forgotten as soon as any note is edited,
    /// so ⌘Z goes back to undoing text.
    private var recentlyClosed: [(note: Note, index: Int, trashed: URL?)] = []
    var canReopen: Bool { !recentlyClosed.isEmpty }
    /// Where the last closed note's file went (for the dev self-test to clean up after itself).
    var debugLastTrashedURL: URL? { recentlyClosed.last?.trashed }

    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?

    let styler = MarkdownStyler()
    private(set) var folder: URL
    private let defaults = UserDefaults.standard

    var assetsFolder: URL { folder.appendingPathComponent("assets", isDirectory: true) }
    var selected: Note? { notes.first { $0.id == selectedID } ?? notes.first }

    init(folder: URL) {
        self.folder = folder
        styler.imageProvider = { [weak self] source in self?.loadImage(source) }
        load()
    }

    // MARK: Loading

    private func load() {
        imageCache.removeAll()
        imageFailures.removeAll()
        styler.clearImageCache()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        let markdown = files.filter { $0.pathExtension.lowercased() == "md" }
        let order = defaults.stringArray(forKey: "noteOrder") ?? []
        let sorted = markdown.sorted { a, b in
            let ia = order.firstIndex(of: a.lastPathComponent) ?? Int.max
            let ib = order.firstIndex(of: b.lastPathComponent) ?? Int.max
            if ia != ib { return ia < ib }
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return da < db
        }
        // Unreadable files never become tabs, so closing a tab can't discard their contents.
        notes = sorted.compactMap { url in
            Note.read(url).map { adopt(Note(url: url, text: $0.text, encoding: $0.encoding, styler: styler)) }
        }
        recentlyClosed.removeAll()
        if notes.isEmpty { notes = [makeNote()] }
        let selectedName = defaults.string(forKey: "selectedNote")
        selectedID = notes.first { $0.fileName == selectedName }?.id ?? notes.first?.id
        persistOrder()
    }

    private func makeNote() -> Note {
        let url = availableURL(in: folder, base: Stamp.noteName.string(from: Date())) { url in
            self.notes.contains { $0.url == url }
        }
        return adopt(Note(url: url, text: "", styler: styler))
    }

    private func adopt(_ note: Note) -> Note {
        note.onEdit = { [weak self] in self?.recentlyClosed.removeAll() }
        return note
    }

    private func persistOrder() {
        defaults.set(notes.map(\.fileName), forKey: "noteOrder")
        defaults.set(selected?.fileName, forKey: "selectedNote")
    }

    // MARK: Tabs

    func select(_ note: Note) {
        let previous = selected
        selectedID = note.id
        if let previous, previous !== note { discardIfBlank(previous) }
        persistOrder()
    }

    /// Blank notes don't linger as "Untitled" tabs: they go away once you leave them (or hide the panel).
    func discardIfBlank(_ note: Note) {
        guard note.isBlank, notes.count > 1, let index = notes.firstIndex(where: { $0 === note }) else { return }
        if FileManager.default.fileExists(atPath: note.url.path) {
            try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        }
        notes.remove(at: index)
        persistOrder()
    }

    func discardSelectedIfBlank() {
        if let note = selected, notes.count > 1, note.isBlank {
            let index = notes.firstIndex { $0 === note } ?? 0
            selectedID = notes[index == 0 ? 1 : index - 1].id
            discardIfBlank(note)
        }
    }

    func select(index: Int) {
        guard notes.indices.contains(index) else { return }
        select(notes[index])
    }

    func selectNext(offset: Int) {
        guard let current = selected, let i = notes.firstIndex(where: { $0.id == current.id }) else { return }
        select(notes[(i + offset + notes.count) % notes.count])
    }

    @discardableResult
    func newNote() -> Note {
        let note = makeNote()
        let insertAt = (selected.flatMap { s in notes.firstIndex { $0.id == s.id } } ?? notes.count - 1) + 1
        notes.insert(note, at: insertAt)
        select(note)
        return note
    }

    /// Closes a tab. Its file (if any) goes to the Trash, so nothing is ever deleted outright.
    /// A note whose latest edits can't be saved stays open.
    @discardableResult
    func close(_ note: Note) -> CloseResult {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return .closed }
        guard note.save() else { return .failed }
        var trashedURL: URL?
        let fm = FileManager.default
        if fm.fileExists(atPath: note.url.path) {
            var resulting: NSURL?
            // A file that can't go to the Trash would come back on next launch: keep the tab instead.
            guard (try? fm.trashItem(at: note.url, resultingItemURL: &resulting)) != nil else { return .failed }
            trashedURL = resulting as URL?
        }
        var result = CloseResult.closed
        if !note.isBlank {
            recentlyClosed.append((note, index, trashedURL))
            result = .reopenable
        }
        notes.remove(at: index)
        if notes.isEmpty { notes = [makeNote()] }
        if selectedID == note.id { selectedID = notes[min(index, notes.count - 1)].id }
        persistOrder()
        return result
    }

    /// ⌘Z right after closing: the note comes back where it was, with its undo history and selection.
    func reopenLastClosed() {
        guard let (note, index, trashed) = recentlyClosed.popLast() else { return }
        note.restoreFile(from: trashed) { url in self.notes.contains { $0.url == url } }
        // Closing the last note left a fresh blank one behind; it has no reason to stay.
        if notes.count == 1, let placeholder = notes.first, placeholder.isBlank,
           !FileManager.default.fileExists(atPath: placeholder.url.path) {
            notes.removeAll()
        }
        notes.insert(note, at: min(index, notes.count))
        let previous = selected
        selectedID = note.id
        if let previous, previous !== note { discardIfBlank(previous) }
        persistOrder()
    }

    func move(from source: Int, to destination: Int) {
        guard notes.indices.contains(source) else { return }
        let note = notes.remove(at: source)
        notes.insert(note, at: min(max(0, destination), notes.count))
        persistOrder()
    }

    func saveAll() {
        notes.forEach { $0.save() }
    }

    func reloadChangedFiles() {
        notes.forEach { $0.reloadIfChangedOnDisk() }
    }

    /// Fonts / appearance changed: restyle the visible note now, the others when they are shown.
    func restyleAll() {
        notes.forEach { $0.editor.setNeedsRestyle() }
    }

    func imageWidthChanged() {
        styler.clearImageCache()
        restyleAll()
    }

    /// Resolves a link target: absolute URLs as-is, anything else relative to the notes folder.
    func resolve(_ link: String) -> URL? {
        if let url = URL(string: link), url.scheme != nil { return url }
        return folder.appendingPathComponent(link.removingPercentEncoding ?? link)
    }

    // MARK: Folder

    /// Moves every note (and its assets) into a new folder.
    func changeFolder(to newFolder: URL) {
        guard newFolder.standardizedFileURL != folder.standardizedFileURL else { return }
        saveAll()
        let fm = FileManager.default
        try? fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for note in notes where fm.fileExists(atPath: note.url.path) {
            // Never skip a note on a name clash: pick "name 2.md", "name 3.md", …
            let target = availableURL(in: newFolder, base: note.url.deletingPathExtension().lastPathComponent)
            if (try? fm.moveItem(at: note.url, to: target)) != nil { note.moved(to: target) }
        }
        if fm.fileExists(atPath: assetsFolder.path) {
            let newAssets = newFolder.appendingPathComponent("assets", isDirectory: true)
            try? fm.createDirectory(at: newAssets, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: assetsFolder, includingPropertiesForKeys: nil)) ?? [] {
                // A clashing image stays where it is rather than replacing a different one.
                let target = newAssets.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }
        folder = newFolder
        load()
    }

    // MARK: Images

    private var imageCache: [String: NSImage] = [:]
    /// Missing / failed images are retried after a while, not on every keystroke.
    private var imageFailures: [String: Date] = [:]
    private var pendingRemote: Set<String> = []
    private var restyleWork: DispatchWorkItem?

    private func loadImage(_ source: String) -> NSImage? {
        if let cached = imageCache[source] { return cached }
        if let failed = imageFailures[source], Date().timeIntervalSince(failed) < 30 { return nil }
        if let url = URL(string: source), let scheme = url.scheme, scheme.hasPrefix("http") {
            fetchRemote(url, key: source)
            return nil
        }
        let path = source.removingPercentEncoding ?? source
        let fileURL: URL
        if path.hasPrefix("file://"), let u = URL(string: source) {
            fileURL = u
        } else if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else if path.hasPrefix("~") {
            fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            fileURL = folder.appendingPathComponent(path)
        }
        guard let image = NSImage(contentsOf: fileURL) else {
            imageFailures[source] = Date()
            return nil
        }
        imageCache[source] = image
        return image
    }

    private func fetchRemote(_ url: URL, key: String) {
        guard !pendingRemote.contains(key) else { return }
        pendingRemote.insert(key)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingRemote.remove(key)
                if let image {
                    self.imageCache[key] = image
                    self.scheduleRestyle()
                } else {
                    self.imageFailures[key] = Date()
                }
            }
        }.resume()
    }

    /// Several images finishing together cause one restyle.
    private func scheduleRestyle() {
        restyleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restyleAll() }
        restyleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Saves pasted / dropped image data into assets/ and returns the Markdown-relative path.
    func storeImage(data: Data, fileExtension: String) -> String? {
        try? FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
        let name = "img-\(Stamp.compact.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased()).\(fileExtension)"
        do {
            try data.write(to: assetsFolder.appendingPathComponent(name))
            return "assets/\(name)"
        } catch {
            return nil
        }
    }
}
