import SwiftUI
import PhotosUI
import SwiftData
import RemarksCore
import UniformTypeIdentifiers

/// The ways to add an attachment to the open note: the photo library, the camera, files, and drag and drop.
/// The editor's toolbar (or keyboard bar) asks for a source through `EditorCommands`, and this shows the matching
/// picker, stores the result with `AttachmentStore`, and puts the Markdown at the caret.
struct AttachmentPickers: ViewModifier {
    let note: Note
    let commands: EditorCommands

    @Environment(\.modelContext) private var context
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    @State private var fileImportTask: Task<Void, Never>?
    #if os(iOS)
    @State private var showsCamera = false
    #endif

    private var canAcceptAttachments: Bool {
        !note.isDeleted && note.modelContext != nil && note.deletedAt == nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: commands.attachmentRequest) { _, source in
                guard let source else { return }
                commands.attachmentRequest = nil
                guard canAcceptAttachments else { return }
                request(source)
            }
            .onChange(of: commands.pastedFiles.count) {
                guard !commands.pastedFiles.isEmpty else { return }
                let files = commands.pastedFiles
                commands.pastedFiles = []
                guard canAcceptAttachments else { return }
                files.forEach { add(data: $0.data, fileName: $0.fileName, type: $0.type) }
            }
            .onChange(of: commands.pastedFileURLs.count) {
                guard !commands.pastedFileURLs.isEmpty else { return }
                let urls = commands.pastedFileURLs
                commands.pastedFileURLs = []
                guard canAcceptAttachments else { return }
                addFiles(urls)
            }
            .photosPicker(isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
            .task(id: photoItems) {
                let items = photoItems
                guard !items.isEmpty else { return }
                await addPhotos(items)
                if !Task.isCancelled { photoItems = [] }
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): addFiles(urls)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard canAcceptAttachments else { return false }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                addFiles(files)
                return true
            }
            .onChange(of: note.id) { _, _ in
                fileImportTask?.cancel()
                fileImportTask = nil
            }
            .onDisappear {
                fileImportTask?.cancel()
                fileImportTask = nil
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { data in add(data: data, fileName: "Photo.jpg", type: .jpeg) }
                    .ignoresSafeArea()
            }
            #endif
            .alert("Couldn’t Add Attachment", item: $errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private func request(_ source: AttachmentSource) {
        switch source {
        case .photoLibrary:
            showsPhotos = true
        case .file:
            showsFiles = true
        case .camera:
            #if os(iOS)
            showsCamera = true
            #endif
        }
    }

    // MARK: Adding

    private func add(data: Data, fileName: String, type: UTType?) {
        guard canAcceptAttachments else { return }
        do {
            let attachment = try AttachmentStore(context: context).add(
                data: data,
                fileName: fileName,
                typeIdentifier: (type ?? .data).identifier,
                to: note
            )
            commands.insertBlock(AttachmentStore.markdown(for: attachment))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    if !Task.isCancelled { errorMessage = AttachmentError.unreadable.localizedDescription }
                    continue
                }
                // A transfer may finish after cancellation; never insert into a different editor.
                try Task.checkCancellation()
                let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                let fileExtension = type?.preferredFilenameExtension ?? "jpg"
                add(data: data, fileName: "Photo.\(fileExtension)", type: type ?? .jpeg)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard canAcceptAttachments else { return }
        let targetNoteID = note.id
        fileImportTask?.cancel()
        fileImportTask = Task {
            for url in urls {
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(Data, String, UTType?), AttachmentError> in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                    // Check the size before reading, so a huge file is refused without loading it into memory.
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                    if let size = values?.fileSize, size > AttachmentLimits.maxFileBytes * 2 {
                        return .failure(.tooLarge)
                    }
                    guard let data = try? Data(contentsOf: url) else {
                        return .failure(.unreadable)
                    }
                    let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
                    return .success((data, url.lastPathComponent, type))
                }.value
                guard !Task.isCancelled, canAcceptAttachments, note.id == targetNoteID else { return }
                switch outcome {
                case .success(let (data, fileName, type)):
                    add(data: data, fileName: fileName, type: type)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

extension View {
    func attachmentPickers(for note: Note, commands: EditorCommands) -> some View {
        modifier(AttachmentPickers(note: note, commands: commands))
    }
}

#if os(iOS)
/// The system camera, as a full screen sheet.
private struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onPhoto(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
