import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

/// The topic remains fixed while composing. No new subscription or credential is created.
@MainActor
final class ComposeModel: ObservableObject {
    @Published var message = ""
    @Published var title = ""
    @Published var tags = ""
    @Published var priority = 3
    @Published var clickURL = ""
    @Published var attachmentURL = ""
    @Published var delay = ""
    @Published var markdown = false
    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var attachmentLimit: Int64?
    @Published var loadingLimits = false
    @Published var busy = false
    @Published var error = ""
    private var lastAttempt = ""
    private var closed = false
    private var limitGeneration = UUID()

    var options: PublishOptions {
        PublishOptions(clickURL: clickURL.trimmingCharacters(in: .whitespacesAndNewlines),
            attachmentURL: attachmentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            filename: fileName, delay: delay.trimmingCharacters(in: .whitespacesAndNewlines),
            markdown: markdown, fileURL: fileURL, attachmentLimit: attachmentLimit)
    }
    var canSend: Bool { !busy && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.hasAttachment) }
    var dirty: Bool { !message.isEmpty || !title.isEmpty || !tags.isEmpty || !clickURL.isEmpty || options.hasAttachment || !delay.isEmpty || markdown || priority != 3 }

    func loadLimits(baseURL: String, user: ServerCredential?) {
        guard let url = URL(string: normalizeBaseUrl(baseURL) + "/v1/account") else { return }
        let generation = UUID()
        limitGeneration = generation
        attachmentLimit = nil
        loadingLimits = true
        let api = ApiService.shared
        let request = api.newRequest(url: url, baseUrl: baseURL, user: user)
        api.runOneShot(request, timeout: 10, baseUrl: baseURL) { data, response, networkError in
            DispatchQueue.main.async {
                guard self.limitGeneration == generation, !self.closed else { return }
                self.loadingLimits = false
                guard networkError == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data, let limit = PublishOptions.attachmentLimit(from: data) else {
                    self.attachmentLimit = nil
                    return
                }
                self.attachmentLimit = limit
            }
        }
    }

    /// Copy provider-owned files before their security scope or load callback expires.
    nonisolated static func stage(_ source: URL, limit: Int64) throws -> URL {
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count > 0, Int64(count) <= limit else {
            throw ApiService.PublishError.attachmentTooLarge
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compose-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return destination
    }

    /// A photo (picked or shared) is staged like any file, then sent in a format every reader
    /// handles; see `OutgoingImage`. The limit applies to what is actually sent.
    nonisolated static func stageImage(_ source: URL, limit: Int64) throws -> URL {
        let staged = try stage(source, limit: Int64.max)
        let prepared = OutgoingImage.prepare(staged)
        let size = (try? prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0, size <= limit else {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            throw ApiService.PublishError.attachmentTooLarge
        }
        return prepared
    }

    func selectFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure: error = String(localized: "The file could not be opened. Choose it again.")
        case .success(let source):
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard let limit = attachmentLimit else { return }
            do { acceptFile(try Self.stage(source, limit: limit)) }
            catch { self.error = (error as? ApiService.PublishError)?.userMessage ?? String(localized: "The file could not be opened. Choose it again.") }
        }
    }

    func acceptFile(_ url: URL) {
        guard !closed else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return
        }
        removeFile()
        fileURL = url
        fileName = url.lastPathComponent
        attachmentURL = ""
        error = ""
    }
    func close() {
        closed = true
        removeFile()
    }
    func removeFile() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        fileURL = nil
        fileName = ""
    }

    func send(subscription: Subscription, store: Store, completion: @escaping () -> Void) {
        guard canSend else { return }
        let baseURL = subscription.baseUrl ?? ""
        let fingerprint = "\(subscription.urlString())|\(message)|\(title)|\(tags)|\(priority)|\(clickURL)|\(attachmentURL)|\(delay)|\(markdown)|\(fileURL?.absoluteString ?? "")"
        if !lastAttempt.isEmpty && fingerprint != lastAttempt {
            ServerCooldown.shared.requestChanged(server: baseURL, kind: .publish)
        }
        lastAttempt = fingerprint
        busy = true
        error = ""
        TopicPublisher.send(subscription: subscription, store: store, message: message, title: title,
            priority: priority, tags: tags, options: options) { result in
                self.busy = false
                switch result {
                case .success:
                    self.removeFile()
                    completion()
                case .failure(let failure):
                    self.error = failure.message
                }
            }
    }
}

/// What a photo the person sends goes out as (1.32). The reader is often an AI agent, and agents
/// read PNG, JPEG, GIF and WebP but not HEIC, the iPhone camera's format; other ntfy clients differ
/// too. Those four formats go unchanged, so a screenshot keeps every pixel. Anything else that
/// decodes as an image becomes a JPEG, at most `maxPixelSize` on its longest side, oriented as
/// shown in Photos. Re-encoding also drops the camera's metadata, location included. A photo that
/// goes unchanged loses only its location, rewritten without decoding the pixels.
enum OutgoingImage {
    static let maxPixelSize = 4096
    static let jpegQuality = 0.85
    private static let unchanged: [UTType] = [.png, .jpeg, .gif, .webP]

    /// The file to send: `staged` itself, or a JPEG written in its place (`staged` is then removed).
    /// A JPEG goes as it is unless it is stored sideways (an iPhone set to "Most Compatible" writes
    /// portrait photos that way): a reader that ignores the orientation tag would see it turned.
    /// Anything that fails to convert is sent as it was.
    static func prepare(_ staged: URL) -> URL {
        guard let source = CGImageSourceCreateWithURL(staged as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image) else { return staged }
        if unchanged.contains(where: { type.conforms(to: $0) }) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if !(type.conforms(to: .jpeg) && orientation != 1) {
                // Nobody expects their home coordinates to ride along to a server and an agent.
                guard properties?[kCGImagePropertyGPSDictionary] != nil else { return staged }
                if removeLocation(staged, source: source, type: type) { return staged }
                // A format ImageIO can't rewrite in place goes as a JPEG, which carries no location.
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return staged }
        let written = staged.deletingLastPathComponent().appendingPathComponent(".upright-\(UUID().uuidString).jpg")
        guard let output = CGImageDestinationCreateWithURL(written as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return staged
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: written)
            return staged
        }
        let destination = staged.deletingPathExtension().appendingPathExtension("jpg")
        do {
            try FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: written, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: written)
            return staged
        }
        return destination
    }

    /// Rewrites `staged` in place without its GPS dictionary. The image data is copied, not
    /// re-encoded, so the pixels, the orientation tag and the rest of the metadata stay as they were.
    private static func removeLocation(_ staged: URL, source: CGImageSource, type: UTType) -> Bool {
        let written = staged.deletingLastPathComponent()
            .appendingPathComponent(".nolocation-\(UUID().uuidString).\(staged.pathExtension)")
        guard let output = CGImageDestinationCreateWithURL(written as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        let options = [kCGImagePropertyGPSDictionary: kCFNull] as CFDictionary
        guard CGImageDestinationCopyImageSource(output, source, options, nil),
              let check = CGImageSourceCreateWithURL(written as CFURL, nil),
              (CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary] == nil,
              (try? FileManager.default.replaceItemAt(staged, withItemAt: written)) != nil else {
            try? FileManager.default.removeItem(at: written)
            return false
        }
        return true
    }
}
