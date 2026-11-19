import SwiftUI
import AppKit

@main
struct MakeFilmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var editor: Editor { appDelegate.editor }

    var body: some Scene {
        Window("MakeFilm", id: "main") {
            ContentView(editor: editor)
                .frame(minWidth: 1100, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1360, height: 920)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("新規プロジェクト")) { editor.newProject() }.keyboardShortcut("n")
                Button(L("プロジェクトを開く…")) { editor.openProjectPanel() }.keyboardShortcut("o")
                Menu(L("最近使ったプロジェクト")) {
                    ForEach(editor.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            Task { await editor.openProject(url, confirmed: false) }
                        }
                    }
                    Divider()
                    Button(L("履歴を消去")) { editor.clearRecents() }
                }
                .disabled(editor.recentProjects.isEmpty)
                Divider()
                Button(L("素材を読み込む…")) { editor.openPanel() }.keyboardShortcut("i")
                Button(L("書き出し…")) { editor.openExport() }
                    .keyboardShortcut("e")
                    .disabled(!editor.canExport)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("保存")) { editor.saveProject() }.keyboardShortcut("s")
                Button(L("別名で保存…")) { editor.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L("取り消し")) { editor.undo() }.keyboardShortcut("z")
                    .disabled(editor.undoStack.isEmpty)
                Button(L("やり直し")) { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(editor.redoStack.isEmpty)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = Editor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` (no .app bundle) behave like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Ask about unsaved changes before quitting (also covers closing the window).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor.confirmDiscardIfNeeded() ? .terminateNow : .terminateCancel
    }

    /// Finder double-click / drop on the Dock icon / file arguments.
    func application(_ application: NSApplication, open urls: [URL]) {
        editor.openFiles(urls)
    }
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
                    .overlay(Text(L("ドロップして開く（動画は素材に、.makefilm はプロジェクトとして）")).foregroundStyle(Theme.accent))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let p = editor.exportProgress {
                ZStack {
                    Color.black.opacity(0.6)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("書き出し中…")).fontWeight(.semibold)
                        ProgressView(value: p).tint(Theme.accent)
                        HStack {
                            Text("\(Int(p * 100))%").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button(L("中止")) { editor.cancelExport() }.buttonStyle(FilmButtonStyle())
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
        .navigationTitle(editor.windowTitle)
        .dropDestination(for: URL.self) { urls, _ in
            editor.openFiles(urls)
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                editor.handleKey(e) ? nil : e
            }
            // Files passed on the command line (handy for testing); otherwise reopen the last project.
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let urls = args.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { editor.openFiles(urls) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { editor.reopenLastProjectIfAny() }
        }
    }
}
