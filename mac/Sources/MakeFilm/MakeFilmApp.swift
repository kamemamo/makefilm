import SwiftUI
import AppKit

@main
struct MakeFilmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var editor = Editor()

    var body: some Scene {
        Window("MakeFilm", id: "main") {
            ContentView(editor: editor)
                .frame(minWidth: 1100, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1360, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("素材を開く…") { editor.openPanel() }.keyboardShortcut("o")
                Button("書き出し…") { editor.openExport() }
                    .keyboardShortcut("e")
                    .disabled(!editor.canExport)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("取り消し") { editor.undo() }.keyboardShortcut("z")
                    .disabled(editor.undoStack.isEmpty)
                Button("やり直し") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(editor.redoStack.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` (no .app bundle) behave like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    let editor: Editor
    @State private var keyMonitor: Any?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(editor: editor)
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                FilmStripView(editor: editor)
                    .frame(width: 250)
                    .frame(maxHeight: .infinity)
                    .clipped()
                Divider().overlay(Theme.line)
                ViewerView(editor: editor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.line)
                MediaPanel(editor: editor)
                    .frame(width: 260)
            }
            Divider().overlay(Theme.line)
            TransportBar(editor: editor)
            Divider().overlay(Theme.line)
            TrimBinView(editor: editor)
                .frame(height: 260)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if let msg = editor.toastMessage {
                Text(msg)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x0C0E0C)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    .padding(.bottom, 340)   // just above the transport bar
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.black.opacity(0.35))
                    .overlay(Text("ドロップして素材に追加").foregroundStyle(Theme.accent))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let p = editor.exportProgress {
                ZStack {
                    Color.black.opacity(0.6)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("書き出し中…").fontWeight(.semibold)
                        ProgressView(value: p).tint(Theme.accent)
                        HStack {
                            Text("\(Int(p * 100))%").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("中止") { editor.cancelExport() }.buttonStyle(FilmButtonStyle())
                        }
                    }
                    .padding(20)
                    .frame(width: 340)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: editor.toastMessage)
        .sheet(isPresented: Binding(get: { editor.showExportSheet }, set: { editor.showExportSheet = $0 })) {
            ExportSheet(editor: editor)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mts"].contains($0.pathExtension.lowercased()) }
            editor.importURLs(videos)
            return !videos.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                editor.handleKey(e) ? nil : e
            }
            // Files passed on the command line open as source clips (handy for testing).
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let urls = args.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { editor.importURLs(urls) }
        }
    }
}
