import XCTest
import UserNotifications
@testable import ntfy

final class LocalizationTests: XCTestCase {
    /// Raw catalog resources are copied from the same folder compiled into the app and NSE.
    /// Discover languages across all tables so adding a language automatically adds its gate.
    func testEveryCatalogEntryIsTranslatedInEverySupportedLanguage() throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Localization"))
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        XCTAssertEqual(urls.count, 2)
        let catalogs = try urls.map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: Any] }
        let tables = catalogs.map { $0["strings"] as! [String: [String: Any]] }
        let languages = Set(tables.flatMap { $0.values.flatMap { ($0["localizations"] as? [String: Any])?.keys.map { $0 } ?? [] } })
        XCTAssertTrue(languages.contains("de"))
        let appCopy = tables[try XCTUnwrap(urls.firstIndex { $0.lastPathComponent == "Localizable.xcstrings" })]
        for component in OpenSourceLicenses.components {
            XCTAssertNotNil(appCopy[component.licenseName], "Missing license-name translation: \(component.licenseName)")
        }

        for (table, url) in zip(tables, urls) {
            XCTAssertFalse(table.isEmpty)
            for (key, entry) in table {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for language in languages {
                    let value = try XCTUnwrap(localizations[language], "\(url.lastPathComponent): \(language) missing for \(key)")
                    if let source = localizations["en"] as? [String: Any],
                       let sourceVariations = source["variations"] as? [String: Any],
                       sourceVariations["plural"] != nil {
                        let object = try XCTUnwrap(value as? [String: Any])
                        let variations = try XCTUnwrap(object["variations"] as? [String: Any], "\(language): missing plural variants for \(key)")
                        let plural = try XCTUnwrap(variations["plural"] as? [String: Any])
                        let required: Set<String>
                        switch language {
                        case "pl": required = ["one", "few", "many", "other"]
                        case "es", "it", "fr": required = ["one", "many", "other"]
                        default: required = ["one", "other"]
                        }
                        XCTAssertTrue(required.isSubset(of: Set(plural.keys)), "\(language): missing plural categories for \(key)")
                    }
                    let units = stringUnits(value)
                    XCTAssertFalse(units.isEmpty, "\(language): no values for \(key)")
                    for unit in units {
                        XCTAssertEqual(unit["state"] as? String, "translated", "\(language): \(key)")
                        let text = try XCTUnwrap(unit["value"] as? String)
                        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): empty \(key)")
                        // InfoPlist uses symbolic keys. Other tables preserve all format arguments.
                        if url.lastPathComponent == "Localizable.xcstrings" {
                            XCTAssertEqual(placeholders(text), placeholders(key), "\(language): arguments differ for \(key)")
                        }
                    }
                }
            }
        }
    }

    /// These six immutable bullets describe builds already shipped or in review through 1.24.
    /// Keep the exemption exact so newly added copy cannot silently inherit it.
    func testCurrentCatalogCopyUsesDeviceNeutralWordingInEveryLanguage() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("Localization/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let historicalBullets: Set<String> = [
            "For self-hosted HTTPS topics, Settings → Notification status can check whether ntfy-me.com receives forwarded wake-ups. It asks before sending one visible test message. This checks forwarding, not delivery to your phone.",
            "If notifications are turned off for the app, or a topic can't refresh, the app now says why and how to fix it. Settings → Notification status checks that this phone is set up for push and can repair it.",
            "Settings → Notification history sets how long notifications are kept on this phone. Until you choose a limit, everything is kept. Long topics open on their newest messages, and you can search a topic's whole history.",
            "The app and its notifications now follow your phone's language when it is German.",
            "The app and its notifications now support Spanish, Italian, Polish, Dutch and French, following your phone's language.",
            "View and share diagnostic reports from Settings > About. Reports stay on your phone.",
        ]
        XCTAssertTrue(historicalBullets.isSubset(of: Set(strings.keys)))
        // No current sentence is device-specific by design. Include inflected phone nouns
        // in the six translations, and traverse plural/device variations as well as plain units.
        let phone = try NSRegularExpression(pattern: #"(?i)\b(?:i?phones?|tel[eé]fo+n\w*|téléphon\w*)\b"#)
        for noun in ["phone", "iPhone", "Telefon", "teléfono", "telefono", "telefonie", "telefoon", "téléphone"] {
            XCTAssertNotNil(phone.firstMatch(in: noun, range: NSRange(noun.startIndex..., in: noun)), noun)
        }
        for (key, entry) in strings where !historicalBullets.contains(key) {
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for (language, value) in localizations {
                for unit in stringUnits(value) {
                    let text = try XCTUnwrap(unit["value"] as? String)
                    XCTAssertNil(phone.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                 "\(language): device-specific phone wording in \(key): \(text)")
                }
            }
        }
    }

    func testDeviceNeutralCopyCompilesIntoAppAndNotificationExtension() throws {
        let keys = [
            "Check whether %@ receives forwarded wake-ups for this topic. This cannot prove delivery to your device.",
            "Critical alerts, which play sound even when your device is silenced, need special approval from Apple and aren't offered in this app.",
            "Encrypted messages stay locked and plain ones are marked \"Not encrypted\". If this persists after unlocking your device, set the password again or remove it.",
            "Device registration",
            "The encryption password is unavailable. Unlock your device or set the topic password again. Nothing was sent.",
            "This topic is end-to-end encrypted, but its password can't be read right now, so the test message would go out unencrypted. Try again after unlocking your device, or set the password again.",
            "With a password, messages are encrypted by whoever sends them, in transit and on the server: the server, Google and Apple see only ciphertext. Once they arrive they are stored readable on this device. The password stays on this device only and isn't backed up, so a restored or new device needs it entered again. Senders need the same password; see \"How to send encrypted messages\".",
            "Your server's upstream-base-url must be https://ntfy.sh, with instant banners on in Settings, or %@. Its configured base-url must exactly match the server address used for this subscription, including scheme, port, path and spelling. The relay keeps only recent acceptance times (up to 2 minutes); it does not report device delivery.",
            "%@ received a wake-up for this topic at %@, and FCM accepted it. This does not prove your device received it or that this test caused the wake-up.",
            "The server sign-in is unavailable. Unlock your device or sign in again in Settings. Nothing was sent.",
            "Topics could not be read. Unlock your device and open NTF-AI, then try again.",
            "Get one alert when no message arrives within the chosen time, even if this topic is muted. A new message starts the timer again. A quiet alert can also mean this device isn't receiving messages, including when it is offline.",
            "New messages won't show while your device is locked. Tap Open Settings, then turn on Lock Screen.",
            "Allow notifications so each message sent to %@ shows up on your lock screen, even when the app is closed. You'll be asked for permission next.",
            "Allow notifications so messages sent to the topics you added show up on your lock screen, even when the app is closed. You'll be asked for permission next.",
            "Critical alerts were not allowed. You can enable them for NTF-AI in the Settings app under Notifications.",
            "Priority 4 and 5 messages are Time Sensitive. They can break through Focus and the Notification Summary when allowed in the Settings app, including your Focus settings.",
            "Your device provides reports after some crashes, hangs or resource issues. They may arrive later and do not cover every incident.",
            "Date shown is the end of the reporting period. The JSON file contains call stacks and technical metadata. You can attach it to a bug report.",
            "Import audio from Files, up to 50 MB. The first 29 seconds are used. System ringtones are not available to apps.",
            "Allowed messages use their usual topic sound and urgency. Notification and Focus settings still apply.",
            "Messages can arrive late or only when you open the app. Turn it on in the Settings app under General → Background App Refresh.",
            "Background updates are paused to save battery, so messages can arrive late. Turn it off in the Settings app under Battery.",
            "Shows the system notification permission prompt",
            "When enabled, priority 5 messages can play sound even when silenced.",
        ]
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("Localization/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent == "ntfyNSE.appex" })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        for key in keys {
            let entry = try XCTUnwrap(strings[key], "Missing device-neutral catalog key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for (language, value) in localizations {
                let expected = try XCTUnwrap(stringUnits(value).first?["value"] as? String)
                for target in [Bundle.main, extensionBundle] {
                    let bundle = try XCTUnwrap(target.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
                    XCTAssertEqual(bundle.localizedString(forKey: key, value: "__missing_device_copy__", table: nil), expected,
                                   "\(target.bundleURL.lastPathComponent): \(language): \(key)")
                }
            }
        }
    }

    func testDeviceRegistrationAndLockScreenCopyReachTheApp() {
        XCTAssertEqual(DeliveryHealthCopy.phoneRegistration, String(localized: "Device registration"))
        XCTAssertNotEqual(DeliveryHealthCopy.phoneRegistration, DeliveryHealthCopy.pushRegistration)
        XCTAssertEqual(NotificationWarning.lockScreenOff.detail,
                       String(localized: "New messages won't show while your device is locked. Tap Open Settings, then turn on Lock Screen."))
    }

    /// Shipped release copy is immutable; the official upstream client is a product name.
    /// Current instructions should say Settings or describe the action directly on both platforms.
    func testCurrentCatalogCopyDoesNotNameOnlyThePhoneOperatingSystem() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("Localization/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let historicalOrProductNames: Set<String> = [
            "Priority 4 and 5 messages can now break through Focus and the Notification Summary when Time Sensitive notifications are allowed in iOS and Focus settings.",
            "Notification status now shows iOS settings that hide or delay alerts.",
        ]
        XCTAssertTrue(historicalOrProductNames.isSubset(of: Set(strings.keys)))
        let ios = try NSRegularExpression(pattern: #"\biOS\b"#)
        for (key, entry) in strings where !historicalOrProductNames.contains(key) {
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for (language, value) in localizations {
                for unit in stringUnits(value) {
                    let text = try XCTUnwrap(unit["value"] as? String)
                    XCTAssertNil(ios.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                 "\(language): current copy names only iOS: \(key): \(text)")
                }
            }
        }
    }

    func testPlatformNeutralUrgentCopyReachesTheApp() {
        XCTAssertEqual(UrgentAlertsState.explanation,
                       String(localized: "Priority 4 and 5 messages are Time Sensitive. They can break through Focus and the Notification Summary when allowed in the Settings app, including your Focus settings."))
    }

    func testSystemSettingsWarningsNameTheSettingsApp() {
        XCTAssertEqual(NotificationWarning.backgroundRefreshOff.detail,
                       String(localized: "Messages can arrive late or only when you open the app. Turn it on in the Settings app under General → Background App Refresh."))
        XCTAssertEqual(NotificationWarning.lowPowerMode.detail,
                       String(localized: "Background updates are paused to save battery, so messages can arrive late. Turn it off in the Settings app under Battery."))
    }

    func testWarningBodiesDoNotRepeatTheirTitlesInAnyLanguage() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("Localization/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let warnings: [NotificationWarning] = [.alertsHidden, .bannersOff, .lockScreenOff,
            .notificationCenterOff, .soundsOff, .scheduledSummary, .backgroundRefreshOff,
            .backgroundRefreshRestricted, .lowPowerMode]

        // Resolve the runtime value back to its catalog entry, even when the test host's
        // language is not English. This also keeps the gate tied to the live warning copy.
        func localizations(for text: String) throws -> [String: Any] {
            let matches = strings.values.compactMap { $0["localizations"] as? [String: Any] }
                .filter { $0.values.contains { stringUnits($0).contains { $0["value"] as? String == text } } }
            XCTAssertEqual(matches.count, 1, "Warning text must resolve uniquely: \(text)")
            return try XCTUnwrap(matches.first)
        }
        func words(_ text: String, language: String) -> [String] {
            var tokens = text.lowercased(with: Locale(identifier: language))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let articles: Set<String> = ["the", "der", "die", "das", "el", "los", "las", "la",
                "il", "gli", "i", "le", "les", "l", "de", "het"]
            if let first = tokens.first, articles.contains(first) { tokens.removeFirst() }
            // Italian names the setting with an imperative in the title and a noun in prose.
            if language == "it", tokens.starts(with: ["aggiorna", "app", "in", "background"]) {
                tokens.replaceSubrange(0..<4, with: ["aggiornamento", "delle", "app", "in", "background"])
            }
            return tokens
        }
        let stateVerbs: Set<String> = ["are", "is", "sind", "ist", "está", "están", "sono",
            "è", "są", "jest", "staan", "staat", "blijven", "est", "sont"]
        for warning in warnings {
            let titles = try localizations(for: warning.title)
            let bodies = try localizations(for: warning.detail)
            XCTAssertEqual(Set(titles.keys), Set(bodies.keys))
            XCTAssertEqual(titles.count, 7)
            for language in titles.keys.sorted() {
                let title = try XCTUnwrap(stringUnits(try XCTUnwrap(titles[language])).first?["value"] as? String)
                let body = try XCTUnwrap(stringUnits(try XCTUnwrap(bodies[language])).first?["value"] as? String)
                let titleWords = words(title, language: language)
                let bodyWords = words(body, language: language)
                let verb = try XCTUnwrap(titleWords.firstIndex { stateVerbs.contains($0) },
                                         "Unrecognized warning title state: \(language): \(title)")
                let subject = Array(titleWords.prefix(verb))
                XCTAssertFalse(subject.isEmpty)
                XCTAssertFalse(bodyWords.starts(with: titleWords) || bodyWords.starts(with: subject),
                               "Warning body repeats title opening: \(language)/\(warning.rawValue): \(title) / \(body)")
            }
        }
    }

    func testSpanishTopicTerminologyDoesNotUseTema() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("Localization/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)
        let expression = try NSRegularExpression(pattern: #"\btemas?\b"#, options: .caseInsensitive)
        let offendingKeys = strings.compactMap { key, entry -> String? in
            guard let spanish = (entry["localizations"] as? [String: Any])?["es"] else { return nil }
            let hasTema = stringUnits(spanish).contains { unit in
                guard let text = unit["value"] as? String else { return false }
                return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            return hasTema ? key : nil
        }.sorted()
        XCTAssertTrue(offendingKeys.isEmpty,
                      "Spanish translations must use tópico/tópicos instead of tema/temas. Offending keys: \(offendingKeys.joined(separator: ", "))")
    }

    func testLicenseDetailKeepsCanonicalNoticesInGerman() {
        for component in OpenSourceLicenses.components {
            XCTAssertEqual(component.localizedFullText, component.fullText, component.name)
        }
    }

    func testIngressFallbacksStayNeutralAndRenderInCurrentLanguage() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://localization.invalid", topic: "fallbacks")
        let cases = [
            ("future", "wire", "This message uses an unsupported encoding."),
            ("base64", "not!base64", "This message could not be decoded (invalid base64)."),
            ("base64", "//4A", "This message contains binary data and cannot be displayed as text.")
        ]
        for (index, item) in cases.enumerated() {
            let (encoding, body, source) = item
            let message = Message(id: "fallback-\(index)", time: 1_800_000_000 + Int64(index),
                                  event: "message", topic: "fallbacks", message: body, encoding: encoding)
            store.save(notificationsFromMessages: [message], withSubscription: sub)
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", message.id)
            let row = try XCTUnwrap(store.context.fetch(request).first)
            XCTAssertEqual(row.message, source, "Persist the English source in every ingress locale")
            XCTAssertEqual(row.formatMessage(), Bundle.main.localizedString(forKey: source, value: nil, table: nil))
            // Each full-suite run ingests in its launch language (German or English). Re-read
            // the saved row through both real language bundles, simulating a later app relaunch.
            store.context.refresh(row, mergeChanges: false)
            for language in ["en", "de"] {
                let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
                XCTAssertEqual(row.formatMessage(bundle: bundle), bundle.localizedString(forKey: source, value: nil, table: nil))
                let ordinary = Message(id: "server-\(index)-\(language)", time: 1_800_000_020,
                                       event: "message", topic: "fallbacks", message: source)
                XCTAssertEqual(Message.localizedBody(ordinary.message, contentType: ordinary.contentType, bundle: bundle), source,
                               "A sender's identical sentence must remain verbatim")
                let encodedText = Message(id: "utf8", time: 1, event: "message", topic: "fallbacks",
                                          message: Data(source.utf8).base64EncodedString(), encoding: "base64")
                XCTAssertEqual(Message.localizedBody(encodedText.message, contentType: encodedText.contentType, bundle: bundle), source)
            }
            let roundTrip = try XCTUnwrap(Message.from(userInfo: message.toUserInfo()))
            XCTAssertEqual(roundTrip.message, source)
            XCTAssertEqual(roundTrip.contentType, message.contentType, "NSE userInfo must retain diagnostic identity")
            let json: [String: Any] = ["id": "json", "time": 1, "event": "message", "topic": "fallbacks",
                                       "message": body, "encoding": encoding]
            let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.message, source)
            XCTAssertEqual(decoded.contentType, message.contentType)
            var pushedInfo = message.toUserInfo()
            pushedInfo["message"] = body
            pushedInfo["encoding"] = encoding
            let pushed = try XCTUnwrap(Message.from(userInfo: pushedInfo))
            XCTAssertEqual(pushed.message, source)
            XCTAssertEqual(pushed.contentType, message.contentType)
            let banner = UNMutableNotificationContent()
            banner.modify(message: message, baseUrl: "https://localization.invalid", categoryRegistrationTimeout: 0)
            XCTAssertEqual(banner.body, Bundle.main.localizedString(forKey: source, value: nil, table: nil))
            banner.userInfo = pushedInfo
            banner.body = body
            XCTAssertEqual(UNNotificationContent.encryptionSafeFallback(banner).body,
                           Bundle.main.localizedString(forKey: source, value: nil, table: nil))
        }
        let info: [AnyHashable: Any] = ["id": "unnamed", "time": "1800000010", "event": "message",
                                     "topic": "fallbacks", "attachment_url": "https://attachments.invalid/"]
        let message = try XCTUnwrap(Message.from(userInfo: info))
        store.save(notificationsFromMessages: [message], withSubscription: sub)
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", message.id)
        let row = try XCTUnwrap(store.context.fetch(request).first)
        XCTAssertTrue(row.attachmentName?.isEmpty != false, "Do not persist a localized fallback name")
        XCTAssertEqual(row.messageAttachment()?.displayName(), String(localized: "attachment"))
        store.context.refresh(row, mergeChanges: false)
        for language in ["en", "de"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            XCTAssertEqual(row.messageAttachment()?.displayName(bundle: bundle), bundle.localizedString(forKey: "attachment", value: nil, table: nil))
        }
        row.attachmentName = "Anhang"
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(row.messageAttachment()?.displayName(bundle: english), "Anhang", "Preserve a sender's actual name")
    }

    func testAddedLanguagesCompileIntoAppAndExtensionWithLocalePlurals() throws {
        let expected: [String: [String]] = [
            "es": ["Tópicos", "1 hora", "2 horas", "5 horas", "12 horas", "22 horas"],
            "it": ["Argomenti", "1 ora", "2 ore", "5 ore", "12 ore", "22 ore"],
            "pl": ["Tematy", "1 godzina", "2 godziny", "5 godzin", "12 godzin", "22 godziny"],
            "nl": ["Onderwerpen", "1 uur", "2 uur", "5 uur", "12 uur", "22 uur"],
            "fr": ["Sujets", "1 heure", "2 heures", "5 heures", "12 heures", "22 heures"]
        ]
        let regions = ["es": "ES", "it": "IT", "pl": "PL", "nl": "NL", "fr": "FR"]
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil).first { $0.pathExtension == "appex" })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        for language in Bundle.main.localizations where expected[language] != nil {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let values = try XCTUnwrap(expected[language])
            let locale = Locale(identifier: language + "_" + regions[language]!)
            XCTAssertEqual(bundle.localizedString(forKey: "Topics", value: nil, table: nil), values[0])
            for (index, count) in [1, 2, 5, 12, 22].enumerated() {
                let format = bundle.localizedString(forKey: "%lld hours", value: nil, table: nil)
                XCTAssertEqual(String(format: format, locale: locale, count), values[index + 1], language)
            }
            if language == "pl" {
                let retry = bundle.localizedString(forKey: "The server is limiting this action. Try again in %lld seconds.", value: nil, table: nil)
                for (count, noun) in [(1, "sekundę"), (2, "sekundy"), (5, "sekund"), (12, "sekund"), (22, "sekundy")] {
                    XCTAssertTrue(String(format: retry, locale: locale, count).hasSuffix("\(count) \(noun)."))
                }
            }
            let nse = try XCTUnwrap(extensionBundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in ["Notification state synchronized", "Encrypted message", "New message on %@. Open the app to load it."] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, language)
                XCTAssertEqual(nse.localizedString(forKey: key, value: nil, table: nil), value, language)
            }
            let permission = bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertNotEqual(permission, "NSCameraUsageDescription")
            XCTAssertTrue(permission.contains("NTF-AI"))
        }
    }

    func testVersion120ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.20.0" })
        XCTAssertEqual(release.bullets.count, 2)
        let expected: [String: [String]] = [
            "en": ["Message images no longer disappear from the app after appearing in a notification.", "The app and its notifications now support Spanish, Italian, Polish, Dutch and French, following your phone's language."],
            "de": ["Bilder in Nachrichten verschwinden nicht mehr aus der App, nachdem sie in einer Benachrichtigung angezeigt wurden.", "Die App und ihre Benachrichtigungen sind jetzt auch auf Spanisch, Italienisch, Polnisch, Niederländisch und Französisch verfügbar und folgen der Sprache deines iPhones."],
            "es": ["Las imágenes de los mensajes ya no desaparecen de la app después de mostrarse en una notificación.", "La app y sus notificaciones ahora están disponibles en español, italiano, polaco, neerlandés y francés, según el idioma de tu teléfono."],
            "it": ["Le immagini dei messaggi non scompaiono più dall'app dopo essere state mostrate in una notifica.", "L'app e le sue notifiche sono ora disponibili in spagnolo, italiano, polacco, olandese e francese, in base alla lingua del tuo telefono."],
            "pl": ["Obrazy w wiadomościach nie znikają już z aplikacji po wyświetleniu w powiadomieniu.", "Aplikacja i jej powiadomienia są teraz dostępne po hiszpańsku, włosku, polsku, niderlandzku i francusku, zgodnie z językiem telefonu."],
            "nl": ["Afbeeldingen in berichten verdwijnen niet meer uit de app nadat ze in een melding zijn getoond.", "De app en de meldingen die de app zelf maakt, zijn nu beschikbaar in het Spaans, Italiaans, Pools, Nederlands en Frans en volgen de taal van je telefoon."],
            "fr": ["Les images des messages ne disparaissent plus de l’app après leur affichage dans une notification.", "L’app et ses notifications sont maintenant disponibles en espagnol, italien, polonais, néerlandais et français, selon la langue de votre téléphone."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion121ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.21.0" })
        XCTAssertEqual(release.bullets.count, 4)
        let expected: [String: [String]] = [
            "en": ["Send messages with an optional title, priority, tags and an attachment from a topic screen.", "Share links, text, photos and files to your subscribed topics from other apps.", "Messages that already alerted you no longer alert again when received a second time.", "See when a server refuses sign-in, with a button in the topic screen to check the server user."],
            "de": ["Sende Nachrichten direkt aus einem Thema, auf Wunsch mit Titel, Priorität, Tags und einem Anhang.", "Sende Links, Text, Fotos und Dateien aus anderen Apps an abonnierte Themen.", "Nachrichten, die dich bereits benachrichtigt haben, lösen beim erneuten Empfang keine weitere Benachrichtigung aus.", "Du siehst jetzt, wenn ein Server die Anmeldung ablehnt. Im Thema kannst du über eine Schaltfläche den Server-Benutzer prüfen."],
            "es": ["Envía mensajes desde la pantalla de un tópico, con título, prioridad, etiquetas y un archivo adjunto opcionales.", "Comparte enlaces, texto, fotos y archivos desde otras apps con los tópicos a los que te has suscrito.", "Los mensajes que ya generaron una alerta no vuelven a hacerlo al recibirse de nuevo.", "Ahora se indica si un servidor rechaza el inicio de sesión. Revisa el usuario del servidor con el botón de la pantalla del tópico."],
            "it": ["Invia messaggi dalla schermata di un argomento, con titolo, priorità, tag e un allegato facoltativi.", "Condividi link, testo, foto e file da altre app con gli argomenti a cui sei iscritto.", "I messaggi che hanno già generato un avviso non ne generano un altro se vengono ricevuti di nuovo.", "Ora puoi vedere quando un server rifiuta l'accesso e verificare l'utente del server con il pulsante nella schermata dell'argomento."],
            "pl": ["Wysyłaj wiadomości z ekranu tematu, opcjonalnie dodając tytuł, priorytet, tagi i jeden załącznik.", "Udostępniaj linki, tekst, zdjęcia i pliki z innych aplikacji w subskrybowanych tematach.", "Wiadomości, które już wywołały alert, nie wywołują go ponownie po kolejnym odebraniu.", "Aplikacja informuje teraz, gdy serwer odrzuci logowanie. Przycisk na ekranie tematu pozwala sprawdzić konto na serwerze."],
            "nl": ["Verstuur berichten vanuit een onderwerp, eventueel met een titel, prioriteit, tags en één bijlage.", "Deel links, tekst, foto’s en bestanden vanuit andere apps met de onderwerpen waarop je bent geabonneerd.", "Berichten waarvoor je al een melding hebt gekregen, geven geen nieuwe melding als ze opnieuw binnenkomen.", "Je ziet nu wanneer een server het inloggen weigert. Met de knop in het onderwerp kun je de gebruiker voor die server controleren."],
            "fr": ["Envoyez des messages depuis un sujet, avec un titre, une priorité, des tags et une pièce jointe si vous le souhaitez.", "Partagez des liens, du texte, des photos et des fichiers depuis d’autres apps vers les sujets auxquels vous êtes abonné.", "Les messages qui vous ont déjà alerté ne déclenchent plus d’alerte lorsqu’ils sont reçus une deuxième fois.", "L’app indique désormais quand un serveur refuse la connexion. Un bouton dans le sujet vous permet de vérifier votre utilisateur pour ce serveur."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion122ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.22.0" })
        XCTAssertEqual(release.bullets.count, 3)
        let expected: [String: [String]] = [
            "en": ["Choose a notification sound for each topic, or import one from Files.", "Removed topics stop sending notifications, even if the first unsubscribe attempt fails.", "View and share diagnostic reports from Settings > About. Reports stay on your phone."],
            "de": ["Wähle für jedes Thema einen Benachrichtigungston oder importiere einen aus Dateien.", "Entfernte Themen senden keine Benachrichtigungen mehr, auch wenn das Abmelden zunächst fehlschlägt.", "Sieh dir unter Einstellungen > Über Diagnoseberichte an und teile sie. Sie bleiben auf deinem iPhone."],
            "es": ["Elige un sonido de notificación para cada tópico o importa uno desde Archivos.", "Los tópicos eliminados dejan de enviar notificaciones, aunque falle el primer intento de cancelar la suscripción.", "Consulta y comparte informes de diagnóstico desde Ajustes > Acerca de. Los informes se guardan solo en tu iPhone."],
            "it": ["Scegli un suono di notifica per ogni argomento o importane uno da File.", "Gli argomenti rimossi non inviano più notifiche, anche se il primo tentativo di annullare l’iscrizione non riesce.", "Visualizza e condividi i rapporti diagnostici da Impostazioni > Informazioni. I rapporti restano sul tuo iPhone."],
            "pl": ["Wybierz dźwięk powiadomienia dla każdego tematu lub zaimportuj go z Plików.", "Usunięte tematy nie wysyłają już powiadomień, nawet jeśli pierwsza próba anulowania subskrypcji się nie powiedzie.", "Przeglądaj i udostępniaj raporty diagnostyczne: Ustawienia > O aplikacji. Raporty pozostają na Twoim iPhonie."],
            "nl": ["Kies een meldingsgeluid voor elk onderwerp of importeer er een uit Bestanden.", "Verwijderde onderwerpen sturen geen meldingen meer, ook als het afmelden de eerste keer mislukt.", "Bekijk en deel diagnoserapporten via Instellingen > Over. De rapporten blijven op je iPhone."],
            "fr": ["Choisissez un son de notification pour chaque sujet ou importez-en un depuis Fichiers.", "Les sujets supprimés n’envoient plus de notifications, même si la première tentative de désabonnement échoue.", "Consultez et partagez vos rapports de diagnostic dans Réglages > À propos. Ils restent sur votre iPhone."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion123ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.23.0" })
        XCTAssertEqual(release.bullets.count, 6)
        let expected: [String: [String]] = [
            "en": ["Schedule Quiet hours, with exceptions for priority 5 and chosen topics.", "Run HTTP notification buttons without opening the app. Unlocking is still required.", "Send messages from Shortcuts and Siri.", "Use Alert if quiet to be notified when a topic receives no messages.", "Read code blocks in monospace and choose to open web links in app.", "Fix silent fallback notifications when a message cannot be fetched."],
            "de": ["Plane Ruhezeiten mit Ausnahmen für Priorität 5 und ausgewählte Themen.", "HTTP-Benachrichtigungsaktionen öffnen die App nicht mehr. Entsperren bleibt nötig.", "Sende Nachrichten mit Kurzbefehlen und Siri.", "„Bei Stille benachrichtigen“ meldet, wenn ein Thema keine Nachrichten empfängt.", "Lies Codeblöcke in Festbreitenschrift und öffne Weblinks auf Wunsch in der App.", "Behebt stumme Ersatzbenachrichtigungen, wenn eine Nachricht nicht geladen werden kann."],
            "es": ["Programa el Horario de silencio, con excepciones para la prioridad 5 y los tópicos que elijas.", "Ejecuta acciones HTTP desde las notificaciones sin abrir la app. Aún debes desbloquear el dispositivo.", "Envía mensajes con Atajos y Siri.", "Usa Avisar si no hay mensajes para recibir una alerta cuando un tópico deje de recibir mensajes.", "Lee bloques de código con letra monoespaciada y elige si abrir los enlaces web en la app.", "Se corrige la falta de sonido en las notificaciones de respaldo cuando no se puede obtener un mensaje."],
            "it": ["Programma gli Orari silenziosi, con eccezioni per la priorità 5 e gli argomenti scelti.", "Esegui le azioni HTTP dalle notifiche senza aprire l’app. Devi comunque sbloccare il dispositivo.", "Invia messaggi con Comandi Rapidi e Siri.", "Usa Avvisa se non arrivano messaggi per ricevere un avviso quando un argomento non riceve messaggi.", "Leggi i blocchi di codice con un carattere monospaziato e scegli se aprire i link web nell’app.", "Corrette le notifiche di ripiego senza suono quando non è possibile recuperare un messaggio."],
            "pl": ["Zaplanuj Godziny ciszy z wyjątkami dla priorytetu 5 i wybranych tematów.", "Uruchamiaj akcje HTTP z powiadomień bez otwierania aplikacji. Nadal trzeba odblokować urządzenie.", "Wysyłaj wiadomości za pomocą Skrótów i Siri.", "Włącz Powiadom o braku wiadomości, aby otrzymać alert, gdy temat nie otrzyma wiadomości.", "Czytaj bloki kodu czcionką o stałej szerokości i wybierz otwieranie linków internetowych w aplikacji.", "Naprawiono brak dźwięku powiadomień zastępczych, gdy nie można pobrać wiadomości."],
            "nl": ["Plan Stille uren, met uitzonderingen voor prioriteit 5 en gekozen onderwerpen.", "Voer HTTP-acties uit vanuit meldingen zonder de app te openen. Ontgrendelen blijft nodig.", "Verstuur berichten met Opdrachten en Siri.", "Gebruik Melding bij stilte om een melding te krijgen als een onderwerp geen berichten ontvangt.", "Lees codeblokken in een lettertype met vaste breedte en open weblinks desgewenst in de app.", "Geen stille terugvalmeldingen meer als een bericht niet kan worden opgehaald."],
            "fr": ["Programmez les Heures calmes, avec des exceptions pour la priorité 5 et les sujets de votre choix.", "Exécutez les actions HTTP des notifications sans ouvrir l’app. Le déverrouillage reste nécessaire.", "Envoyez des messages avec Raccourcis et Siri.", "Utilisez Alerter en cas de silence pour être averti quand un sujet ne reçoit aucun message.", "Lisez les blocs de code à chasse fixe et choisissez d’ouvrir les liens web dans l’app.", "Correction des notifications de secours silencieuses quand un message ne peut pas être récupéré."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testLocalNetworkPermissionAndSubscribeHintResolveInEveryBundledLanguage() throws {
        let key = "NTF-AI couldn't reach this server on your local network. Allow local network access when asked, or turn on Local Network in Settings > NTF-AI, then tap Subscribe again."
        let hint: [String: String] = [
            "de": "NTF-AI konnte diesen Server in deinem lokalen Netzwerk nicht erreichen. Erlaube den Zugriff auf das lokale Netzwerk, wenn danach gefragt wird, oder aktiviere „Lokales Netzwerk“ unter Einstellungen > NTF-AI, und tippe dann erneut auf „Abonnieren“.",
            "en": "NTF-AI couldn't reach this server on your local network. Allow local network access when asked, or turn on Local Network in Settings > NTF-AI, then tap Subscribe again.",
            "es": "NTF-AI no pudo conectar con este servidor de tu red local. Permite el acceso a la red local cuando se te pida, o activa Red local en Ajustes > NTF-AI, y luego toca Suscribirse de nuevo.",
            "fr": "NTF-AI n’a pas pu joindre ce serveur sur votre réseau local. Autorisez l’accès au réseau local lorsque cela vous est demandé, ou activez Réseau local dans Réglages > NTF-AI, puis touchez à nouveau S’abonner.",
            "it": "NTF-AI non è riuscita a raggiungere questo server nella tua rete locale. Consenti l’accesso alla rete locale quando richiesto, oppure attiva Rete locale in Impostazioni > NTF-AI, poi tocca di nuovo Iscriviti.",
            "nl": "NTF-AI kon deze server in je lokale netwerk niet bereiken. Sta toegang tot het lokale netwerk toe als daarom wordt gevraagd, of zet Lokaal netwerk aan in Instellingen > NTF-AI, en tik dan opnieuw op Abonneren.",
            "pl": "NTF-AI nie może połączyć się z tym serwerem w Twojej sieci lokalnej. Zezwól na dostęp do sieci lokalnej, gdy pojawi się prośba, lub włącz Sieć lokalna w Ustawienia > NTF-AI, a następnie ponownie stuknij Subskrybuj."
        ]
        let permission: [String: String] = [
            "de": "NTF-AI verbindet sich nur mit ntfy-Servern",
            "en": "NTF-AI connects to ntfy servers on your local network",
            "es": "NTF-AI se conecta a servidores ntfy",
            "fr": "NTF-AI se connecte aux serveurs ntfy",
            "it": "NTF-AI si collega ai server ntfy",
            "nl": "NTF-AI maakt alleen verbinding met ntfy-servers",
            "pl": "NTF-AI łączy się z serwerami ntfy"
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(hint.keys))
        for (language, text) in hint {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), text, language)
            let purpose = bundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertTrue(purpose.hasPrefix(try XCTUnwrap(permission[language])), language)
        }
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"), "iOS shows (null) in the Local Network prompt without it")
    }

    func testVersion130ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.30.0" })
        XCTAssertEqual(ReleaseNotes.shipped.first?.version, "1.30.0", "the newest release leads")
        XCTAssertEqual(release.bullets.count, 4)
        let expected: [String: [String]] = [
            "en": ["Public ntfy.sh topics can get instant banners even with ntfy.sh credentials saved. For topics that require a login, open the app or refresh to see new messages.", "Public topics added as http://ntfy.sh or www.ntfy.sh can get instant banners too.", "Notification status shows the banner problems it can find for each topic, including a self-hosted server that may not be forwarding wake-ups.", "Background wake-ups can renew instant banners. If banners stop, open NTF-AI to refresh push setup."],
            "de": ["Öffentliche Themen auf ntfy.sh können auch mit gespeicherten ntfy.sh-Zugangsdaten sofortige Banner erhalten. Öffne oder aktualisiere die App, um neue Nachrichten für Themen zu sehen, die eine Anmeldung erfordern.", "Öffentliche Themen, die als http://ntfy.sh oder www.ntfy.sh hinzugefügt wurden, können jetzt auch sofortige Banner bekommen.", "Der Benachrichtigungsstatus zeigt für jedes Thema die Banner-Probleme, die er finden kann, auch einen eigenen Server, der Wecksignale möglicherweise nicht weiterleitet.", "Wenn das System NTF-AI im Hintergrund aktiviert, kann die App den Empfang sofortiger Banner verlängern. Bleiben die Banner aus, öffne NTF-AI, um die Push-Einrichtung zu aktualisieren."],
            "es": ["Los tópicos públicos de ntfy.sh pueden recibir avisos instantáneos aunque tengas guardadas credenciales de ntfy.sh. Si un tópico requiere iniciar sesión, abre o actualiza la app para ver sus mensajes nuevos.", "Los tópicos públicos añadidos como http://ntfy.sh o www.ntfy.sh también pueden recibir avisos instantáneos.", "Estado de notificaciones muestra los problemas con los avisos que puede detectar en cada tópico, incluido un servidor propio que quizá no esté reenviando las activaciones.", "Cuando el sistema activa NTF-AI en segundo plano, la app puede renovar los avisos instantáneos. Si dejan de llegar, abre NTF-AI para actualizar la configuración de las notificaciones."],
            "it": ["Gli argomenti pubblici su ntfy.sh possono ricevere banner istantanei anche se hai salvato le credenziali di ntfy.sh. Per gli argomenti che richiedono l’accesso, apri o aggiorna l’app per vedere i nuovi messaggi.", "Anche gli argomenti pubblici aggiunti come http://ntfy.sh o www.ntfy.sh possono ricevere banner istantanei.", "Stato notifiche mostra i problemi dei banner che riesce a trovare per ogni argomento, compreso un server tuo che potrebbe non inoltrare i risvegli.", "Quando il sistema riattiva NTF-AI in background, l’app può rinnovare la ricezione dei banner istantanei. Se smettono di arrivare, apri NTF-AI per aggiornare la configurazione delle notifiche."],
            "pl": ["Publiczne tematy na ntfy.sh mogą otrzymywać natychmiastowe banery nawet po zapisaniu danych logowania do ntfy.sh. Aby zobaczyć nowe wiadomości z tematów wymagających logowania, otwórz lub odśwież aplikację.", "Publiczne tematy dodane jako http://ntfy.sh lub www.ntfy.sh też mogą dostawać natychmiastowe banery.", "Stan powiadomień pokazuje problemy z banerami, które może wykryć dla każdego tematu, także własny serwer, który może nie przekazywać wybudzeń.", "Gdy system wybudzi NTF-AI w tle, aplikacja może odnowić odbieranie natychmiastowych banerów. Jeśli przestaną przychodzić, otwórz NTF-AI, aby odświeżyć konfigurację powiadomień."],
            "nl": ["Openbare onderwerpen op ntfy.sh kunnen ook met opgeslagen ntfy.sh-inloggegevens directe meldingen krijgen. Voor onderwerpen waarvoor je moet inloggen, open of vernieuw je de app om nieuwe berichten te zien.", "Openbare onderwerpen die zijn toegevoegd als http://ntfy.sh of www.ntfy.sh kunnen ook directe meldingen krijgen.", "Meldingsstatus toont per onderwerp de problemen met meldingen die het kan vinden, ook een eigen server die wekberichten mogelijk niet doorstuurt.", "Als het systeem NTF-AI op de achtergrond activeert, kan de app de ontvangst van directe meldingen verlengen. Komen ze niet meer binnen, open dan NTF-AI om de meldingsinstellingen te vernieuwen."],
            "fr": ["Les sujets publics sur ntfy.sh peuvent recevoir des bannières instantanées même si des identifiants de connexion ntfy.sh sont enregistrés. Pour les sujets qui nécessitent une connexion, ouvrez ou actualisez l’app pour voir les nouveaux messages.", "Les sujets publics ajoutés en tant que http://ntfy.sh ou www.ntfy.sh peuvent aussi recevoir des bannières instantanées.", "État des notifications indique les problèmes de bannières qu’il peut détecter pour chaque sujet, y compris un serveur personnel qui ne transmet peut-être pas les réveils.", "Lorsque le système réactive NTF-AI en arrière-plan, l’app peut renouveler la réception des bannières instantanées. Si elles cessent d’arriver, ouvrez NTF-AI pour actualiser la configuration des notifications."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        XCTAssertEqual(release.bullets, expected["en"])
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion129ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.29.0" })
        XCTAssertEqual(release.bullets.count, 3)
        let expected: [String: [String]] = [
            "en": ["Topics on ntfy.sh now get instant banners: ntfy-me.com watches them and wakes your device when a message arrives.", "Your own ntfy server gets instant banners with its usual setting, upstream-base-url: https://ntfy.sh, so the official ntfy app keeps working too.", "You can turn this off anytime in Settings."],
            "de": ["Themen auf ntfy.sh bekommen jetzt sofortige Banner: ntfy-me.com beobachtet sie und weckt dein Gerät, wenn eine Nachricht ankommt.", "Dein eigener ntfy-Server bekommt sofortige Banner mit der üblichen Einstellung upstream-base-url: https://ntfy.sh, und die offizielle ntfy-App funktioniert weiter.", "Du kannst das jederzeit in den Einstellungen ausschalten."],
            "es": ["Los tópicos de ntfy.sh ahora reciben avisos instantáneos: ntfy-me.com los vigila y activa tu dispositivo cuando llega un mensaje.", "Tu propio servidor ntfy recibe avisos instantáneos con su ajuste habitual, upstream-base-url: https://ntfy.sh, y la app oficial de ntfy sigue funcionando.", "Puedes desactivarlo cuando quieras en Ajustes."],
            "it": ["Gli argomenti su ntfy.sh ora ricevono banner istantanei: ntfy-me.com li osserva e riattiva il dispositivo quando arriva un messaggio.", "Il tuo server ntfy riceve banner istantanei con la sua impostazione abituale, upstream-base-url: https://ntfy.sh, e l’app ufficiale di ntfy continua a funzionare.", "Puoi disattivarlo quando vuoi in Impostazioni."],
            "pl": ["Tematy na ntfy.sh dostają teraz natychmiastowe banery: ntfy-me.com je obserwuje i budzi urządzenie, gdy przychodzi wiadomość.", "Twój własny serwer ntfy dostaje natychmiastowe banery przy zwykłym ustawieniu upstream-base-url: https://ntfy.sh, a oficjalna aplikacja ntfy nadal działa.", "Możesz to w każdej chwili wyłączyć w Ustawieniach."],
            "nl": ["Onderwerpen op ntfy.sh krijgen nu directe meldingen: ntfy-me.com houdt ze in de gaten en wekt je apparaat als er een bericht binnenkomt.", "Je eigen ntfy-server krijgt directe meldingen met de gebruikelijke instelling upstream-base-url: https://ntfy.sh, en de officiële ntfy-app blijft werken.", "Je kunt dit altijd uitzetten in Instellingen."],
            "fr": ["Les sujets sur ntfy.sh reçoivent désormais des bannières instantanées : ntfy-me.com les surveille et réveille votre appareil à l’arrivée d’un message.", "Votre propre serveur ntfy reçoit des bannières instantanées avec son réglage habituel, upstream-base-url: https://ntfy.sh, et l’app ntfy officielle continue de fonctionner.", "Vous pouvez le désactiver à tout moment dans Réglages."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        XCTAssertEqual(release.bullets, expected["en"])
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion128ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.28.0" })
        XCTAssertEqual(release.bullets.count, 7)
        let expected: [String: [String]] = [
            "en": ["Clear all empties Waiting on you at once: touch and hold its header. Undo brings it back.", "Only questions from agents wait on you. Messages with plain buttons, like a smart-home alert, stay in Activity.", "Waiting on you lists the newest question first.", "Plain buttons can be tapped again, and an answered question shows the answer you chose.", "Share a topic, a message or a file, or copy a topic's curl or ntf command.", "Send feedback from Settings, or shake your device to open the form.", "New setting: Use buttons without unlocking lets you answer from the lock screen."],
            "de": ["„Alle entfernen“ leert „Wartet auf dich“ auf einmal: Halte die Überschrift gedrückt. „Widerrufen“ holt alles zurück.", "Nur Fragen von Agenten warten auf dich. Mitteilungen mit einfachen Tasten, etwa ein Smart-Home-Alarm, bleiben unter „Aktivität“.", "„Wartet auf dich“ zeigt die neueste Frage zuerst.", "Einfache Tasten lassen sich erneut tippen, und eine beantwortete Frage zeigt deine gewählte Antwort.", "Teile ein Thema, eine Nachricht oder eine Datei, oder kopiere den curl- oder ntf-Befehl eines Themas.", "Sende Feedback in den Einstellungen, oder schüttle dein Gerät, um das Formular zu öffnen.", "Neue Einstellung: Mit „Tasten ohne Entsperren verwenden“ antwortest du direkt vom Sperrbildschirm."],
            "es": ["Quitar todas vacía Esperando tu respuesta de una vez: mantén pulsado su encabezado. Deshacer lo recupera.", "Solo las preguntas de agentes esperan tu respuesta. Los mensajes con botones simples, como una alerta de domótica, quedan en Actividad.", "Esperando tu respuesta muestra primero la pregunta más reciente.", "Los botones simples se pueden volver a pulsar, y una pregunta respondida muestra la respuesta que elegiste.", "Comparte un tópico, un mensaje o un archivo, o copia el comando curl o ntf de un tópico.", "Envía comentarios desde Ajustes, o agita el dispositivo para abrir el formulario.", "Nuevo ajuste: Usar botones sin desbloquear te deja responder desde la pantalla bloqueada."],
            "it": ["Rimuovi tutte svuota In attesa di una tua risposta in un colpo: tieni premuta l’intestazione. Annulla ripristina tutto.", "Solo le domande degli agenti aspettano una tua risposta. I messaggi con semplici pulsanti, come un avviso della casa smart, restano in Attività.", "In attesa di una tua risposta mostra per prima la domanda più recente.", "I pulsanti semplici si possono toccare di nuovo, e una domanda con risposta mostra la risposta che hai scelto.", "Condividi un argomento, un messaggio o un file, oppure copia il comando curl o ntf di un argomento.", "Invia un feedback da Impostazioni, oppure scuoti il dispositivo per aprire il modulo.", "Nuova impostazione: Usa i pulsanti senza sbloccare ti permette di rispondere dalla schermata di blocco."],
            "pl": ["Wyczyść wszystkie opróżnia Czeka na twoją odpowiedź naraz: przytrzymaj nagłówek. Cofnij przywraca wszystko.", "Na twoją odpowiedź czekają tylko pytania od agentów. Wiadomości ze zwykłymi przyciskami, jak alert inteligentnego domu, zostają w Aktywności.", "Czeka na twoją odpowiedź pokazuje najpierw najnowsze pytanie.", "Zwykłe przyciski można nacisnąć ponownie, a pytanie z odpowiedzią pokazuje wybraną odpowiedź.", "Udostępnij temat, wiadomość lub plik albo skopiuj polecenie curl lub ntf dla tematu.", "Wyślij opinię w Ustawieniach albo potrząśnij urządzeniem, aby otworzyć formularz.", "Nowe ustawienie: Używaj przycisków bez odblokowania pozwala odpowiadać z ekranu blokady."],
            "nl": ["Alles wissen leegt Wacht op jou in één keer: houd de kop ingedrukt. Ongedaan maken zet alles terug.", "Alleen vragen van agents wachten op jou. Berichten met gewone knoppen, zoals een slimme-huismelding, blijven bij Activiteit.", "Wacht op jou toont de nieuwste vraag eerst.", "Gewone knoppen kun je opnieuw tikken, en een beantwoorde vraag toont het antwoord dat je koos.", "Deel een onderwerp, een bericht of een bestand, of kopieer de curl- of ntf-opdracht van een onderwerp.", "Stuur feedback via Instellingen, of schud je apparaat om het formulier te openen.", "Nieuwe instelling: met Knoppen gebruiken zonder ontgrendelen antwoord je vanaf het toegangsscherm."],
            "fr": ["Tout effacer vide En attente de votre réponse d’un coup : maintenez le doigt sur son en-tête. Annuler rétablit tout.", "Seules les questions des agents attendent votre réponse. Les messages avec de simples boutons, comme une alerte domotique, restent dans Activité.", "En attente de votre réponse affiche d’abord la question la plus récente.", "Les boutons simples peuvent être touchés à nouveau, et une question répondue affiche la réponse choisie.", "Partagez un sujet, un message ou un fichier, ou copiez la commande curl ou ntf d’un sujet.", "Envoyez un avis depuis Réglages, ou secouez votre appareil pour ouvrir le formulaire.", "Nouveau réglage : Utiliser les boutons sans déverrouiller vous permet de répondre depuis l’écran verrouillé."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        XCTAssertEqual(release.bullets, expected["en"])
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion127ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.27.0" })
        XCTAssertEqual(release.bullets.count, 5)
        let expected: [String: [String]] = [
            "en": ["Agents can ask for a choice, a number, a date, some text or a short form, and you answer right in the app.", "See which agent is asking, with its name and picture in the app and in notifications.", "Questions with a deadline show the time left, and an agent can withdraw a question it no longer needs.", "Agent reminders: an unanswered question can alert you again, or remind you silently.", "Answer buttons are easier to read in light and dark mode."],
            "de": ["Agenten können nach einer Auswahl, einer Zahl, einem Datum, einem Text oder einem kurzen Formular fragen, und du antwortest direkt in der App.", "Sieh, welcher Agent fragt: mit Name und Bild in der App und in Mitteilungen.", "Fragen mit Frist zeigen die verbleibende Zeit, und ein Agent kann eine Frage zurückziehen, die er nicht mehr braucht.", "Erinnerungen von Agenten: Eine unbeantwortete Frage kann dich erneut benachrichtigen oder lautlos erinnern.", "Antworttasten sind im hellen und dunklen Modus besser lesbar."],
            "es": ["Los agentes pueden pedirte una opción, un número, una fecha, un texto o un formulario breve, y respondes directamente en la app.", "Ve qué agente pregunta, con su nombre y su imagen en la app y en las notificaciones.", "Las preguntas con plazo muestran el tiempo restante, y un agente puede retirar una pregunta que ya no necesita.", "Recordatorios de agentes: una pregunta sin responder puede volver a avisarte o recordártelo sin sonido.", "Los botones de respuesta se leen mejor en modo claro y oscuro."],
            "it": ["Gli agenti possono chiederti una scelta, un numero, una data, un testo o un breve modulo, e rispondi direttamente nell'app.", "Vedi quale agente fa la domanda, con nome e immagine nell'app e nelle notifiche.", "Le domande con una scadenza mostrano il tempo rimasto, e un agente può ritirare una domanda che non gli serve più.", "Promemoria degli agenti: una domanda senza risposta può avvisarti di nuovo o ricordartelo senza suono.", "I pulsanti di risposta si leggono meglio in modalità chiara e scura."],
            "pl": ["Agenci mogą prosić o wybór, liczbę, datę, tekst lub krótki formularz, a ty odpowiadasz bezpośrednio w aplikacji.", "Zobacz, który agent pyta: z nazwą i obrazem w aplikacji i w powiadomieniach.", "Pytania z terminem pokazują pozostały czas, a agent może wycofać pytanie, którego już nie potrzebuje.", "Przypomnienia agentów: pytanie bez odpowiedzi może ponownie cię powiadomić lub przypomnieć bez dźwięku.", "Przyciski odpowiedzi są czytelniejsze w trybie jasnym i ciemnym."],
            "nl": ["Agents kunnen vragen om een keuze, een getal, een datum, een tekst of een kort formulier, en je antwoordt direct in de app.", "Zie welke agent iets vraagt, met naam en afbeelding in de app en in meldingen.", "Vragen met een deadline tonen de resterende tijd, en een agent kan een vraag intrekken die hij niet meer nodig heeft.", "Herinneringen van agents: een onbeantwoorde vraag kan je opnieuw waarschuwen, of je zonder geluid herinneren.", "Antwoordknoppen zijn beter leesbaar in lichte en donkere modus."],
            "fr": ["Les agents peuvent demander un choix, un nombre, une date, un texte ou un court formulaire, et vous répondez directement dans l’app.", "Voyez quel agent pose la question, avec son nom et son image dans l’app et dans les notifications.", "Les questions avec une échéance affichent le temps restant, et un agent peut retirer une question dont il n’a plus besoin.", "Rappels des agents : une question sans réponse peut vous alerter à nouveau, ou vous le rappeler sans son.", "Les boutons de réponse sont plus lisibles en mode clair et sombre."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        XCTAssertEqual(release.bullets, expected["en"])
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion126ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.26.0" })
        XCTAssertEqual(release.bullets.count, 5)
        let expected: [String: [String]] = [
            "en": ["Inbox lists the questions agents ask you under Waiting on you, and everything else under Activity.", "Answer an agent from the notification with a button or a typed reply. A blue tick shows the agent got it.", "Connect an agent shows how to link an agent or a script to a topic.", "Denser message lists: long messages fold to six lines, and row actions are in the long-press menu.", "A new emerald look and app icon."],
            "de": ["Der Eingang zeigt die Fragen deiner Agenten unter „Wartet auf dich“ und alles andere unter „Aktivität“.", "Antworte einem Agenten direkt in der Mitteilung, per Taste oder getippter Antwort. Ein blauer Haken zeigt, dass er sie erhalten hat.", "„Agenten verbinden“ zeigt, wie du einen Agenten oder ein Skript mit einem Thema verbindest.", "Kompaktere Nachrichtenlisten: Lange Nachrichten werden auf sechs Zeilen gekürzt, Aktionen findest du im Kontextmenü.", "Ein neuer smaragdgrüner Look und ein neues App-Symbol."],
            "es": ["Recibidos muestra las preguntas de tus agentes en «Esperando tu respuesta» y todo lo demás en «Actividad».", "Responde a un agente desde la notificación con un botón o escribiendo. Una marca azul indica que el agente la recibió.", "«Conectar un agente» explica cómo conectar un agente o un script a un tópico.", "Listas de mensajes más compactas: los mensajes largos se pliegan a seis líneas y las acciones están en el menú al mantener pulsado.", "Un nuevo aspecto esmeralda y un nuevo icono."],
            "it": ["In arrivo mostra le domande dei tuoi agenti in «In attesa di una tua risposta» e tutto il resto in «Attività».", "Rispondi a un agente dalla notifica con un pulsante o scrivendo. Una spunta blu indica che l'agente l'ha ricevuta.", "«Collega un agente» spiega come collegare un agente o uno script a un argomento.", "Elenchi di messaggi più compatti: i messaggi lunghi si riducono a sei righe e le azioni sono nel menu a pressione prolungata.", "Un nuovo aspetto smeraldo e una nuova icona."],
            "pl": ["Odebrane pokazuje pytania od agentów w sekcji „Czeka na twoją odpowiedź”, a resztę w sekcji „Aktywność”.", "Odpowiadaj agentowi prosto z powiadomienia, przyciskiem lub wpisanym tekstem. Niebieski znacznik oznacza, że agent ją otrzymał.", "„Połącz agenta” pokazuje, jak połączyć agenta lub skrypt z tematem.", "Gęstsze listy wiadomości: długie wiadomości zwijają się do sześciu wierszy, a akcje są w menu po przytrzymaniu.", "Nowy szmaragdowy wygląd i nowa ikona."],
            "nl": ["Inbox toont de vragen van je agents onder ‘Wacht op jou’ en al het andere onder ‘Activiteit’.", "Beantwoord een agent vanuit de melding met een knop of een getypt antwoord. Een blauw vinkje laat zien dat de agent het heeft ontvangen.", "‘Agent koppelen’ laat zien hoe je een agent of script aan een onderwerp koppelt.", "Compactere berichtenlijsten: lange berichten worden ingekort tot zes regels en acties staan in het menu bij lang drukken.", "Een nieuwe smaragdgroene stijl en een nieuw app-icoon."],
            "fr": ["Réception affiche les questions de vos agents sous « En attente de votre réponse » et tout le reste sous « Activité ».", "Répondez à un agent depuis la notification, avec un bouton ou une réponse saisie. Une coche bleue indique que l’agent l’a reçue.", "« Connecter un agent » explique comment relier un agent ou un script à un sujet.", "Listes de messages plus denses : les longs messages se replient sur six lignes et les actions sont dans le menu par appui long.", "Un nouveau look émeraude et une nouvelle icône."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion124ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.24.0" })
        XCTAssertEqual(release.bullets.count, 6)
        let expected: [String: [String]] = [
            "en": ["The next poll fetches messages missed by dropped pushes, while they remain in the server cache.", "Use Read messages in Shortcuts to read stored messages from a topic.", "Choose Topics saved in account when adding a subscription on a server you are signed in to.", "Notification status now shows iOS settings that hide or delay alerts.", "See when you subscribed in Topic details. Older subscriptions show Unknown.", "Long message links work in full, words wrap normally, and Markdown code follows text size changes."],
            "de": ["Beim nächsten Abruf werden durch ausgebliebene Pushs verpasste Nachrichten aus dem Servercache geladen.", "Lies gespeicherte Nachrichten eines Themas mit „Nachrichten lesen“ in der App „Kurzbefehle“.", "Abonniere „Im Konto gespeicherte Themen“, wenn du beim Server angemeldet bist.", "Der Benachrichtigungsstatus zeigt jetzt iOS-Einstellungen, die Hinweise ausblenden oder verzögern.", "Die Themendetails zeigen, wann du ein Thema abonniert hast. Bei älteren Abos steht „Unbekannt“.", "Lange Links funktionieren vollständig. Text wird normal umbrochen und Markdown-Code folgt der Textgröße."],
            "es": ["Los mensajes perdidos por notificaciones push que no llegaron se recuperan en la próxima consulta, si siguen en la caché del servidor.", "Usa Leer mensajes en Atajos para leer los mensajes guardados de un tópico.", "Al añadir una suscripción en un servidor donde has iniciado sesión, elige Tópicos guardados en la cuenta.", "Estado de notificaciones ahora muestra los ajustes de iOS que ocultan o retrasan los avisos.", "Consulta cuándo te suscribiste en Detalles del tópico. Las suscripciones anteriores muestran Desconocida.", "Los enlaces largos funcionan completos, las palabras se ajustan con normalidad y el código Markdown sigue los cambios del tamaño de texto."],
            "it": ["I messaggi persi per notifiche push non arrivate vengono recuperati alla prossima verifica, se sono ancora nella cache del server.", "Usa Leggi messaggi in Comandi Rapidi per leggere i messaggi salvati di un argomento.", "Quando aggiungi un’iscrizione su un server a cui hai effettuato l’accesso, scegli Argomenti salvati nell’account.", "Stato notifiche ora mostra le impostazioni di iOS che nascondono o ritardano gli avvisi.", "In Dettagli dell’argomento puoi vedere quando ti sei iscritto. Le iscrizioni precedenti mostrano Sconosciuta.", "I link lunghi funzionano per intero, le parole vanno a capo normalmente e il codice Markdown segue le modifiche alla dimensione del testo."],
            "pl": ["Wiadomości pominięte z powodu niedostarczonych powiadomień push zostaną pobrane przy następnym odpytywaniu, jeśli są jeszcze w pamięci podręcznej serwera.", "Użyj akcji Odczytaj wiadomości w Skrótach, aby czytać zapisane wiadomości z tematu.", "Dodając subskrypcję na serwerze, na którym jesteś zalogowany, wybierz Tematy zapisane na koncie.", "Stan powiadomień pokazuje teraz ustawienia iOS, które ukrywają lub opóźniają alerty.", "W sekcji Szczegóły tematu sprawdzisz datę subskrypcji. Starsze subskrypcje mają datę Nieznana.", "Długie linki działają w całości, słowa zawijają się prawidłowo, a kod Markdown dostosowuje się do zmian rozmiaru tekstu."],
            "nl": ["Berichten die door gemiste pushmeldingen ontbraken, worden bij de volgende controle opgehaald zolang ze nog in de servercache staan.", "Gebruik Berichten lezen in Opdrachten om opgeslagen berichten van een onderwerp te lezen.", "Kies Onderwerpen opgeslagen in account wanneer je een abonnement toevoegt op een server waarop je bent ingelogd.", "Meldingsstatus toont nu iOS-instellingen die meldingen verbergen of vertragen.", "In Onderwerpdetails zie je wanneer je je hebt geabonneerd. Bij oudere abonnementen staat Onbekend.", "Lange links werken volledig, woorden lopen normaal door en Markdown-code volgt wijzigingen in de tekstgrootte."],
            "fr": ["Les messages manqués à cause de notifications push non reçues sont récupérés à la prochaine interrogation, s’ils sont encore dans le cache du serveur.", "Utilisez Lire les messages dans Raccourcis pour lire les messages enregistrés d’un sujet.", "Choisissez Sujets enregistrés dans le compte lors de l’ajout d’un abonnement sur un serveur auquel vous êtes connecté.", "Dans État des notifications, consultez les réglages iOS qui masquent ou retardent les alertes.", "Consultez votre date d’abonnement dans Détails du sujet. Les anciens abonnements indiquent Inconnue.", "Les liens longs fonctionnent en entier, les mots passent normalement à la ligne et le code Markdown suit les changements de taille du texte."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    private func stringUnits(_ node: Any) -> [[String: Any]] {
        guard let object = node as? [String: Any] else { return [] }
        if let unit = object["stringUnit"] as? [String: Any] { return [unit] }
        return object.values.flatMap(stringUnits)
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|d|@)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            let token = String(text[Range($0.range, in: text)!])
            return token.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    func testGermanPluralFormattingAndSharedNotificationCopy() throws {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        let locale = Locale(identifier: "de_DE")
        XCTAssertNil(DeliveryHealthCopy.retryIntervalLocale(language: "en", locale: locale))
        XCTAssertEqual(DeliveryHealthCopy.retryIntervalLocale(language: "pl", locale: Locale(identifier: "pl_PL")), Locale(identifier: "pl_PL"))
        func value(_ key: String, _ count: Int) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: locale, count)
        }
        XCTAssertEqual(value("%lld hours", 1), "1 Stunde")
        XCTAssertEqual(value("%lld hours", 2), "2 Stunden")
        XCTAssertEqual(value("%lld notifications", 1), "1 Benachrichtigung")
        XCTAssertEqual(value("%lld notifications", 0), "0 Benachrichtigungen")
        XCTAssertEqual(value("%lld notifications", 23), "23 Benachrichtigungen")
        XCTAssertEqual(bundle.localizedString(forKey: "Notification state synchronized", value: nil, table: nil), "Benachrichtigungsstatus synchronisiert")
        // The upstream MIT entry, by name: NTF-AI's own GPL-3.0 entry leads the list since 1.27.
        let canonicalMIT = try XCTUnwrap(OpenSourceLicenses.components.first { $0.name == "ntfy for iOS" }).notice
        XCTAssertTrue(canonicalMIT.contains("Permission is hereby granted"))
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil).first { $0.pathExtension == "appex" })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        let extensionGerman = try XCTUnwrap(extensionBundle.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(extensionGerman.localizedString(forKey: "Notification state synchronized", value: nil, table: nil), "Benachrichtigungsstatus synchronisiert")
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"), "NTF-AI nutzt die Kamera nur, um QR-Codes für Themen zu scannen, die du abonnieren möchtest.")
        // Review eligibility uses this prefix in every bundled language, including old messages.
        // A future translator can fix an inconsistent prefix entirely in the catalog.
        for language in Bundle.main.localizations where language != "Base" {
            let localized = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let prefix = localized.localizedString(forKey: Store.testMessagePrefix, value: nil, table: nil)
            for key in [
                "This is a test notification from NTF-AI. Your topic is ready.",
                "This is a test notification from NTF-AI. It has a priority of %lld. If you send another one, it may look different."
            ] {
                XCTAssertTrue(localized.localizedString(forKey: key, value: nil, table: nil).hasPrefix(prefix),
                              "\(language): test-message copy must retain its translated prefix")
            }
        }
        XCTAssertTrue(Store.isOwnTestMessage("Dies ist eine Testnachricht von NTFY me. Dein Thema ist bereit."))
        XCTAssertTrue(Store.isOwnTestMessage("This is a test notification from NTFY me. Your topic is ready."))
        XCTAssertFalse(Store.isOwnTestMessage("A real server message"))
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://localization.invalid", topic: "locale-change")
        let messages = [
            Message(id: "de-test", time: 1_800_000_000, event: "message", topic: "locale-change", message: "Dies ist eine Testnachricht von NTFY me. Dein Thema ist bereit."),
            Message(id: "en-test", time: 1_800_000_001, event: "message", topic: "locale-change", message: "This is a test notification from NTFY me. Your topic is ready."),
            Message(id: "real", time: 1_800_000_002, event: "message", topic: "locale-change", message: "Backup complete")
        ]
        store.save(notificationsFromMessages: messages, withSubscription: subscription)
        messages.forEach { store.recordPresentation(message: $0, baseUrl: "https://localization.invalid") }
        XCTAssertEqual(store.presentedDeliveries().count, 1, "English and German test messages remain excluded across language changes")
        let locked = Notification(context: store.context)
        locked.encryption = NotificationEncryption.locked.rawValue
        locked.message = "Dies ist ein gespeicherter Platzhalter in einer anderen Sprache"
        XCTAssertEqual(locked.formatMessage(), TopicEncryption.lockedPlaceholder)
        XCTAssertEqual(locked.formatMessage(bundle: bundle), bundle.localizedString(forKey: "Encrypted message", value: nil, table: nil))
        locked.encryption = NotificationEncryption.none.rawValue
        XCTAssertEqual(locked.formatMessage(), locked.message, "readable server content must stay verbatim")
    }
}
