#if NTFY_NSE_TEST_HOST
@testable import ntfy
#endif
import UserNotifications
import CoreData
import CryptoKit
import os.log

/// Persists incoming messages in Core Data and fetches notification content from the original
/// server when a "poll_request" wakeup is received.
///
/// Note that the app extension does not run as part of the main app, so log messages are not printed in the main Xcode window. To debug,
/// select Debug -> Attach to Process by PID or Name, and select the extension. Don't forget to set a breakpoint, or you're not gonna have a good time.
class NotificationService: UNNotificationServiceExtension {
    private let tag = "NotificationService"
    private var store: Store?
    var makeStore: () -> Store = { Store.shared } // Test host can exercise an NSE-first disk migration.
    
    private let attempt = NotificationBestAttempt(UNMutableNotificationContent())
    var bestAttemptContent: UNMutableNotificationContent? {
        get { attempt.content }
        set { if let newValue { attempt.replace(with: newValue) } }
    }
    private var deliveryGate: NotificationDeliveryGate?
    private let presentationLock = NSLock()
    var soundLibrary: TopicSoundLibrary = .shared
    private var processedMessage: (message: Message, soundName: String?)?
    private var presentationMessage: (message: Message, soundName: String?)? {
        get { presentationLock.lock(); defer { presentationLock.unlock() }; return processedMessage }
        set { presentationLock.lock(); defer { presentationLock.unlock() }; processedMessage = newValue }
    }
    
    private var alertIdentity: (message: Message, baseUrl: String)? {
        get { presentationLock.lock(); defer { presentationLock.unlock() }; return processedIdentity }
        set {
            // Capture evidence before asynchronous I/O. Expiry uses only this snapshot, never a
            // queue, shared file lock, or database fetch. Uncertainty deliberately allows delivery.
            let alerted = newValue.map { store?.wasAlerted(message: $0.message, baseUrl: $0.baseUrl) ?? false } ?? false
            let muted = newValue.map { store?.isTopicMuted(baseUrl: $0.baseUrl, topic: $0.message.topic) ?? false } ?? false
            presentationLock.lock(); defer { presentationLock.unlock() }
            processedIdentity = newValue
            // Our own claim (made before the fetch) reads as "alerted"; it must not silence us.
            expiryIsQuiet = (alerted && claimedAlert != true) || muted
        }
    }
    private var quietHours = QuietHours.load()
    private var expiryIsQuiet = false
    private var processedIdentity: (message: Message, baseUrl: String)?
    /// Settled before the slow steps of a presentation: true when this extension alerts the
    /// message, false when the app or an earlier delivery already did. Nil means not claimed.
    private var alertClaim: Bool? {
        get { presentationLock.lock(); defer { presentationLock.unlock() }; return claimedAlert }
        set {
            presentationLock.lock(); defer { presentationLock.unlock() }
            claimedAlert = newValue
            if newValue == false { expiryIsQuiet = true }
        }
    }
    private var claimedAlert: Bool?
    /// One monotonic deadline from entry, shared by every step (review-130 #5).
    private(set) var deadline = ExtensionDeadline()
    /// Tests shorten the self-imposed cutoff.
    var processingBudget: TimeInterval = NotificationServiceTiming.processingBudget

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        // On a Mac this process can outlive the banner and receive its taps; pass them to the app.
        // The deadline, the one-shot gate, the fallback and the watchdog come first, before any store
        // work (review-130b #5): a slow store open can't delay the handoff past the system's limit.
        deadline = ExtensionDeadline(budget: processingBudget)
        self.deliveryGate = NotificationDeliveryGate { output in
            // Release builds expose only presentation metadata, never message or account content.
            os_log("NSE handoff soundRequested=%{public}d interruptionLevel=%{public}ld",
                   log: OSLog(subsystem: Config.bundleIdBase, category: "NotificationPresentation"), type: .info,
                   output.sound == nil ? 0 : 1, output.interruptionLevel.rawValue)
            contentHandler(output)
        }
        // At the deadline, hand off the best attempt ourselves, before iOS cuts the extension off;
        // anything that lands later finds the one-shot gate closed.
        let gate = deliveryGate
        DispatchQueue.global().asyncAfter(deadline: .now() + processingBudget) { [weak self] in
            guard let self, self.deliveryGate === gate, gate?.isPending == true else { return }
            Log.w(self.tag, "Deadline reached; delivering the best attempt")
            if let content = self.bestAttemptContent { self.deliver(content, expiring: true) }
        }
        presentationMessage = nil
        presentationLock.lock(); processedIdentity = nil; expiryIsQuiet = false; presentationLock.unlock()
        alertClaim = nil
        self.bestAttemptContent = (fallbackContent(request).mutableCopy() as? UNMutableNotificationContent)
        NotificationResponseRelay.installInExtensionIfNeeded()
        NotificationExtensionLifetime.shared.requestStarted()
        if self.store == nil { self.store = makeStore() }
        quietHours = QuietHours.load()

        if let bestAttemptContent = bestAttemptContent {
            let userInfo = bestAttemptContent.userInfo
            guard let message = Message.from(userInfo: userInfo) else {
                Log.w(tag, "Message cannot be parsed from userInfo", userInfo)
                deliver(fallbackContent(request))
                return
            }
            Log.d(
                tag,
                "\(#function) event=\(message.event), topic=\(message.topic), pollId=\(message.pollId ?? "<nil>"), baseUrl=\(userInfo["base_url"] as? String ?? "<nil>")"
            )
            switch message.event {
            case "poll_request":
                handlePollRequest(request, bestAttemptContent, message)
            case "message", "message_clear", "message_delete":
                let baseUrl = userInfo["base_url"]  as? String ?? Config.appBaseUrl // messages only come for the main server
                handleMessage(request, bestAttemptContent, baseUrl, message)
            default:
                Log.w(tag, "Irrelevant message received", message)
                deliver(fallbackContent(request))
            }
        } else {
            deliver(fallbackContent(request))
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content,
        // otherwise the original push payload will be used.

        Log.w(tag, "\(#function): delivering best attempt content")
        if let bestAttemptContent = bestAttemptContent {
            deliver(bestAttemptContent, expiring: true)
        }
    }

    /// The push exactly as received, unless its text is an end-to-end encrypted body: a server that
    /// sends full messages (not poll requests) puts the JWE in the alert, and every early-exit path
    /// would otherwise show that ciphertext on the lock screen.
    /// False once this request was handed to iOS: late callbacks (reconcile, attachment, avatar,
    /// fetch) then stop before any store or presentation work.
    private var isPending: Bool { deliveryGate?.isPending == true }

    private func fallbackContent(_ request: UNNotificationRequest) -> UNNotificationContent {
        UNNotificationContent.encryptionSafeFallback(request.content)
    }

    private func deliver(_ content: UNNotificationContent, expiring: Bool = false, quietReady: Bool = false) {
        if !expiring, !quietReady, let store {
            store.quietAlerts.flush { self.deliver(content, quietReady: true) }
            return
        }
        let final = content.mutableCopy() as! UNMutableNotificationContent
        if let presentationMessage { final.configureInterruption(message: presentationMessage.message, soundName: presentationMessage.soundName) }
        if !expiring { final.applyTopicMute() }
        let handoff = { (output: UNNotificationContent) -> Bool in
            // iOS gets an immutable snapshot: nothing still running can change what it shows.
            let snapshot = (output.copy() as? UNNotificationContent) ?? output
            guard self.deliveryGate?.deliver(snapshot) == true else {
                Log.w(self.tag, "Ignoring late notification delivery after the content handler already fired")
                return false
            }
            NotificationExtensionLifetime.shared.requestFinished()
            return true
        }
        if expiring {
            store?.quietAlerts.cancelScheduling()
            presentationLock.lock()
            var info = final.userInfo
            if let identity = processedIdentity {
                info["base_url"] = identity.baseUrl; info["topic"] = identity.message.topic
            }
            var quiet = expiryIsQuiet || quietHours.isQuiet(userInfo: info) || AgentAck.isAck(tags: processedIdentity?.message.tags)
            let identity = processedIdentity
            let unresolved = claimedAlert == nil
            presentationLock.unlock()
            // No claim settled yet (review-130b #5): if the app holds the alert lock, it may be
            // alerting this message, so this handoff is passive; if no one does, claim the message
            // first, so a later app poll stays quiet, then sound the fallback.
            if !quiet, unresolved, let identity, let store {
                switch store.claimAtExpiry(message: identity.message, baseUrl: identity.baseUrl) {
                case .claimed: break
                case .alreadyAlerted, .contended: quiet = true
                }
            }
            if quiet { final.sound = nil; final.interruptionLevel = .passive; final.relevanceScore = 0 }
            _ = handoff(final)
            return
        }
        // Passive content prevents a duplicate banner/sound. Fully removing the Notification Center
        // entry would require Apple's notification-filtering entitlement; empty content is unsafe.
        let passive = {
            let quiet = final.mutableCopy() as! UNMutableNotificationContent
            quiet.sound = nil
            quiet.interruptionLevel = .passive
            quiet.relevanceScore = 0
            _ = handoff(quiet)
        }
        if let claim = alertClaim {
            if claim { _ = handoff(final) } else { passive() }
            return
        }
        guard let identity = alertIdentity, let store else {
            _ = handoff(final)
            return
        }
        let gate = deliveryGate
        store.deliverAlert(message: identity.message, baseUrl: identity.baseUrl, recordBeforeDelivery: true,
                           stillNeeded: { gate?.isPending == true }, delivery: { finished in
            finished(handoff(final))
        }, suppressed: passive)
    }

    /// Records the alert for a stored message before category registration and the attachment
    /// download, not at the handoff. Once the content handler is pending, iOS shows this push whether
    /// the extension finishes, expires (best attempt) or is killed (original payload), and expiry
    /// itself may not touch the store. A later presenting poll then sees `alerted` and stays quiet.
    private func claimAlert(then next: @escaping () -> Void) {
        guard let identity = alertIdentity, let store else { next(); return }
        let gate = deliveryGate
        let proceed = { (alerting: Bool) in
            self.alertClaim = alerting
            DispatchQueue.global(qos: .userInitiated).async(execute: next)
        }
        // If expiry already handed off, neither closure runs and nothing remains to present.
        store.deliverAlert(message: identity.message, baseUrl: identity.baseUrl, recordBeforeDelivery: true,
                           stillNeeded: { gate?.isPending == true },
                           delivery: { _ in proceed(true) }, suppressed: { proceed(false) })
    }
    
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ received: Message) {
        if received.event == "message" { alertIdentity = (received, baseUrl) }
        if AgentAck.isAck(tags: received.tags) {
            // Silent from the first moment, so even the expiry fallback makes no sound.
            content.sound = nil
            content.interruptionLevel = .passive
            content.relevanceScore = 0
            bestAttemptContent = content
        }
        // Save notification first so attachment downloads can update persistent state. What comes back
        // is the message as stored: decrypted for an end-to-end encrypted topic (or its "Encrypted
        // message" placeholder), so the banner never shows ciphertext and matches the in-app row.
        guard let result = store?.ingest(pushedMessage: received, baseUrl: baseUrl, topic: received.topic) else {
            Log.w(tag, "Subscription \(topicUrl(baseUrl: baseUrl, topic: received.topic)) unknown")
            deliver(fallbackContent(request))
            return
        }
        if case .reconcile(let poll) = result {
            let placeholder = NotificationHealth.fetchFailureContent(request.content, topic: received.topic, baseUrl: baseUrl, event: received.event)
            bestAttemptContent = placeholder
            ApiService.shared.poll(poll, timeout: deadline.timeout(NotificationServiceTiming.pollTimeout, reserve: 3)) { messages, _ in
                // Handed off already (expiry): no store or presentation work after it.
                guard self.isPending else { return }
                guard let messages else { self.deliver(placeholder); return }
                guard let presentations = Store.shared.save(notificationsFromMessages: messages, polledWith: poll) else {
                    self.deliver(placeholder)
                    return
                }
                if let latest = presentations.last(where: { $0.sequence == received.sequence }) {
                    self.handlePresentation(request, content, baseUrl, latest, reconciled: true)
                } else {
                    self.deliverSynchronizationReceipt(content, baseUrl, received)
                }
            }
            return
        }
        if case .handled = result {
            deliverSynchronizationReceipt(content, baseUrl, received)
            return
        }
        if case .acknowledged(let ack, let questionTitle) = result {
            deliverAcknowledgement(request, content, baseUrl, ack, questionTitle: questionTitle)
            return
        }
        if case .answered = result {
            // The person's own answer, perhaps from their other device: its question already shows
            // it. Dropping the push needs the filtering entitlement, so it is a passive receipt
            // removed right after delivery, and again when the app next runs.
            content.relevanceScore = 0
            deliverSynchronizationReceipt(content, baseUrl, received)
            let identifier = request.identifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            }
            return
        }
        guard case .stored(let message) = result else {
            // A re-posted copy of an encrypted message this topic already has: it is not stored again.
            // Empty content would NOT hide the banner (that needs the filtering entitlement, which this
            // app doesn't have); iOS would show the server's original alert. Show the neutral
            // "Encrypted message" placeholder instead.
            Log.w(tag, "Replayed encrypted message; not storing it, showing the neutral placeholder")
            deliver(UNNotificationContent.replayedEncryptedMessage(request.content))
            return
        }
        handlePresentation(request, content, baseUrl, message)
    }

    private func deliverSynchronizationReceipt(_ content: UNMutableNotificationContent, _ baseUrl: String, _ received: Message) {
        // A custom relay may wrap a control in an alert. Suppressing that alert entirely needs
        // the filtering entitlement; use a passive receipt instead of the original placeholder.
        content.title = "ntfy"
        content.body = String(localized: "Notification state synchronized")
        content.subtitle = ""
        content.attachments = []
        content.categoryIdentifier = ""
        content.sound = nil
        content.interruptionLevel = .passive
        content.badge = NSNumber(value: Store.shared.totalUnreadCount())
        content.userInfo = received.toUserInfo()
        content.userInfo["base_url"] = baseUrl
        deliver(content)
    }

    /// An agent's ack (ACK-SPEC). The store already took the question out of Waiting and removed its
    /// banner. This push still has to show something: dropping it needs Apple's filtering
    /// entitlement. So it is a passive, silent receipt with the lowest relevance, whatever priority
    /// the agent sent. With "Show agent confirmations" off it is a neutral receipt that is removed
    /// right after delivery, and again when the app next runs.
    private func deliverAcknowledgement(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ ack: Message, questionTitle: String?) {
        let shows = AgentAck.showsConfirmations()
        let note = AgentAck.note(fromBody: ack.message)
        let topicName = store?.subscriptionDisplayName(baseUrl: baseUrl, topic: ack.topic) ?? ack.topic
        if shows {
            content.title = questionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? topicName
            content.body = [String(localized: "Agent got it"), note].compactMap { $0 }.joined(separator: "\n")
        } else {
            content.title = "ntfy"
            content.body = String(localized: "Notification state synchronized")
        }
        content.subtitle = ""
        content.attachments = []
        content.categoryIdentifier = ""
        content.sound = nil
        content.interruptionLevel = .passive
        content.relevanceScore = 0
        content.threadIdentifier = topicUrl(baseUrl: baseUrl, topic: ack.topic)
        content.badge = NSNumber(value: Store.shared.totalUnreadCount())
        content.userInfo = ack.toUserInfo()
        content.userInfo["base_url"] = baseUrl
        deliver(content)
        if !shows {
            // Best effort: the extension may be suspended before this runs. The app sweeps again.
            let identifier = request.identifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            }
        }
    }

    private func handlePresentation(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, reconciled: Bool = false) {
        // The best attempt stays what it is (a poll_request's ready placeholder, or the push as
        // received) until `presentClaimed` has formatted this message (review-130b #5).
        guard isPending else { return }
        // A poll_request claimed its alert before fetching: the row exists now, so mark it.
        if let claim = alertClaim {
            if claim { store?.recordPresentation(message: message, baseUrl: baseUrl) }
            DispatchQueue.global(qos: .userInitiated).async { self.presentClaimed(content, baseUrl, message, reconciled: reconciled) }
            return
        }
        claimAlert { self.presentClaimed(content, baseUrl, message, reconciled: reconciled) }
    }

    private func presentClaimed(_ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, reconciled: Bool) {
        guard isPending else { return }
        let user = store?.getBasicUser(baseUrl: baseUrl)
        let displayName = store?.subscriptionDisplayName(baseUrl: baseUrl, topic: message.topic)
        let soundName = store?.topicSoundName(baseUrl: baseUrl, topic: message.topic, library: soundLibrary)
        content.modify(
            message: message,
            baseUrl: baseUrl,
            displayName: displayName,
            soundName: soundName,
            categoryRegistrationTimeout: NotificationServiceTiming.categoryRegistrationTimeout
        )
        presentationMessage = (message, soundName)
        bestAttemptContent = content
        content.attachImageIfNeeded(
            message: message,
            baseUrl: baseUrl,
            user: user,
            timeout: deadline.timeout(reconciled ? NotificationServiceTiming.reconciliationAttachmentTimeout : NotificationServiceTiming.attachmentTimeout)
        ) {
            guard self.isPending else { return }
            self.presentAsAgent(content, baseUrl: baseUrl, message: message, reconciled: reconciled)
        }
    }

    /// An agent's message with an `@name` tag shows as a message from that agent (SPEC 6). Its
    /// picture is fetched only where `AgentIdentity.avatarAllowed` says so; any failure, including a
    /// build without the Communication Notifications capability, delivers today's banner.
    private func presentAsAgent(_ content: UNMutableNotificationContent, baseUrl: String, message: Message, reconciled: Bool) {
        guard let name = AgentIdentity.name(tags: message.tags) else { deliver(content); return }
        let conversation = AgentIdentity.conversationIdentifier(topicURL: topicUrl(baseUrl: baseUrl, topic: message.topic), name: name)
        let finish = { (avatar: Data?) in
            guard self.isPending else { return }
            let shown = AgentIdentity.communicationContent(content, name: name, avatar: avatar, conversation: conversation,
                                                           donate: message.encryption != .decrypted)
            self.bestAttemptContent = (shown.mutableCopy() as? UNMutableNotificationContent) ?? content
            self.deliver(shown)
        }
        AgentAvatarStore.shared.avatar(for: message, baseUrl: baseUrl, network: !reconciled) { finish($0) }
    }
    
    private func handlePollRequest(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ pollRequest: Message) {
        // The server's mutable alert omits aps.sound. Every fallback needs an explicit policy.
        content.configureInterruption(message: pollRequest)
        bestAttemptContent = content
        let pollId = pollRequest.pollId ?? pollRequest.id
        let preferredBaseUrl = bestAttemptContent?.userInfo["base_url"] as? String
        guard let subscription = store?.findSubscriptionMatch(
                forPollRequestTopic: pollRequest.topic,
                preferredBaseUrl: preferredBaseUrl
            )
        else {
            Log.w(tag, "Cannot find subscription for poll request topic=\(pollRequest.topic), pollId=\(pollRequest.pollId ?? "<nil>")")
            let fallback = fallbackContent(request).mutableCopy() as! UNMutableNotificationContent
            fallback.configureInterruption(message: pollRequest)
            deliver(fallback)
            return
        }
        
        // Even a failed fetch/expiry must not re-alert a known id. Unknown ids fail open.
        alertIdentity = (Message(id: pollId, time: pollRequest.time, event: "message", topic: subscription.topic), subscription.baseUrl)
        // Install the safe topic-named fallback before anything else, including expiry.
        let placeholder = NotificationHealth.fetchFailureContent(request.content, topic: subscription.topic, baseUrl: subscription.baseUrl)
        placeholder.configureInterruption(message: pollRequest,
            soundName: store?.topicSoundName(baseUrl: subscription.baseUrl, topic: subscription.topic, library: soundLibrary))
        bestAttemptContent = placeholder
        // Claim the alert by message id before fetching: if the fallback is what shows (fetch
        // failure or expiry), a later ~poll that loads the message stays quiet; if the app already
        // alerted it, this push is passive.
        claimAlert {
            self.fetchPolled(request, content, pollRequest, pollId: pollId, subscription: subscription, placeholder: placeholder)
        }
        if normalizeBaseUrl(subscription.baseUrl) != normalizeBaseUrl(Config.appBaseUrl) {
            // Maintenance after the fallback is in place, never waited on.
            // A wake-up arrived for this hash: the server is set up (clears "not set up").
            SelfHostedWakeCheck.shared.recordWake(hash: pollRequest.topic)
            // Someone who lives on banners may never open the app: renew (never replace) the
            // bridge's registration, at most hourly and only when a week old.
            NtfyShBridge.shared.renewFromExtensionIfStale()
        }
    }

    private func fetchPolled(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ pollRequest: Message,
                             pollId: String, subscription: (baseUrl: String, topic: String), placeholder: UNMutableNotificationContent) {
        let user = store?.getBasicUser(baseUrl: subscription.baseUrl)
        // A wake-up can beat the server's own cache write, so "not stored yet" is asked again
        // (SingleMessagePoll) unless the wake is old; a real error still fails at once.
        let age = pollRequest.time > 0 ? Date().timeIntervalSince1970 - TimeInterval(pollRequest.time) : nil
        let pollDeadline = min(deadline.clock() + NotificationServiceTiming.pollTimeout, deadline.end - 2)
        SingleMessagePoll.run(deadline: pollDeadline, delays: SingleMessagePoll.delays(messageAge: age), clock: deadline.clock, fetch: { timeout, done in
            ApiService.shared.poll(baseUrl: subscription.baseUrl, topic: subscription.topic, messageId: pollId,
                                   user: user, timeout: timeout, completionHandler: done)
        }) { message, error, attempts in
            guard self.isPending else { return }
            guard let message = message else {
                Log.w(self.tag, "Error fetching poll request message topic=\(pollRequest.topic), pollId=\(pollId), attempts=\(attempts), subscription=\(topicUrl(baseUrl: subscription.baseUrl, topic: subscription.topic))", error)
                let missing = error is PollMissingResult ? shortUrl(url: normalizeBaseUrl(subscription.baseUrl)) : nil
                self.deliver(NotificationHealth.fetchFailureContent(placeholder, topic: subscription.topic,
                                                                    failure: PollFailure.classify(error), missingOn: missing))
                return
            }
            self.handleMessage(request, content, subscription.baseUrl, message)
        }
    }
}
