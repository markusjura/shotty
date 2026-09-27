import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Editable reviews, one window per recognition. Reopening a result raises its window with
/// any edits intact; a newer result opens beside it instead of replacing unsaved edits.
@MainActor
final class TextReviewWindow {
    private var windows: [Date: (window: NSWindow, observer: NSObjectProtocol)] = [:]

    /// `createdAt` identifies the recognition.
    func show(_ result: RecognizedTextResult, settings: CaptureOutputSnapshot, createdAt: Date, clipboard: ClipboardWriter) {
        NSApp.activate()
        if let existing = windows[createdAt]?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Recognized Text"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 420, height: 280)
        let model = TextReviewModel(result: result, preservesLineBreaks: settings.text.preservesLineBreaks)
        window.contentView = NSHostingView(rootView: TextReviewView(model: model, settings: settings, createdAt: createdAt,
                                                                    clipboard: clipboard) { [weak window] in window?.close() })
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(createdAt) }
        }
        windows[createdAt] = (window, observer)
        if let frontmost = windows.values.map(\.window).first(where: { $0 !== window && $0.isVisible }) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: CGPoint(x: frontmost.frame.minX, y: frontmost.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        for entry in windows.values { entry.window.close() }
    }

    private func forget(_ createdAt: Date) {
        if let observer = windows.removeValue(forKey: createdAt)?.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor @Observable
private final class TextReviewModel {
    let result: RecognizedTextResult
    var text: String
    /// The last text generated from the recognition, before any user edits.
    private var generated: String
    var preservesLineBreaks: Bool {
        didSet {
            guard !isEdited else { return }
            generated = result.text(preservingLineBreaks: preservesLineBreaks)
            text = generated
        }
    }
    var status: String?

    /// Regenerating text would discard edits, so the line-break choice locks after editing.
    var isEdited: Bool { text != generated }

    init(result: RecognizedTextResult, preservesLineBreaks: Bool) {
        let initialText = result.text(preservingLineBreaks: preservesLineBreaks)
        self.result = result
        generated = initialText
        text = initialText
        self.preservesLineBreaks = preservesLineBreaks
    }
}

private struct TextReviewView: View {
    @Bindable var model: TextReviewModel
    let settings: CaptureOutputSnapshot
    let createdAt: Date
    let clipboard: ClipboardWriter
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $model.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Recognized text")
            let uncertain = model.result.lowConfidenceLines
            if !uncertain.isEmpty {
                Text("Check \(uncertain.count == 1 ? "this line" : "these \(uncertain.count) lines"); recognition was uncertain: "
                     + uncertain.prefix(3).map { "“\($0.text)”" }.joined(separator: ", ") + (uncertain.count > 3 ? "…" : ""))
                    .secondaryNote().lineLimit(3)
            }
            HStack {
                Toggle("Keep line breaks", isOn: $model.preservesLineBreaks)
                    .disabled(model.isEdited)
                    .help(model.isEdited ? "Line breaks can't change after editing." : "Join lines that wrap within a paragraph.")
                if let status = model.status { Text(status).secondaryNote() }
                Spacer()
                Button("Save…", action: save)
                Button("Copy", action: copy).keyboardShortcut("c", modifiers: [.shift, .command])
                    .buttonStyle(.borderedProminent)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }

    /// An explicit Copy always replaces the clipboard.
    private func copy() {
        model.status = clipboard.write(model.text, ticket: clipboard.begin()) ? "Copied" : "Couldn't copy"
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.nameFieldStringValue = ExportService.filenameStem(date: createdAt) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The panel has already confirmed replacement of an existing file.
            try AtomicFile.write(Data(model.text.utf8), to: url, replacing: true)
            model.status = "Saved \(url.lastPathComponent)"
        } catch {
            model.status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
