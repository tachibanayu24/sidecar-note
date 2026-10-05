import AppKit

/// Dev builds only (`SidecarNoteDev.selftest`): exercises the editor, styler and store in-process — no windows,
/// keyboard or focus involved — and appends PASS / FAIL lines to /tmp/sidecar-dev.log.
@MainActor
enum DevSelfTest {
    private static var failures = 0

    static func run() {
        failures = 0
        log("---- self-test \(Date())")
        syntaxFollowsCaret()
        listEditing()
        tasks()
        sourceMapCalibration()
        listRendering()
        closeAndReopen()
        blankNotesAreDiscarded()
        legacyEncodingIsKept()
        // Some checks run on the next runloop turn (after deferred restyles); report once they're in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        }
    }

    // MARK: Cases

    private static func syntaxFollowsCaret() {
        let editor = EditorController(text: "a **b** c\nnext line", styler: styler())
        editor.textView.setSelectedRange(NSRange(location: 14, length: 0))   // caret on line 2
        check("syntax hidden off the caret line", fontSize(editor, at: 2) < 1)
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))    // caret on line 1
        check("syntax shown on the caret line", fontSize(editor, at: 2) > 1)
        editor.textView.setSelectedRange(NSRange(location: 14, length: 0))
        check("syntax hidden again after leaving", fontSize(editor, at: 2) < 1)
        check("bold text itself never hidden", fontSize(editor, at: 4) > 1)

        // Wherever the caret starts, its line shows syntax from the first frame.
        let fresh = EditorController(text: "**x**\n**more**", styler: styler())
        let caret = fresh.textView.selectedRange().location
        let caretLine = (fresh.text as NSString).lineRange(for: NSRange(location: min(caret, fresh.text.utf16.count), length: 0))
        let otherLine = caretLine.location == 0 ? 6 : 0
        log("(fresh editor caret at \(caret))")
        check("syntax visible on the caret line right after opening", fontSize(fresh, at: caretLine.location) > 1)
        check("and hidden on the other line", fontSize(fresh, at: otherLine) < 1)

        // An edit away from the caret (like a checkbox click) must not leave syntax shown on the lines between.
        let far = EditorController(text: "**a**\nb\n**c** [ ] x", styler: styler())
        far.textView.setSelectedRange(NSRange(location: 1, length: 0))
        let tv = far.textView
        let box = (far.text as NSString).range(of: " ]").location
        if tv.shouldChangeText(in: NSRange(location: box, length: 1), replacementString: "x") {
            tv.textStorage?.replaceCharacters(in: NSRange(location: box, length: 1), with: "x")
            tv.didChangeText()
        }
        DispatchQueue.main.async {
            let c = (far.text as NSString).range(of: "**c").location
            check("edit away from the caret keeps other lines' syntax hidden", fontSize(far, at: c) < 1)
            check("caret line keeps its syntax", fontSize(far, at: 0) > 1)
        }
    }

    private static func listEditing() {
        let editor = EditorController(text: "- item", styler: styler())
        let tv = editor.textView
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertNewline(nil)
        check("Return continues a list", editor.text == "- item\n- ")
        tv.insertNewline(nil)
        check("Return on an empty item ends the list", editor.text == "- item\n")

        let indent = EditorController(text: "- a\n- b\n- c", styler: styler())
        indent.textView.setSelectedRange(NSRange(location: 4, length: 7))
        indent.textView.insertTab(nil)
        check("Tab nests every selected item under the one above", indent.text == "- a\n  - b\n  - c")
        check("selection follows the indent", indent.textView.selectedRange() == NSRange(location: 6, length: 9))
        indent.textView.insertBacktab(nil)
        check("⇧Tab outdents", indent.text == "- a\n- b\n- c")

        let firstItem = EditorController(text: "- a\n- b", styler: styler())
        firstItem.textView.setSelectedRange(NSRange(location: 3, length: 0))
        firstItem.textView.insertTab(nil)
        check("the first item has nothing to nest under", firstItem.text == "- a\n- b")

        let children = EditorController(text: "- a\n- b\n  - c\n- d", styler: styler())
        children.textView.setSelectedRange(NSRange(location: 7, length: 0))
        children.textView.insertTab(nil)
        check("Tab takes the item's children along", children.text == "- a\n  - b\n    - c\n- d")
        check("caret stays after the text", children.textView.selectedRange().location == 9)
        children.textView.insertBacktab(nil)
        check("⇧Tab brings them back", children.text == "- a\n- b\n  - c\n- d")

        let numbered = EditorController(text: "1. a\n2. b", styler: styler())
        numbered.textView.setSelectedRange(NSRange(location: 10, length: 0))
        numbered.textView.insertTab(nil)
        check("Tab nests a numbered item under the text and restarts at 1", numbered.text == "1. a\n   1. b")
        numbered.textView.insertBacktab(nil)
        check("⇧Tab continues the outer numbering", numbered.text == "1. a\n2. b")

        let emptyNested = EditorController(text: "- a\n  - b", styler: styler())
        emptyNested.textView.setSelectedRange(NSRange(location: 10, length: 0))
        emptyNested.textView.insertNewline(nil)
        check("Return continues a nested list", emptyNested.text == "- a\n  - b\n  - ")
        emptyNested.textView.insertNewline(nil)
        check("Return on an empty nested item outdents it", emptyNested.text == "- a\n  - b\n- ")

        let ordered = EditorController(text: "1. one", styler: styler())
        ordered.textView.setSelectedRange(NSRange(location: 6, length: 0))
        ordered.textView.insertNewline(nil)
        check("Return numbers the next item", ordered.text == "1. one\n2. ")
    }

    private static func tasks() {
        let editor = EditorController(text: "hello", styler: styler())
        let tv = editor.textView
        // Real key presses are separate events, each its own undo group; reproduce that here.
        let undo = editor.undoManager(for: tv)
        undo?.groupsByEvent = false
        func step(_ action: () -> Void) {
            undo?.beginUndoGrouping()
            action()
            undo?.endUndoGrouping()
        }
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        step { tv.toggleTask(nil) }
        check("⌘↩ turns a line into a task", editor.text == "- [ ] hello")
        step { tv.toggleTask(nil) }
        check("⌘↩ checks the task", editor.text == "- [x] hello")
        undo?.undo()
        check("undo reverts one ⌘↩", editor.text == "- [ ] hello")

        let quote = EditorController(text: "> note", styler: styler())
        quote.textView.setSelectedRange(NSRange(location: 6, length: 0))
        quote.textView.toggleTask(nil)
        check("⌘↩ on a quote", quote.text == "> - [ ] note")

        let bold = EditorController(text: "**word**", styler: styler())
        bold.textView.setSelectedRange(NSRange(location: 2, length: 4))
        bold.textView.toggleItalic(nil)
        check("⌘I inside bold adds italics instead of breaking it", bold.text == "***word***")
    }

    private static func sourceMapCalibration() {
        // A lazy continuation line with an escape: bold / code must land on the right characters.
        let text = "- a\nx **b** \\* `d`"
        let out = styler().render(text)
        let ns = text as NSString
        let b = ns.range(of: "b", options: .backwards).location
        let d = ns.range(of: "d").location
        let boldFont = out.attribute(.font, at: b, effectiveRange: nil) as? NSFont
        check("bold on a continuation line", boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        check("inline code on a continuation line", out.attribute(.mdInlineCode, at: d, effectiveRange: nil) != nil)
        let emoji = styler().render("😀 **x**")
        let x = ("😀 **x**" as NSString).range(of: "x").location
        let emojiFont = emoji.attribute(.font, at: x, effectiveRange: nil) as? NSFont
        check("bold after an emoji (surrogate pair)", emojiFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    private static func listRendering() {
        let s = styler()
        func font(_ text: String, at index: Int) -> CGFloat {
            (s.render(text).attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        func indent(_ text: String, line: Int) -> CGFloat {
            let ns = text as NSString
            let start = ns.lineRanges(in: NSRange(location: 0, length: ns.length))[line].location
            return (s.render(text).attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?
                .firstLineHeadIndent ?? -1
        }
        // "- a\n  - " in CommonMark is a setext heading "a"; while typing a list it must stay an item.
        check("an empty nested item doesn't turn the line above into a heading", font("- a\n  - ", at: 2) == s.size)
        check("nor does a lone marker under a paragraph", font("text\n- ", at: 0) == s.size)
        check("a lone marker under a paragraph is a list item", s.render("text\n- ").attribute(.mdBullet, at: 5, effectiveRange: nil) != nil)
        check("the empty nested item is drawn as a nested bullet", indent("- a\n  - ", line: 1) > 0)
        check("a nested item numbered 2 still nests", indent("1. a\n   2. b", line: 1) > 0)
        let one = indent("- a\n  - b\n    - c", line: 1), two = indent("- a\n  - b\n    - c", line: 2)
        check("nesting is indented by a full step per level", one >= s.size * 1.4 && abs(two - one * 2) < 0.5)
        check("top-level items aren't indented", indent("- a\n  - b", line: 0) == 0)
        let wrapped = "- a\n  - b\n    more"
        check("an item's continuation lines align with its text", indent(wrapped, line: 2) > indent(wrapped, line: 1))
        check("setext headings still work", font("Title\n===", at: 0) > s.size)
    }

    private static func closeAndReopen() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("alpha", to: folder.appendingPathComponent("A.md"))
        write("beta", to: folder.appendingPathComponent("B.md"))
        let store = NoteStore(folder: folder)
        guard store.notes.count == 2, let a = store.notes.first(where: { $0.fileName == "A.md" }),
              let b = store.notes.first(where: { $0.fileName == "B.md" }) else {
            check("store loads notes", false)
            return
        }
        let result = store.close(a)
        check("close sends the file to the Trash", result == .reopenable && !exists(a.url))
        check("⌘Z can reopen after closing", store.canReopen)
        store.reopenLastClosed()
        check("reopen restores the note and its file", store.notes.contains { $0 === a } && exists(a.url)
            && store.selected === a)

        _ = store.close(a)
        let trashed = store.debugLastTrashedURL
        b.editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        b.editor.textView.insertText("!", replacementRange: NSRange(location: 4, length: 0))
        check("editing any note makes ⌘Z undo text again", !store.canReopen)
        if let trashed { try? FileManager.default.removeItem(at: trashed) }   // don't leave test files in the Trash

        // ⌘W → ⌘T → ⌘Z: the reopened note replaces the blank one instead of leaving an "Untitled" tab.
        write("gamma", to: folder.appendingPathComponent("C.md"))
        let store2 = NoteStore(folder: folder)
        guard let c = store2.notes.first(where: { $0.fileName == "C.md" }) else { return }
        _ = store2.close(c)
        let cTrashed = store2.debugLastTrashedURL
        let blank = store2.newNote()
        // Another file took C's name meanwhile: the reopened note must not overwrite it.
        write("other", to: c.url)
        store2.reopenLastClosed()
        check("reopen drops the blank note that was selected", !store2.notes.contains { $0 === blank })
        let other = try? String(contentsOf: folder.appendingPathComponent("C.md"), encoding: .utf8)
        check("reopen never overwrites a file that took the name", other == "other" && exists(c.url) && c.url.lastPathComponent != "C.md")
        _ = cTrashed
    }

    private static func blankNotesAreDiscarded() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        write("keep", to: folder.appendingPathComponent("K.md"))
        let store = NoteStore(folder: folder)
        guard let keep = store.notes.first else { return }
        let blank = store.newNote()
        check("new note is selected", store.selected === blank && store.notes.count == 2)
        store.select(keep)
        check("leaving a blank note discards it", store.notes.count == 1 && !store.notes.contains { $0 === blank })
        let blank2 = store.newNote()
        store.discardSelectedIfBlank()
        check("hiding with a blank note discards it", !store.notes.contains { $0 === blank2 } && store.selected === keep)
    }

    private static func legacyEncodingIsKept() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("S.md")
        try? "日本語のメモ".data(using: .shiftJIS)?.write(to: url)
        let store = NoteStore(folder: folder)
        guard let note = store.notes.first else {
            check("Shift_JIS note loads", false)
            return
        }
        check("Shift_JIS note loads", note.editor.text == "日本語のメモ")
        note.editor.textView.insertText("です", replacementRange: NSRange(location: 6, length: 0))
        note.save()
        let data = (try? Data(contentsOf: url)) ?? Data()
        check("saved back as Shift_JIS", String(data: data, encoding: .shiftJIS) == "日本語のメモです"
            && String(data: data, encoding: .utf8) == nil)
    }

    // MARK: Helpers

    private static func styler() -> MarkdownStyler { MarkdownStyler() }

    private static func fontSize(_ editor: EditorController, at index: Int) -> CGFloat {
        (editor.storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    private static func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL") \(name)")
    }

    private static func log(_ message: String) {
        DevLog.write("[selftest] " + message)
    }
}
