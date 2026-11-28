// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import UIKit
import SafariServices
import UserNotifications
import Firebase
import FirebaseCore
import FirebaseMessaging
import CoreData

/// When the app asks iOS for notification permission.
///
/// Apple's HIG: ask in context, and when the reason isn't obvious, explain it first on your own
/// screen. A fresh install used to get the system prompt at launch; now it waits for the first
/// subscribe, which is the moment a notification permission makes sense to the user.
enum NotificationPermissionPolicy {
    /// At launch, ask directly only if iOS would not show a prompt anyway (already decided), or if
    /// the user has topics from before this flow existed and was never offered the explanation
    /// screen. Someone who saw it and chose "Not now" (or swiped it away) keeps the in-context path:
    /// a cold prompt on their next launch would undo exactly the choice they just made.
    static func shouldRequestAtLaunch(status: UNAuthorizationStatus, hasSubscriptions: Bool,
                                      primerOffered: Bool) -> Bool {
        status != .notDetermined || (hasSubscriptions && !primerOffered)
    }

    private static let primerOfferedKey = "notificationPermissionPrimerOffered"

    /// Whether this install has shown the explanation screen. Set when it appears, not on a button,
    /// so dismissing the sheet counts the same as "Not now".
    static func primerOffered(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: primerOfferedKey)
    }

    static func recordPrimerOffered(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: primerOfferedKey)
    }

    /// Show the explanation screen only when the system prompt would actually follow it.
    static func shouldPrime(status: UNAuthorizationStatus) -> Bool {
        status == .notDetermined
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate, ObservableObject {
    private let tag = "AppDelegate"
    // Single source of truth lives with the reconciler, which is what subscribes to it.
    private let pollTopic = FcmSubscriptionReconciler.pollTopic
    
    // Implements navigation from notifications, see https://stackoverflow.com/a/70731861/1440785
    @Published var selectedBaseUrl: String? = nil
    /// The sequence of the message whose banner was tapped, read together with `selectedBaseUrl`:
    /// a tap opens that message's page, one Back from its topic.
    var selectedMessageSequence: String? = nil
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var timeSensitiveSetting: UNNotificationSetting = .notSupported
    @Published private(set) var notificationSwitches = NotificationSwitches()
    @Published private(set) var hasPhoneRegistration = false
    @Published private(set) var hasPushRegistration = false
    @Published private(set) var criticalAlertSetting: UNNotificationSetting = .notSupported

    /// Taps the extension received in the app's place (on a Mac), and the guard that runs each tap once.
    private let responseRelay = NotificationResponseRelay(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    private var responseDeduper = NotificationResponseDeduper()
    private var relayActivationObserver: NSObjectProtocol?

    private var policySnapshot: NSObjectProtocol?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Log.d(tag, "Launching AppDelegate")
        ReviewPrompt.shared.recordLaunch()

        // When the app is launched only as the unit-test host, skip Firebase +
        // remote-notification registration: they crash the test runner during
        // bootstrap and aren't needed for logic tests. XCTestCase is only present
        // when XCTest.framework is loaded (test runs), never in a shipped build.
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        // Rows an earlier unsubscribe left behind would show as nameless cards; once gone, a no-op.
        Store.shared.removeOrphanedRows()
        // So do alert claims of topics no longer subscribed, should an unsubscribe's sweep have failed.
        Store.shared.pruneClaimsOfRemovedTopics()
        // The extension's entry fallback reads mutes and quiet-hours exceptions from this (review-130c C6).
        policySnapshot = Store.shared.startNotificationPolicySnapshot()

        QuietTopicAlerts.shared.beginExecution = { cancel, start in
            DispatchQueue.main.async {
                var task: UIBackgroundTaskIdentifier = .invalid
                task = UIApplication.shared.beginBackgroundTask(withName: "Schedule quiet alert", expirationHandler: cancel)
                if task == .invalid { cancel() }
                start {
                    DispatchQueue.main.async {
                        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                    }
                }
            }
        }
        QuietTopicAlerts.shared.refreshQuietHours()
        DiagnosticSubscriber.shared.start()
        #if DEBUG
        DiagnosticSubscriber.shared.receiveDebugFixtureIfRequested()
        #endif

        // Lift any password still sitting in the Core Data store into the Keychain and blank the
        // column. Idempotent and cheap — stores written by this build already have none.
        Store.shared.migrateCredentialsToKeychain()

        FirebaseApp.configure()
        #if DEBUG
        FirebaseConfiguration.shared.setLoggerLevel(FirebaseLogPolicy.level(debug: true))
        #else
        FirebaseConfiguration.shared.setLoggerLevel(FirebaseLogPolicy.level(debug: false))
        #endif

        // Move topics off the private server 1.12/1.13 shipped as the built-in default (they get 403
        // there). Once only; after Firebase is configured because a move tears down old FCM names.
        RetiredDefaultServerMigration.runIfNeeded(
            store: Store.shared,
            defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard,
            reconciler: FcmSubscriptionReconciler.shared
        )

        // Rows an older build created under ntf-ai.app, which it took for someone else's server.
        HostedAliasRowMigration.run(
            store: Store.shared,
            defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard,
            reconciler: FcmSubscriptionReconciler.shared
        )

        ManagedConfiguration.shared.start()

        // Register app permissions for push notifications
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        requestStandardNotificationAuthorizationIfAppropriate()
        refreshNotificationSettings()
        
        // Register too receive remote notifications
        application.registerForRemoteNotifications()

        startBadgeSync()
        observeRelayedNotificationResponses()
        // Screens showing bridge state re-read when the extension writes it, and on activation.
        BridgeStateSignal.observeOtherProcesses()

        return true
    }

    // MARK: Banner taps relayed by the extension

    /// On a Mac the system can hand a banner tap to the extension instead of the app (see
    /// `NotificationResponseRelay`). Pick those up at launch, whenever the app becomes active (the
    /// system brings it forward for the tap) and when the extension says it queued one.
    private func observeRelayedNotificationResponses() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { delegate.handleRelayedNotificationResponses() }
            },
            NotificationResponseRelay.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        relayActivationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleRelayedNotificationResponses()
            QuietTopicAlerts.shared.refreshQuietHours()
            BridgeStateSignal.postInProcess()
        }
        handleRelayedNotificationResponses()
    }

    func applicationSignificantTimeChange(_ application: UIApplication) {
        QuietTopicAlerts.shared.refreshQuietHours()
    }

    private func handleRelayedNotificationResponses() {
        for relayed in responseRelay.drain() {
            Log.d(tag, "Handling a notification response relayed by the extension", relayed.actionIdentifier)
            handleNotificationResponse(
                userInfo: relayed.userInfo,
                actionIdentifier: relayed.actionIdentifier,
                notificationId: relayed.notificationId,
                userText: relayed.userText
            )
        }
    }

    // MARK: App icon badge

    private var badgeObservers: [NSObjectProtocol] = []

    /// Keeps the app icon badge in step with the number of unread notifications (ntfy#1462).
    ///
    /// Delivery pushes the badge *up* from the notification payload itself
    /// (`UNMutableNotificationContent.modify`) — that is the only thing that can move it while the
    /// app isn't running. This covers everything else: the moment the user reads, swipes, deletes
    /// or unsubscribes, the icon has to come back down, and on returning to the foreground the app
    /// has to absorb whatever the notification service extension wrote in its own process while we
    /// were away.
    private func startBadgeSync() {
        let center = NotificationCenter.default
        let refresh: (Foundation.Notification) -> Void = { [weak self] _ in self?.refreshAppIconBadge() }
        badgeObservers = [
            // Every in-app mutation: read/unread toggles, opening a topic, deletes, unsubscribes.
            center.addObserver(forName: .NSManagedObjectContextDidSave, object: Store.shared.context,
                               queue: .main, using: refresh),
            // A write from the notification service extension's process.
            center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil,
                               queue: .main, using: refresh),
            // Returning to the foreground, where neither of the above is guaranteed to have reached us.
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                               queue: .main, using: refresh),
        ]
        refreshAppIconBadge()
    }

    private func refreshAppIconBadge() {
        let count = Store.shared.totalUnreadCount()
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    Log.w(self.tag, "Cannot set app icon badge", error)
                }
            }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }

    func refreshNotificationSettings(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let isAuthorized = settings.criticalAlertSetting == .enabled
            DispatchQueue.main.async {
                let switches = NotificationSwitches(settings: settings, backgroundRefresh: UIApplication.shared.backgroundRefreshStatus,
                                                   lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled).applyingDebugOverride()
                self.notificationSwitches = switches
                self.notificationAuthorizationStatus = switches.authorization
                if FirebaseApp.app() != nil {
                    self.hasPhoneRegistration = Messaging.messaging().apnsToken != nil
                    // Keep token mode: FID registration opts out of tokens used by the reconciler.
                    self.hasPushRegistration = !(Messaging.messaging().fcmToken ?? "").isEmpty
                }
                if #available(iOS 15.0, *) {
                    self.timeSensitiveSetting = settings.timeSensitiveSetting
                }
                self.criticalAlertSetting = settings.criticalAlertSetting
                Store.saveCriticalAlertsAuthorized(isAuthorized)
                completion?()
            }
        }
    }

    func requestCriticalAlertsAuthorization(completion: @escaping (Bool) -> Void) {
        if criticalAlertSetting == .enabled {
            completion(true)
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert]) { success, error in
            if let error {
                Log.e(self.tag, "Failed to register for critical alerts", error)
            } else if success {
                Log.d(self.tag, "Successfully requested critical alerts")
            }

            self.refreshNotificationSettings {
                completion(self.criticalAlertSetting == .enabled)
            }
        }
    }

    // TODO: Needs to be tested on multiple devices/iOS versions
    func openNotificationSettings() {
        let settingsURLString: String
        #if targetEnvironment(simulator)
        settingsURLString = UIApplication.openSettingsURLString
        #else
        if #available(iOS 16.0, *) {
            settingsURLString = UIApplication.openNotificationSettingsURLString
        } else if #available(iOS 15.4, *) {
            settingsURLString = UIApplicationOpenNotificationSettingsURLString
        } else {
            settingsURLString = UIApplication.openSettingsURLString
        }
        #endif
        guard let url = URL(string: settingsURLString) else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Launch-time permission request, skipped on a fresh install. A cold system prompt before the
    /// user has done anything gives them no reason to say yes; the add-topic screen asks instead,
    /// after the first subscribe, with a short explanation first (see `NotificationPermissionPolicy`).
    private func requestStandardNotificationAuthorizationIfAppropriate() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let hasSubscriptions = !(Store.shared.getSubscriptions() ?? []).isEmpty
                if NotificationPermissionPolicy.shouldRequestAtLaunch(
                    status: settings.authorizationStatus,
                    hasSubscriptions: hasSubscriptions,
                    primerOffered: NotificationPermissionPolicy.primerOffered()
                ) {
                    self.requestStandardNotificationAuthorization()
                }
            }
        }
    }

    func notificationAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus) }
        }
    }

    func requestStandardNotificationAuthorization(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, error in
            if success {
                Log.d(self.tag, "Successfully registered for local push notifications")
            } else {
                Log.e(self.tag, "Failed to register for local push notifications", error)
            }
            self.refreshNotificationSettings(completion: completion)
        }
    }
    
    /// Executed when a background notification arrives on the "~poll" topic. This is used to trigger polling of local topics.
    /// See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/pushing_background_updates_to_your_app
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // iOS gives this callback 30 seconds. The deadline and its watchdog start here, before any
        // store work, on a monotonic clock and off the main queue, and the completion runs exactly
        // once, by then at the latest (review-130b #2).
        let finish = BackgroundWakeCompletion(deadline: BackgroundWakeCompletion.budget, completion: completionHandler)
        Log.d(tag, "Background notification received", userInfo)
        
        var wakeManager = SubscriptionManager(store: Store.shared)
        wakeManager.fetch = { ApiService.shared.poll($0, timeout: 8, wake: finish.wake, completionHandler: $1) }
        if wakeManager.handleSilentWake(userInfo: userInfo, completion: { succeeded in
            finish.complete(succeeded ? .newData : .failed)
        }) { return }

        if let message = Message.from(userInfo: userInfo), message.isControl {
            let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
            let result = Store.shared.ingest(pushedMessage: message, baseUrl: baseUrl, topic: message.topic)
            if case .reconcile(let request) = result {
                ApiService.shared.poll(request, timeout: 8, wake: finish.wake) { messages, _ in
                    guard let messages else { finish.complete(.failed); return }
                    let presentations = Store.shared.save(notificationsFromMessages: messages, polledWith: request) ?? []
                    self.showNotificationsSequentially(baseUrl: baseUrl, messages: presentations, wake: finish.wake) {
                        finish.complete(.newData)
                    }
                }
            } else {
                finish.complete(result == nil ? .noData : .newData)
            }
            return
        }

        // Exit out early if this message is not expected
        let topic = userInfo["topic"] as? String ?? ""
        if topic != pollTopic {
            finish.complete(.noData)
            return
        }

        // Poll and show new messages as notifications. An empty store still runs maintenance: a
        // removal or opt-out the server hasn't confirmed is retried on every trigger (review-130c C2).
        let store = Store.shared
        var subscriptionManager = SubscriptionManager(store: store)
        let wake = finish.wake
        subscriptionManager.fetch = { ApiService.shared.poll($0, timeout: 8, wake: wake, completionHandler: $1) }
        let subscriptions = store.getSubscriptions() ?? []

        let group = DispatchGroup()
        subscriptions.forEach { subscription in
            group.enter()
            guard let baseUrl = subscription.baseUrl else {
                Log.w(tag, "Skipping background poll notification for subscription with missing baseUrl")
                group.leave()
                return
            }
            subscriptionManager.poll(subscription) { messages in
                if !messages.isEmpty { finish.noteNewData() }
                self.showNotificationsSequentially(baseUrl: baseUrl, messages: messages, wake: wake) {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            // ntfy-me.com sends this wake-up about every 20 minutes, so it also keeps the bridge's
            // registration alive (and its ntfy.sh access rechecks current) for someone who never
            // opens the app. The wake completes on the content result; maintenance then runs only
            // with enough of the budget left, in a background task bound to the same wake: no
            // request of it starts past the deadline, and the deadline cancels what is running
            // (review-130c C4).
            guard finish.admitsMaintenance else {
                Log.d(self.tag, "Background wake: no time left for bridge maintenance")
                finish.complete()
                return
            }
            self.runWakeMaintenance(finish: finish)
        }
    }

    var beginMaintenanceBackgroundTask: (@escaping () -> Void) -> UIBackgroundTaskIdentifier = {
        UIApplication.shared.beginBackgroundTask(withName: "bridge maintenance", expirationHandler: $0)
    }
    var endMaintenanceBackgroundTask: (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    var bridgeMaintenance: (WakeContext, @escaping () -> Void) -> Void = { wake, done in
        NtfyShBridge.shared.sync(reason: "background wake", wake: wake, completion: done)
    }

    /// The wake's bridge maintenance, after its content result. It runs only inside a UIKit
    /// background task: the wake is completed before it starts, and its shared-container locks
    /// must never be held by a suspended app (review-130f F1). Denied a task, it doesn't start.
    func runWakeMaintenance(finish: BackgroundWakeCompletion) {
        let wake = finish.wake
        let ended = Once()
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard ended.claim() else { return }
            DispatchQueue.main.async { if task != .invalid { self.endMaintenanceBackgroundTask(task); task = .invalid } }
        }
        task = beginMaintenanceBackgroundTask { wake.cancel(); end() }
        guard task != .invalid else {
            Log.d(tag, "Background wake: no background time for bridge maintenance")
            finish.complete()
            return
        }
        wake.onCancel(end)
        finish.complete()
        bridgeMaintenance(wake) { end() }
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { data in String(format: "%02.2hhx", data) }.joined()
        Messaging.messaging().apnsToken = deviceToken
        DispatchQueue.main.async { self.hasPhoneRegistration = true }
        Log.d(tag, "Registered for remote notifications. Passing APNs token \(token.prefix(12))... to Firebase")
        // FCM topic binding only works once this token is associated, and this
        // callback frequently lands *after* the FCM token did. Reconciling here
        // means whichever of the two arrives second completes the round —
        // previously the earlier one just failed silently for every topic.
        FcmSubscriptionReconciler.shared.reconcile(reason: "APNs token registered")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.e(tag, "Failed to register for remote notifications", error)
        DispatchQueue.main.async { self.hasPhoneRegistration = false }
    }
    
    /// Create a local notification manually (as opposed to a remote notification being generated by Firebase). We need to make the
    /// local notification look exactly like the remote one (same userInfo), so that when we tap it, the userNotificationCenter(didReceive) function
    /// has the same information available.
    private func showNotification(_ subscription: Subscription, _ message: Message, completionHandler: (() -> Void)? = nil) {
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Skipping notification for subscription with missing baseUrl")
            completionHandler?()
            return
        }
        showNotification(baseUrl: baseUrl, message, completionHandler: completionHandler)
    }

    var soundLibrary: TopicSoundLibrary = .shared

    var notificationScheduler: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void = {
        UNUserNotificationCenter.current().add($0, withCompletionHandler: $1)
    }

    /// Where banner answers are logged; tests inject their own.
    var answerLog: AnswerLog = .shared
    var beginNotificationBackgroundTask: (@escaping () -> Void) -> UIBackgroundTaskIdentifier = {
        UIApplication.shared.beginBackgroundTask(withName: "Schedule notification", expirationHandler: $0)
    }
    var endNotificationBackgroundTask: (UIBackgroundTaskIdentifier) -> Void = {
        UIApplication.shared.endBackgroundTask($0)
    }

    /// Seconds the attachment download may take: 20, or within a wake what is left of it, less
    /// time to schedule the banner (review-130d D3).
    static func attachmentTimeout(wake: WakeContext?) -> TimeInterval {
        guard let wake else { return 20 }
        return max(0.5, min(20, wake.remaining - 2))
    }

    /// Within a wake (`wake`), every step of this message's presentation stops when the wake ends:
    /// the attachment download is bounded by its remaining time and isn't recorded after it, and the
    /// wake is checked again right before the claim and the scheduler (review-130d D3). The message
    /// is saved either way and shows in the app.
    func showNotification(baseUrl: String, _ message: Message, wake: WakeContext? = nil, completionHandler: (() -> Void)? = nil) {
        // Ended (the watchdog cancelled it) or out of time even if the watchdog is late (review-130e E5).
        let stillNeeded = { wake.map { !$0.isCancelled && $0.remaining > 0 } ?? true }
        let user = Store.shared.getBasicUser(baseUrl: baseUrl)
        let displayName = Store.shared.subscriptionDisplayName(baseUrl: baseUrl, topic: message.topic)
        let soundName = Store.shared.topicSoundName(baseUrl: baseUrl, topic: message.topic, library: soundLibrary)
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: baseUrl, displayName: displayName, soundName: soundName)
        content.attachImageIfNeeded(message: message, baseUrl: baseUrl, user: user, timeout: Self.attachmentTimeout(wake: wake),
                                    stillNeeded: stillNeeded) {
            content.configureInterruption(message: message, soundName: soundName)
            content.applyTopicMute(baseUrl: baseUrl, topic: message.topic)
            let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil /* now */)
            // Acquire background execution on main before the shared-container lock or scheduler.
            // Expiration cancels the pending delivery and relinquishes its lock before ending the task.
            DispatchQueue.main.async {
                guard stillNeeded() else {
                    Log.w(self.tag, "Background wake ended; message \(message.id) not presented, saved for the app")
                    completionHandler?()
                    return
                }
                var cancel: () -> Void = {}
                var task: UIBackgroundTaskIdentifier = .invalid
                task = self.beginNotificationBackgroundTask { cancel() }
                let schedule: (@escaping (Bool) -> Void) -> Void = { finished in
                    self.notificationScheduler(request) { error in
                        if let error { Log.e(self.tag, "Unable to create notification", error) }
                        finished(error == nil)
                    }
                }
                let done = {
                    DispatchQueue.main.async {
                        if task != .invalid { self.endNotificationBackgroundTask(task) }
                        completionHandler?()
                    }
                }
                guard task != .invalid else {
                    // Denied: no claims lock and no shared write; the app may be suspended at once (review-130f F1).
                    Store.shared.presentWithoutExecutionTime(message: message, baseUrl: baseUrl, stillNeeded: stillNeeded,
                                                             delivery: schedule, completion: done)
                    return
                }
                // The task is held from here until `done`, which follows the last locked section.
                cancel = Store.shared.deliverAlert(message: message, baseUrl: baseUrl, stillNeeded: stillNeeded,
                                                   delivery: schedule, completion: done)
            }
        }
    }

    /// Within a wake, presentation stops when the wake ends; the messages are saved and show in the app.
    private func showNotificationsSequentially(baseUrl: String, messages: [Message], wake: WakeContext? = nil, completionHandler: @escaping () -> Void) {
        guard let firstMessage = messages.first else {
            completionHandler()
            return
        }
        if wake?.isCancelled == true {
            Log.w(tag, "Background wake ended; \(messages.count) message(s) not presented, saved for the app")
            completionHandler()
            return
        }

        showNotification(baseUrl: baseUrl, firstMessage, wake: wake) {
            self.showNotificationsSequentially(
                baseUrl: baseUrl,
                messages: Array(messages.dropFirst()),
                wake: wake,
                completionHandler: completionHandler
            )
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Executed when the app is in the foreground. Nothing has to be done here, except call the completionHandler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier == TopicSoundPreview.requestID {
            completionHandler([.sound])
            return
        }
        let userInfo = notification.request.content.userInfo
        if userInfo[QuietTopicAlerts.marker] as? Bool == true {
            completionHandler(QuietHours.load().isQuiet(userInfo: userInfo) ? [.list] : [.banner, .sound, .list])
            return
        }
        Log.d(tag, "Notification received via userNotificationCenter(willPresent)", userInfo)
        var wakeManager = SubscriptionManager(store: Store.shared)
        wakeManager.fetch = { ApiService.shared.poll($0, timeout: 8, completionHandler: $1) }
        if wakeManager.handleSilentWake(userInfo: userInfo, completion: { _ in }) {
            completionHandler([])
            return
        }
        if let message = Message.from(userInfo: userInfo) {
            let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
            if message.event == "message" || message.isControl {
                let result = Store.shared.ingest(pushedMessage: message, baseUrl: baseUrl, topic: message.topic)
                if case .reconcile(let request) = result {
                    ApiService.shared.poll(request, timeout: 8) { messages, _ in
                        if let messages { _ = Store.shared.save(notificationsFromMessages: messages, polledWith: request) }
                    }
                }
                if message.isControl { completionHandler([]); return }
                // An ack is a silent receipt: never a banner or sound. With confirmations off it
                // stays out of Notification Center too.
                if AgentAck.isAck(tags: message.tags) {
                    completionHandler(AgentAck.foregroundPresentation(shows: AgentAck.showsConfirmations()))
                    return
                }
                // The person's own answer or reply that the store kept no unread row for: no banner.
                if AnswerMessage.replySequence(tags: message.tags) != nil, result?.message == nil {
                    completionHandler([])
                    return
                }
            }
        }
        let muted = Store.shared.isNotificationMuted(userInfo: userInfo)
        ReviewPrompt.shared.noteGoodMoment()
        completionHandler(muted || notification.request.content.sound == nil ? [.list] : [.banner, .sound])
    }
    
    /// Executed when the user clicks on the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Log.d(tag, "Notification received via userNotificationCenter(didReceive)", userInfo)
        ReviewPrompt.shared.noteGoodMoment()
        handleNotificationResponse(
            userInfo: userInfo,
            actionIdentifier: response.actionIdentifier,
            notificationId: response.notification.request.identifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            completionHandler: completionHandler
        )
    }

    /// Acts on a tap (the body, a button, or a dismiss), whether the app's own delegate received it
    /// or the extension relayed it. Each tap runs once.
    func handleNotificationResponse(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String,
        notificationId: String,
        userText: String? = nil,
        completionHandler: @escaping () -> Void = {}
    ) {
        let isQuietAlert = userInfo[QuietTopicAlerts.marker] as? Bool == true
        let decodedMessage = isQuietAlert ? nil : Message.from(userInfo: userInfo)
        let action = decodedMessage?.actions?.first { $0.id == actionIdentifier }
        let isReply = action.flatMap { BannerReply.destination(for: $0) } != nil
        // Rejected submissions must not consume the once-only delivery slot.
        if isReply && (userText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !isReply && userText != nil {
            completionHandler()
            return
        }
        // Before the once-only slot, so the same button works after the person unlocks.
        if let action, action.action == "http", !isReply,
           !LockScreenButtons.mayRun(httpButton: true, enabled: LockScreenButtons.enabled(),
                                     protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                                     onMac: ProcessInfo.processInfo.isiOSAppOnMac) {
            Log.w(tag, "Refusing an http button tapped while locked with Use buttons without unlocking off", action.id)
            LockScreenButtons.notifyRefused(action.label)
            completionHandler()
            return
        }
        guard responseDeduper.shouldHandle(notificationId: notificationId, actionIdentifier: actionIdentifier) else {
            Log.d(tag, "Ignoring a notification response that was already handled", actionIdentifier)
            completionHandler()
            return
        }
        if isQuietAlert {
            if let baseUrl = userInfo["base_url"] as? String, let topic = userInfo["topic"] as? String {
                selectedMessageSequence = nil
                selectedBaseUrl = topicUrl(baseUrl: baseUrl, topic: topic)
            }
            completionHandler()
            return
        }
        guard let message = decodedMessage else {
            Log.w(tag, "Cannot convert userInfo to message", userInfo)
            completionHandler()
            return
        }
        
        let baseUrl = userInfo["base_url"] as? String ?? Config.appBaseUrl
        if actionIdentifier == UNNotificationDismissActionIdentifier {
            Store.shared.read(message: message, baseUrl: baseUrl, completion: completionHandler)
            return
        }
        Store.shared.read(message: message, baseUrl: baseUrl)
        
        // Show current topic, and the tapped message's page on top of it
        if message.topic != "" {
            selectedMessageSequence = actionIdentifier == UNNotificationDefaultActionIdentifier ? message.sequence : nil
            selectedBaseUrl = topicUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // Execute user action or click action (if any)
        if let action = action {
            if action.action == "http" || isReply {
                let execute = {
                    var task = UIBackgroundTaskIdentifier.invalid
                    var execution: Progress?
                    var finished = false
                    // The response and expiration callbacks share one main-thread finish path.
                    let finish = {
                        guard !finished else { return }
                        finished = true
                        if task != .invalid { self.endNotificationBackgroundTask(task) }
                        completionHandler()
                    }
                    task = self.beginNotificationBackgroundTask {
                        execution?.cancel()
                        finish()
                    }
                    execution = ActionExecutor.execute(action, notificationId: notificationId, baseUrl: baseUrl,
                                                       replyText: isReply ? userText : nil,
                                                       answer: AnswerKey(baseUrl: baseUrl, topic: message.topic, sequence: message.sequence),
                                                       repeatable: !AgentQuestion.locksAfterAnswer(tags: message.tags ?? [],
                                                                                                   actions: message.actions ?? []),
                                                       answerLog: self.answerLog) {
                        DispatchQueue.main.async(execute: finish)
                    }
                }
                if Thread.isMainThread { execute() } else { DispatchQueue.main.async(execute: execute) }
                return
            }
            ActionExecutor.execute(action, notificationId: notificationId, baseUrl: baseUrl)
        } else if let url = ClickURL.url(from: message.click) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    
        completionHandler()
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        DispatchQueue.main.async { self.hasPushRegistration = !(fcmToken ?? "").isEmpty }
        if let fcmToken = fcmToken, !fcmToken.isEmpty {
            Log.d(tag, "Firebase token received: \(fcmToken.prefix(12))...")
        } else {
            Log.w(tag, "Firebase token missing")
        }

        // A rotated token voids every existing topic binding, so record it first
        // (that marks all subscriptions stale) and then rebuild them. This used
        // to be a single best-effort re-subscribe loop that swallowed every
        // error, which is why a rotation could silently kill push forever —
        // ntfy#1305. Reconciling is retryable and idempotent; if the APNs token
        // has not landed yet this no-ops and the APNs callback re-drives it.
        // A changed token drives its own rebuild inside noteRegistrationToken — the invalidation and
        // the round that acts on it belong together, so it does not depend on callers remembering.
        // An *unchanged* token invalidates nothing, but this callback is still a repair trigger, so
        // reconcile explicitly in that case.
        if !FcmSubscriptionReconciler.shared.noteRegistrationToken(fcmToken) {
            FcmSubscriptionReconciler.shared.reconcile(reason: "FCM registration token")
        }
    }
}


enum FirebaseLogPolicy {
    static func level(debug: Bool) -> FirebaseLoggerLevel { debug ? .max : .min }
}

/// A background wake's completion: called exactly once, when the work finishes or at the
/// deadline, whichever comes first. Later calls do nothing. The deadline is monotonic (system
/// uptime) and its watchdog runs off the main queue, so a slow store open or a busy main thread
/// can't push the completion past the system's limit.
final class BackgroundWakeCompletion {
    /// Under the 30 seconds iOS gives a background notification, with room for the handoff.
    static let budget: TimeInterval = 25
    /// Bridge maintenance starts only with at least this much of the budget left.
    static let maintenanceMinimum: TimeInterval = 8

    private let deadlineUptime: TimeInterval
    private let uptime: () -> TimeInterval
    private let lock = NSLock()
    private var completion: ((UIBackgroundFetchResult) -> Void)?
    /// The wake's budget and cancellation, for every request it starts (review-130c C4).
    let wake: WakeContext
    private var newData = false

    init(deadline: TimeInterval, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
         },
         completion: @escaping (UIBackgroundFetchResult) -> Void) {
        self.uptime = uptime
        self.deadlineUptime = uptime() + deadline
        self.completion = completion
        self.wake = WakeContext(deadline: deadline, uptime: uptime)
        // Held strongly until the deadline: the completion must run even if nothing else does,
        // and nothing the wake started outlives it.
        schedule(deadline) {
            if self.isPending { Log.w("BackgroundWake", "Deadline reached; completing the background wake") }
            self.complete()
            self.wake.cancel()
        }
    }

    /// Seconds left before the deadline (never negative).
    var remaining: TimeInterval { max(0, deadlineUptime - uptime()) }
    /// The deadline as a date for request budgeting.
    var deadlineDate: Date { Date().addingTimeInterval(remaining) }
    var admitsMaintenance: Bool { isPending && remaining >= Self.maintenanceMinimum }

    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }

    func noteNewData() { lock.lock(); newData = true; lock.unlock() }

    /// Completes with `result`, or with new data / no data as noted.
    func complete(_ result: UIBackgroundFetchResult? = nil) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        let outcome: UIBackgroundFetchResult = result ?? (newData ? .newData : .noData)
        lock.unlock()
        completion?(outcome)
    }
}
