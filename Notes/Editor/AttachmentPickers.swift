import SwiftUI
import PhotosUI
import SwiftData
import NotesCore
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
    #if os(iOS)
    @State private var showsCamera = false
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear { commands.requestAttachment = request }
            .photosPicker(isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await addPhotos(items) }
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): addFiles(urls)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                addFiles(files)
                return true
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { data in add(data: data, fileName: "Photo.jpg", type: .jpeg) }
                    .ignoresSafeArea()
            }
            #endif
            .alert(
                "Couldn’t Add Attachment",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
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
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                errorMessage = AttachmentError.unreadable.localizedDescription
                continue
            }
            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
            let fileExtension = type?.preferredFilenameExtension ?? "jpg"
            add(data: data, fileName: "Photo.\(fileExtension)", type: type ?? .jpeg)
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Check the size before reading, so a huge file is refused without loading it into memory.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            if let size = values?.fileSize, size > AttachmentLimits.maxFileBytes * 2 {
                errorMessage = AttachmentError.tooLarge.localizedDescription
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = AttachmentError.unreadable.localizedDescription
                continue
            }
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            add(data: data, fileName: url.lastPathComponent, type: type)
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

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

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
