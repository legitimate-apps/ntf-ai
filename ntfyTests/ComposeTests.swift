// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import XCTest
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SwiftUI
import UIKit
@testable import ntfy

final class ComposeTests: XCTestCase {
    private let base = "https://compose.invalid"
    private var store: Store { Store.shared }
    private func topic() -> Subscription { store.saveSubscription(baseUrl: base, topic: "compose-" + UUID().uuidString) }
    private func build(_ options: PublishOptions, message: String = "Note", key: Data? = nil,
                       api: ApiService = ApiService(), user: ServerCredential? = nil) throws -> URLRequest {
        try api.buildPublishRequest(subscription: topic(), user: user, message: message, title: "Hello",
            priority: 5, tags: ["note", "memo"], options: options, encryptionKey: key).get()
    }

    func testMetadataHeadersAndMessageBody() throws {
        let r = try build(PublishOptions(clickURL: "https://example.org/note", attachmentURL: "https://example.org/photo.jpg", delay: "30m", markdown: true))
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Click"), "https://example.org/note")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Attach"), "https://example.org/photo.jpg")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Delay"), "30m")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Markdown"), "yes")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Title"), "Hello")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Tags"), "note,memo")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Priority"), "5")
        XCTAssertEqual(r.httpBody, Data("Note".utf8))
    }

    func testUploadUsesExactRawBytesAndSeparateCaptionEvenForSmallTextFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let data = Data("small file, not the caption".utf8)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let r = try build(PublishOptions(filename: "note.txt", fileURL: url, attachmentLimit: 100), message: "Line 1\nLine 2")
        XCTAssertEqual(r.httpBody, data)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Filename"), "note.txt")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Message"), "Line 1\\nLine 2")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
    }

    func testPhotoUploadWithoutCaptionDoesNotReplaceImageWithText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let bytes = Data([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0xff, 0xd9])
        try bytes.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let r = try build(PublishOptions(filename: "photo.jpg", fileURL: url, attachmentLimit: 100), message: "")
        XCTAssertEqual(r.httpBody, bytes)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Filename"), "photo.jpg")
    }

    func testUploadRequiresReportedLimitAndEnforcesActualSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: 20).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try build(PublishOptions(filename: "data.bin", fileURL: url)))
        XCTAssertThrowsError(try build(PublishOptions(filename: "data.bin", fileURL: url, attachmentLimit: 19)))
        XCTAssertNoThrow(try build(PublishOptions(filename: "data.bin", fileURL: url, attachmentLimit: 20)))
    }

    func testRefusesConflictingAttachmentsAndUnsafeURLs() throws {
        XCTAssertThrowsError(try build(PublishOptions(clickURL: "javascript:alert(1)")))
        XCTAssertThrowsError(try build(PublishOptions(attachmentURL: "https://user:secret@example.org/a")))
        XCTAssertThrowsError(try build(PublishOptions(delay: "30m\r\nEmail: other@example.org")))
        XCTAssertThrowsError(try build(PublishOptions(attachmentURL: "https://example.org/a", fileURL: URL(fileURLWithPath: "/nonexistent"), attachmentLimit: 100)))
    }

    func testEncryptedClickAndMarkdownStayInsideCiphertextAndFilesAreRefused() throws {
        let key = Data(repeating: 9, count: 32)
        let r = try build(PublishOptions(clickURL: "https://example.org/private", delay: "1h", markdown: true), key: key)
        XCTAssertNil(r.value(forHTTPHeaderField: "Click"))
        XCTAssertNil(r.value(forHTTPHeaderField: "Markdown"))
        XCTAssertNil(r.value(forHTTPHeaderField: "Title"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "Delay"), "1h")
        let payload = try TopicEncryption.decryptPayload(String(decoding: r.httpBody!, as: UTF8.self), key: key)
        XCTAssertEqual(payload.click, "https://example.org/private")
        XCTAssertEqual(payload.markdown, true)
        XCTAssertThrowsError(try build(PublishOptions(attachmentURL: "https://example.org/a"), key: key))
    }

    func testBasicBearerAndExplicitCustomAuthorizationSurvive() throws {
        let credentials = InMemoryCredentialStore()
        credentials.setHTTPHeaders(["X-Proxy-Key": "test-only"], baseUrl: base)
        let api = ApiService(credentialStore: credentials)
        for user in [ServerCredential.basic(username: "u", password: "p"), .accessToken("tk_test")] {
            let r = try build(PublishOptions(clickURL: "https://example.org/a"), api: api, user: user)
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), user.toHeader())
            XCTAssertEqual(r.value(forHTTPHeaderField: "X-Proxy-Key"), "test-only")
        }
        credentials.setHTTPHeaders(["Authorization": "Bearer custom", "X-Proxy-Key": "test-only"], baseUrl: base)
        XCTAssertEqual(try build(PublishOptions(), api: api, user: .accessToken("tk_saved")).value(forHTTPHeaderField: "Authorization"), "Bearer custom")
    }

    func testUnicodeAndMultilineMetadataAreEncodedWithoutHeaderInjection() throws {
        let r = try ApiService().buildPublishRequest(subscription: topic(), user: nil, message: "body", title: "Hola 🌍\nTitle", tags: ["🐱"], options: PublishOptions()).get()
        XCTAssertEqual(r.value(forHTTPHeaderField: "Title"), PublishOptions.header("Hola 🌍\nTitle"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "Tags"), PublishOptions.header("🐱"))
    }

    func testAccountLimitsUseTierAndRemainingStorageIncludingZero() {
        XCTAssertEqual(PublishOptions.attachmentLimit(from: Data(#"{"limits":{"attachment_file_size":150},"stats":{"attachment_total_size_remaining":90}}"#.utf8)), 90)
        XCTAssertEqual(PublishOptions.attachmentLimit(from: Data(#"{"limits":{"attachment_file_size":150},"stats":{"attachment_total_size_remaining":0}}"#.utf8)), 0)
        XCTAssertNil(PublishOptions.attachmentLimit(from: Data(#"{"limits":{"attachment_file_size":0}}"#.utf8)))
        XCTAssertNil(PublishOptions.attachmentLimit(from: Data("{}".utf8)))
    }

    func testActivePublishBudgetPreventsAnyNetworkRequestAndDoesNotBlockReads() {
        let cooldown = ServerCooldown(defaults: nil)
        cooldown.limit(server: base, retryAfter: "72000", condition: "time", kind: .publish)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [ComposeProtocol.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        ComposeProtocol.count = 0
        let done = expectation(description: "refused before network")
        ApiService().publish(subscription: topic(), user: nil, message: "note", title: "", session: session, cooldown: cooldown,
            completionHandler: { XCTFail("Must respect publish budget"); done.fulfill() }, failureHandler: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(ComposeProtocol.count, 0)
        XCTAssertTrue(cooldown.claim(server: base, manual: false, kind: .poll))
    }

    func testStock429WithoutConditionalHeaderInstallsPublishWait() {
        let cooldown = ServerCooldown(defaults: nil)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [ComposeProtocol.self]
        let session = URLSession(configuration: cfg); defer { session.invalidateAndCancel() }
        ComposeProtocol.status = 429; defer { ComposeProtocol.status = 200 }
        let done = expectation(description: "stock refusal")
        ApiService().publish(subscription: topic(), user: nil, message: "note", title: "", session: session, cooldown: cooldown,
            failureHandler: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertFalse(cooldown.claim(server: base, manual: false, kind: .publish))
        XCTAssertGreaterThan(cooldown.deadline(for: base, kind: .publish).timeIntervalSinceNow, 59)
    }
}

private final class ComposeProtocol: URLProtocol {
    static var count = 0
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Retry-After": "60"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ComposeTests {
    func testNativeStockTextAndPhotoArriveWithTheirMetadataAndExactBytes() throws {
        guard let base = ProcessInfo.processInfo.environment["COMPOSE_STOCK_URL"] else {
            throw XCTSkip("Opt in with COMPOSE_STOCK_URL for the loopback stock server")
        }
        XCTAssertTrue(base.hasPrefix("http://127.0.0.1:"))
        let topic = Store.shared.saveSubscription(baseUrl: base, topic: "compose-native-" + UUID().uuidString.lowercased())
        let api = ApiService()
        func send(_ text: String, title: String, options: PublishOptions) {
            let done = expectation(description: "real publish")
            api.publish(subscription: topic, user: nil, message: text, title: title, priority: 4, tags: ["memo", "🐱"], options: options,
                cooldown: ServerCooldown(defaults: nil), completionHandler: { done.fulfill() }, failureHandler: { error in
                    XCTFail(error.userMessage); done.fulfill()
                })
            wait(for: [done], timeout: 15)
        }
        send("**A note**\nfrom iOS", title: "Hola 🌍", options: PublishOptions(clickURL: "https://example.org/note", markdown: true))
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("compose-native-photo.jpg")
        // A deterministic image fixture still goes through the exact raw file upload path.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["COMPOSE_PHOTO_PATH"])))
        try bytes.write(to: photo); defer { try? FileManager.default.removeItem(at: photo) }
        let account = expectation(description: "server allowance")
        var limit: Int64?
        api.runOneShot(URLRequest(url: URL(string: base + "/v1/account")!), timeout: 5, baseUrl: base) { data, _, error in
            XCTAssertNil(error)
            limit = data.flatMap(PublishOptions.attachmentLimit)
            account.fulfill()
        }
        wait(for: [account], timeout: 7)
        XCTAssertNotNil(limit)
        send("Photo caption\nSecond line", title: "A photo", options: PublishOptions(filename: "landscape.jpg", fileURL: photo, attachmentLimit: limit))
        let polled = expectation(description: "real topic poll")
        var rows: [Message] = []
        api.poll(PollRequest(subscriptionID: topic.objectID, baseUrl: base, topicUrl: topic.urlString(), since: "all", user: nil)) { messages, error in
            XCTAssertNil(error); rows = messages ?? []; polled.fulfill()
        }
        wait(for: [polled], timeout: 7)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.message, "**A note**\nfrom iOS")
        XCTAssertEqual(rows.first?.title, "Hola 🌍")
        XCTAssertEqual(rows.first?.click, "https://example.org/note")
        XCTAssertEqual(rows.first?.contentType, "text/markdown")
        XCTAssertEqual(rows.first?.tags, ["memo", "🐱"])
        XCTAssertEqual(rows.last?.message, "Photo caption\nSecond line")
        let attachment = try XCTUnwrap(rows.last?.attachment)
        XCTAssertEqual(attachment.name, "landscape.jpg")
        let downloaded = expectation(description: "download exact uploaded photo")
        api.runOneShot(URLRequest(url: URL(string: attachment.url)!), timeout: 5, baseUrl: base) { data, _, error in
            XCTAssertNil(error); XCTAssertEqual(data, bytes); downloaded.fulfill()
        }
        wait(for: [downloaded], timeout: 7)
        let receipt = XCTAttachment(string: "Stock ntfy received \(rows.count) messages on \(topic.urlString()). Text, Unicode title/tags, click, markdown, multiline photo caption and downloaded bytes matched. Photo SHA256: \(SHA256.hash(data: bytes))")
        receipt.name = "native-stock-publish-receipt"; receipt.lifetime = .keepAlways; add(receipt)
        print("NATIVE_COMPOSE_TOPIC " + topic.urlString())
    }
}

/// 1.32: a photo the person sends back reaches an agent in a format it can read, and an agent's
/// screenshot shows as the picture on the phone without a tap.
final class OutgoingImageTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Writes a striped width x height image of `type`, with an EXIF orientation, a capture date and,
    /// unless `gps` is false, a GPS position. The stripes make a lossy re-encode change the pixels.
    private func image(_ name: String, _ type: UTType, width: Int, height: Int, orientation: Int = 1,
                       gps: Bool = true) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.3, alpha: 1))
        for x in stride(from: 0, to: width, by: 7) { context.fill(CGRect(x: x, y: 0, width: 3, height: height)) }
        let url = folder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("this simulator cannot encode \(type.identifier)")
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:24 12:00:00"]
        ]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 32.46, kCGImagePropertyGPSLatitudeRef: "N"]
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("this simulator cannot encode \(type.identifier)") }
        return url
    }
    private func read(_ url: URL) -> (type: String, width: Int, height: Int, gps: Bool) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (CGImageSourceGetType(source)! as String, properties[kCGImagePropertyPixelWidth] as! Int,
                properties[kCGImagePropertyPixelHeight] as! Int, properties[kCGImagePropertyGPSDictionary] != nil)
    }

    func testCameraHEICPhotoGoesAsUprightJPEGWithoutLocation() throws {
        // Orientation 6: stored landscape, shown portrait (how an iPhone saves a portrait photo).
        let heic = try image("IMG_0001.HEIC", .heic, width: 300, height: 200, orientation: 6)
        let sent = OutgoingImage.prepare(heic)
        XCTAssertEqual(sent.lastPathComponent, "IMG_0001.jpg")
        let result = read(sent)
        XCTAssertEqual(result.type, UTType.jpeg.identifier)
        XCTAssertEqual([result.width, result.height], [200, 300], "the pixels are rotated as Photos shows them")
        XCTAssertFalse(result.gps, "the location stays on the phone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path), "only the JPEG is left to send")
    }

    func testOtherFormatsConvertAndHugePhotosShrinkToTheLimit() throws {
        let tiff = try image("scan.tiff", .tiff, width: OutgoingImage.maxPixelSize + 904, height: 100)
        let result = read(OutgoingImage.prepare(tiff))
        XCTAssertEqual(result.type, UTType.jpeg.identifier)
        XCTAssertEqual(result.width, OutgoingImage.maxPixelSize)
    }

    /// The decoded RGBA pixels of `url`, to tell a copied image from a re-encoded one.
    private func pixels(_ url: URL) -> Data {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    func testScreenshotsAndAgentReadableFormatsGoUnchanged() throws {
        for (name, type) in [("shot.png", UTType.png), ("photo.jpg", .jpeg), ("loop.gif", .gif)] {
            let original = try image(name, type, width: 5000, height: 40, gps: false)
            let bytes = try Data(contentsOf: original)
            let sent = OutgoingImage.prepare(original)
            XCTAssertEqual(sent, original, name)
            XCTAssertEqual(try Data(contentsOf: sent), bytes, "\(name) keeps every byte")
        }
        let text = folder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: text)
        XCTAssertEqual(OutgoingImage.prepare(text), text)
    }

    func testAnUprightPhotoLosesOnlyItsLocation() throws {
        for (name, type) in [("photo.jpg", UTType.jpeg), ("shot.png", .png), ("loop.gif", .gif)] {
            let original = try image(name, type, width: 600, height: 40)
            guard read(original).gps else {
                XCTAssertNotEqual(type, .jpeg, "the JPEG fixture must carry a location for this test to mean anything")
                continue  // this format can't hold a location here, so there is nothing to remove
            }
            let before = pixels(original)
            let sent = OutgoingImage.prepare(original)
            XCTAssertEqual(sent, original, "\(name) keeps its name and format")
            let result = read(sent)
            XCTAssertEqual(result.type, type.identifier, name)
            XCTAssertFalse(result.gps, "\(name): the location stays on the phone")
            XCTAssertEqual([result.width, result.height], [600, 40], name)
            XCTAssertEqual(pixels(sent), before, "\(name): copied, not re-encoded")
            let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(sent as CFURL, nil)!, 0, nil) as! [CFString: Any]
            if type == .jpeg {
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:11:24 12:00:00", "the rest of EXIF stays")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [name], "no leftovers")
            try FileManager.default.removeItem(at: sent)
        }
    }

    func testASidewaysJPEGIsTurnedUprightUnderItsOwnName() throws {
        // An iPhone set to "Most Compatible" saves a portrait photo as a landscape JPEG tagged 6.
        let jpeg = try image("IMG_0003.jpg", .jpeg, width: 300, height: 200, orientation: 6)
        let sent = OutgoingImage.prepare(jpeg)
        XCTAssertEqual(sent, jpeg, "same name, now upright")
        XCTAssertEqual([read(sent).width, read(sent).height], [200, 300])
        XCTAssertFalse(read(sent).gps, "a re-encoded photo carries no location")
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(sent as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["IMG_0003.jpg"], "no leftovers")
    }

    func testStagedPhotoIsConvertedAndTheServerLimitAppliesToWhatIsSent() throws {
        let heic = try image("IMG_0002.heic", .heic, width: 64, height: 64)
        let staged = try ComposeModel.stageImage(heic, limit: 10 * 1024 * 1024)
        XCTAssertEqual(staged.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: heic.path), "the picker's own file is left alone")
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())

        XCTAssertThrowsError(try ComposeModel.stageImage(heic, limit: 10)) {
            XCTAssertEqual($0 as? ApiService.PublishError, .attachmentTooLarge)
        }
    }

    /// The paperclip sends the file as picked; only an image's location stays behind (operator,
    /// 2026-11-25: "Strip paperclip images too").
    func testPaperclipFilesGoAsPickedExceptAnImagesLocation() throws {
        let limit: Int64 = 10 * 1024 * 1024
        // A sideways JPEG keeps its orientation tag and pixels: the paperclip doesn't turn it upright.
        let jpeg = try image("IMG_0004.jpg", .jpeg, width: 300, height: 200, orientation: 6)
        let before = pixels(jpeg)
        let sentJPEG = try ComposeModel.stageFile(jpeg, limit: limit)
        XCTAssertEqual(sentJPEG.lastPathComponent, "IMG_0004.jpg")
        XCTAssertFalse(read(sentJPEG).gps, "the location stays on the phone")
        XCTAssertEqual(pixels(sentJPEG), before, "copied, not re-encoded")
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(sentJPEG as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        XCTAssertTrue(read(jpeg).gps, "the picked file itself is left alone")
        try? FileManager.default.removeItem(at: sentJPEG.deletingLastPathComponent())

        // A HEIC with a location can't be rewritten in place, so it goes as a JPEG, which carries none.
        let heic = try image("IMG_0005.heic", .heic, width: 64, height: 64)
        let sentHEIC = try ComposeModel.stageFile(heic, limit: limit)
        XCTAssertEqual(read(sentHEIC).type, UTType.jpeg.identifier)
        XCTAssertFalse(read(sentHEIC).gps)
        try? FileManager.default.removeItem(at: sentHEIC.deletingLastPathComponent())

        // Without a location, an image goes byte for byte, HEIC included; so does any other file.
        let plain = try image("IMG_0006.heic", .heic, width: 64, height: 64, gps: false)
        let text = folder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: text)
        for original in [plain, text] {
            let sent = try ComposeModel.stageFile(original, limit: limit)
            XCTAssertEqual(sent.lastPathComponent, original.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: sent), try Data(contentsOf: original), original.lastPathComponent)
            try? FileManager.default.removeItem(at: sent.deletingLastPathComponent())
        }
    }

    func testAnAgentsFullScreenScreenshotDownloadsByDefault() throws {
        let store = Store.shared
        let saved = store.getAttachmentAutoDownloadMaxSize()
        func clear() {
            store.context.performAndWait {
                let request = Preference.fetchRequest()
                request.predicate = NSPredicate(format: "key = %@", Store.prefKeyAttachmentAutoDownloadMaxSize)
                for row in (try? store.context.fetch(request)) ?? [] { store.context.delete(row) }
                try? store.context.save()
            }
        }
        clear()
        addTeardownBlock { store.saveAttachmentAutoDownloadMaxSize(saved) }
        let megabyte: Int64 = 1024 * 1024
        func attachment(_ size: Int64) -> MessageAttachment {
            MessageAttachment(name: "screen.png", type: "image/png", size: size, expires: nil, url: "https://ntf-ai.app/file/a.png")
        }
        XCTAssertTrue(store.shouldAutoDownloadAttachment(attachment(3 * megabyte)), "a 3 MB Retina screenshot shows without a tap")
        XCTAssertTrue(store.shouldAutoDownloadAttachment(attachment(5 * megabyte)))
        XCTAssertFalse(store.shouldAutoDownloadAttachment(attachment(5 * megabyte + 1)))
        store.saveAttachmentAutoDownloadMaxSize(Store.autoDownload1MB)
        XCTAssertFalse(store.shouldAutoDownloadAttachment(attachment(3 * megabyte)), "a limit the person chose still holds")
    }
}

@MainActor
final class ComposePresentationTests: XCTestCase {
    func testRequiredMessageAndAttachmentValidation() {
        let model = ComposeModel()
        XCTAssertFalse(model.canSend)
        model.message = " \n "
        XCTAssertFalse(model.canSend)
        model.attachmentURL = "https://example.org/photo.jpg"
        XCTAssertTrue(model.canSend)
        model.busy = true
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.dirty)
    }

    func testStagingEnforcesLimitAndRemovalCleansOnlyOwnedCopy() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("test file".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertThrowsError(try ComposeModel.stage(source, limit: 2))
        let staged = try ComposeModel.stage(source, limit: 9)
        XCTAssertNotEqual(staged, source)
        let model = ComposeModel(); model.acceptFile(staged)
        XCTAssertEqual(model.fileName, source.lastPathComponent)
        model.removeFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let late = try ComposeModel.stage(source, limit: 9)
        model.close()
        model.acceptFile(late)
        XCTAssertNil(model.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    func testCaptureComposeStatesOnSimulator() throws {
        guard ProcessInfo.processInfo.environment["COMPOSE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Opt in with COMPOSE_SCREENSHOTS=1 for native visual evidence")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("compose-screenshots")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = ProcessInfo.processInfo.environment["COMPOSE_STOCK_URL"] ?? "http://127.0.0.1:54579"
        let topic = Store.shared.saveSubscription(baseUrl: base, topic: "compose-ui-121")
        let loaded = expectation(description: "load real sent messages for list screenshots")
        SubscriptionManager(store: Store.shared).pollWithOutcome(topic, manual: true) { outcome in
            XCTAssertTrue(outcome.succeeded)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)
        defer { window.isHidden = true; previous?.makeKey() }
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for name in ["empty", "filled", "error", "sent"] {
            for variant in ["light", "dark", "largest-text"] {
                let model = ComposeModel()
                model.attachmentLimit = 15_728_640
                if name != "empty" {
                    model.message = "A note between my devices\n\n**Remember** the train tickets."
                    model.title = "Travel notes"
                    model.tags = "train, memo"
                    model.priority = 4
                    model.markdown = true
                    model.clickURL = "https://example.org/tickets"
                    model.delay = "30m"
                }
                if name == "error" { model.error = ApiService.PublishError.http(403).userMessage }
                let root: AnyView
                if name == "sent" {
                    root = AnyView(NavigationView {
                        NotificationListView(subscription: topic).environmentObject(Store.shared)
                    }.navigationViewStyle(StackNavigationViewStyle())
                        .environment(\.colorScheme, variant == "dark" ? .dark : .light)
                        .environment(\.sizeCategory, variant == "largest-text" ? .accessibilityExtraExtraExtraLarge : .large))
                } else {
                    root = AnyView(Color.clear.sheet(isPresented: .constant(true)) {
                    ComposeSheetView(subscription: topic, model: model).environmentObject(Store.shared)
                        .environment(\.colorScheme, variant == "dark" ? .dark : .light)
                        .environment(\.sizeCategory, variant == "largest-text" ? .accessibilityExtraExtraExtraLarge : .large)
                    })
                }
                let host = UIHostingController(rootView: root)
                window.rootViewController = host
                window.overrideUserInterfaceStyle = variant == "dark" ? .dark : .light
                window.makeKeyAndVisible();host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                let scroll = scrollViews(host.presentedViewController?.view ?? host.view).first
                var offset = -(scroll?.adjustedContentInset.top ?? 0)
                for page in 0..<24 {
                    scroll?.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try XCTUnwrap(image.jpegData(compressionQuality: 0.5)).write(to: directory.appendingPathComponent("\(name)-\(variant)-\(page).jpg"))
                    guard let scroll else { break }
                    let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    if scroll.contentOffset.y >= bottom - 1 { break }
                    offset = min(bottom, scroll.contentOffset.y + max(80, scroll.bounds.height * 0.65))
                    XCTAssertLessThan(page, 23)
                }
                host.dismiss(animated: false)
            }
        }
    }
}

extension ComposeTests {
    func testOversizedTextAndCaptionsAreRefusedInsteadOfTruncatedOrAutoAttached() throws {
        let tooLong = String(repeating: "🌍", count: 1025)
        XCTAssertEqual(tooLong.utf8.count, 4100)
        XCTAssertThrowsError(try build(PublishOptions(), message: tooLong))
        XCTAssertThrowsError(try build(PublishOptions(attachmentURL: "https://example.org/photo.jpg"), message: tooLong))
        XCTAssertThrowsError(try build(PublishOptions(), message: String(repeating: "🌍", count: 1024)))
        XCTAssertNoThrow(try build(PublishOptions(), message: String(repeating: "m", count: 4095)))
    }

    func testRelayRecoveryProbeIsConsumedByTheActualPublishOnlyOnce() {
        for condition in ["state-change", "request-change"] {
            let cooldown = ServerCooldown(defaults: nil)
            cooldown.limit(server: base, retryAfter: nil, condition: condition, kind: .publish)
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ComposeProtocol.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            ComposeProtocol.count = 0
            let topic = self.topic()
            let check = RelayCheck(cooldown: cooldown, discover: { $0(true) }, read: { request, done in
                done(Data("{\"relayed\":false,\"relayed_at\":null,\"window_seconds\":120}".utf8),
                     HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
            }, schedule: { _, action in action() })
            check.prepare(baseUrl: base, topic: topic.topicName())
            let prepared = expectation(description: "capability")
            DispatchQueue.main.async { prepared.fulfill() }; wait(for: [prepared], timeout: 2)
            let published = expectation(description: "recovery publish")
            check.approve { done in
                ApiService().publish(subscription: topic, user: nil, message: "recovery", title: "", session: session, cooldown: cooldown,
                    completionHandler: { done(nil); published.fulfill() },
                    failureHandler: { error in XCTFail(error.userMessage); done(error.userMessage); published.fulfill() })
            }
            wait(for: [published], timeout: 3)
            XCTAssertEqual(ComposeProtocol.count, 1, condition)
            check.cancel()
        }
    }
}


extension ComposeTests {
    func testExactly4096ByteEncryptedPublishIsRefusedBeforeStockCanAutoAttachIt() throws {
        let key = Data(repeating: 4, count: 32)
        let empty = TopicEncryption.payload(message: "", title: "", priority: 3, tags: [])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let overhead = try encoder.encode(empty).count
        let message = String(repeating: "m", count: 3011 - overhead)
        let payload = TopicEncryption.payload(message: message, title: "", priority: 3, tags: [])
        XCTAssertEqual(try encoder.encode(payload).count, 3011)
        XCTAssertEqual(try TopicEncryption.encrypt(payload, key: key).utf8.count, 4096)
        let result = ApiService().buildPublishRequest(subscription: topic(), user: nil, message: message, title: "", encryptionKey: key)
        guard case .failure(.tooLargeToEncrypt(bytes: 4096)) = result else {
            return XCTFail("An exactly 4096-byte ciphertext must never reach the raw publish endpoint")
        }
    }
}

/// The line under an agent's picture says when its link stops working.
final class AttachmentFinePrintTests: XCTestCase {
    func testALinkThatExpiresTodayShowsTheTimeAndALaterOneTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 13, minute: 5)))
        let store = Store(inMemory: true)
        let notification = ntfy.Notification(context: store.context)
        notification.id = "fp1"
        notification.attachmentUrl = "https://ntf-ai.app/file/a.png"
        notification.attachmentName = "latency.png"
        notification.attachmentSize = 34_453

        // ntf-ai.app keeps a file 3 hours.
        let later = now.addingTimeInterval(3 * 3600)
        notification.attachmentExpires = Int64(later.timeIntervalSince1970)
        let time = DateFormatter.localizedString(from: later, dateStyle: .none, timeStyle: .short)
        let today = try XCTUnwrap(notification.attachmentFinePrint(includeName: true, now: now, calendar: calendar))
        XCTAssertTrue(today.hasSuffix(String(localized: "expires at \(time)")), today)
        XCTAssertTrue(today.hasPrefix("latency.png · "), today)

        let nextWeek = now.addingTimeInterval(7 * 86400)
        notification.attachmentExpires = Int64(nextWeek.timeIntervalSince1970)
        let day = DateFormatter.localizedString(from: nextWeek, dateStyle: .medium, timeStyle: .none)
        XCTAssertEqual(notification.attachmentFinePrint(includeName: false, now: now, calendar: calendar),
                       "\(formatBytes(34_453)) · " + String(localized: "expires \(day)"))

        notification.attachmentExpires = Int64(now.addingTimeInterval(-60).timeIntervalSince1970)
        XCTAssertTrue(try XCTUnwrap(notification.attachmentFinePrint(includeName: false, now: now, calendar: calendar))
                        .hasSuffix(String(localized: "expired")))
    }
}
