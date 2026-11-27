import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Chat composer's text field: an NSTextView that takes images as attachments, not as text. A dropped image
/// file, a file promise (the screenshot thumbnail, drags out of Safari or Finder) or image data (copied in Preview),
/// dropped or pasted, goes to `onImages` as the Attachments button would send it; promised files are read the
/// moment they arrive, since the system's TemporaryItems folder they land in is cleared soon after. Anything else
/// (text, other files) is handled as a text view does, and a paste that carries text as well as a picture of it
/// (Numbers, Pages, Word) is text. Return sends; Shift- or Option-Return starts a new line; an input method's
/// Return confirms its candidate.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    /// Changes when the field should take the keyboard: on appearing, and when another chat is opened.
    var focus: Int
    var onSend: () -> Void
    var onImages: ([Data]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        // Promised files alongside what a text view takes already (file URLs, text, images).
        view.registerForDraggedTypes(view.registeredDraggedTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.tiff, .png, .fileURL])

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        if view.string != text { view.string = text }
        if context.coordinator.focused != focus {
            context.coordinator.focused = focus
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var focused = -1
        init(_ parent: ComposerEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerEditor.Coordinator?
    private let promises = OperationQueue()

    override func keyDown(with event: NSEvent) {
        // An input method composing text (Japanese, Chinese, Korean) takes Return to confirm its candidate; the
        // message is sent by the next Return, once nothing is marked.
        if hasMarkedText() { super.keyDown(with: event); return }
        // Return sends; with Shift or Option it is a new line, as in every chat app.
        if event.keyCode == 36 || event.keyCode == 76, !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
            coordinator?.parent.onSend()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Images in

    /// Takes the images off a pasteboard as attachments; false when there are none, so the caller can go on
    /// with text. With `textWins`, image data that comes with text is left alone: Numbers, Excel, Pages, Word and
    /// Keynote put a picture of the copied cells or paragraph next to the text, and the text is what a paste means.
    private func takeImages(from pasteboard: NSPasteboard, textWins: Bool = false) -> Bool {
        var images: [Data] = []
        // 1. Image files on disk (Finder, the Attachments panel's kind of drag).
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageFiles = urls.filter { url in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }
        images += imageFiles.compactMap(ChatStore.jpeg(from:))
        // 2. Image data (copied in Preview, dragged out of a page) when no file came with it.
        if images.isEmpty, urls.isEmpty, !(textWins && hasText(pasteboard)), pasteboard.canReadObject(forClasses: [NSImage.self]),
           let image = NSImage(pasteboard: pasteboard), let data = ChatStore.jpeg(from: image) {
            images.append(data)
        }
        // 3. Promised files: the screenshot thumbnail, Safari, Photos. They arrive in a moment, in a folder of ours.
        let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        let promised = receivers.filter { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }
        for receiver in promised { receive(receiver) }
        if !images.isEmpty { coordinator?.parent.onImages(images) }
        return !images.isEmpty || !promised.isEmpty
    }

    private func receive(_ receiver: NSFilePromiseReceiver) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nearloop-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promises) { [weak self] url, error in
            // Read at once: the file is ours only for a moment.
            let data = error == nil ? ChatStore.jpeg(from: url) : nil
            try? FileManager.default.removeItem(at: url)
            guard let data else { return }
            DispatchQueue.main.async { self?.coordinator?.parent.onImages([data]) }
        }
    }

    private func hasText(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains(where: { $0 == .string || $0 == .rtf || $0.rawValue == "public.utf8-plain-text" })
    }

    private func hasImages(_ pasteboard: NSPasteboard, textWins: Bool = false) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(where: { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) }) {
            let receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
            if receivers.contains(where: { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }) { return true }
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.contains(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) { return true }
        return urls.isEmpty && !(textWins && hasText(pasteboard)) && pasteboard.canReadObject(forClasses: [NSImage.self])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImages(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImages(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if hasImages(sender.draggingPasteboard), takeImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        // Text wins over a picture that comes with it; an image file or image data alone is attached.
        if hasImages(.general, textWins: true), takeImages(from: .general, textWins: true) { return }
        super.paste(sender)
    }
}
