import AppKit
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    var onChangeFolder: (URL) -> Void

    var body: some View {
        Form {
            Section("Summon") {
                KeyboardShortcuts.Recorder("Show / Hide", name: .toggleNote)
                Toggle("Four-finger swipe down", isOn: $prefs.gestureEnabled)
            }

            Section("Appearance") {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Glow while focused", isOn: $prefs.focusGlow)
                LabeledContent("Opacity") {
                    HStack {
                        Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                        Slider(value: $prefs.opacity, in: 0...1)
                        Image(systemName: "circle.fill").foregroundStyle(.secondary)
                    }
                }
                Picker("Font", selection: $prefs.fontFamily) {
                    ForEach(FontFamily.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Text Size") {
                    HStack {
                        Slider(value: $prefs.fontSize, in: Preferences.fontSizeRange, step: 1)
                        Text("\(Int(prefs.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Notes Folder") {
                    HStack(spacing: 8) {
                        Text(displayPath(prefs.notesFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(prefs.notesFolder.path)
                        Button("Change…", action: chooseFolder)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([prefs.notesFolder])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")
                    }
                }
            }

            Section {
                LaunchAtLogin.Toggle("Launch at login")
                Toggle("Show in menu bar", isOn: $prefs.showMenuBarIcon)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where notes (.md) and images are stored. Existing notes will be moved there."
        panel.directoryURL = prefs.notesFolder
        // A sheet on the Settings window: it gets the keyboard like Settings does, without activating the app.
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            onChangeFolder(url)
        }
    }
}
