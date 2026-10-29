import AppKit
import Carbon

struct NotchEntryGate {
    private var wasNear = false

    mutating func suppressUntilExit(currentlyNear: Bool) {
        wasNear = currentlyNear
    }

    mutating func moved(isNear: Bool) -> Bool {
        defer { wasNear = isNear }
        return isNear && !wasNear
    }
}

@MainActor
final class GlobalHotkeyMonitor {
    private var interpreter = HotkeyInterpreter()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var mouseMonitor: Any?
    private var desktopInteractionMonitor: Any?
    private var notchGate = NotchEntryGate()
    private var escapeHotKey: EventHotKeyRef?
    private var escapeHandler: EventHandlerRef?
    var onAction: ((HotkeyAction) -> Void)?
    /// A release must last this long before Bibbles stops listening, so a
    /// momentary slip of a finger or a dropped key event does not cut you off.
    private let releaseGraceNanoseconds: UInt64 = 250_000_000
    private var pendingRelease: HotkeyAction?
    private var pendingReleaseTask: Task<Void, Never>?
    var onPointerNearNotch: (() -> Void)?
    var onDesktopInteraction: (() -> Void)?
    /// Scrolling elsewhere on the desktop (content under any marks moved).
    var onDesktopScroll: (() -> Void)?
    /// When the user last scrolled outside Bibbles.
    private(set) var lastScrollAt = Date.distantPast
    var onFocusModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return event
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.checkPointerNearNotch() }
        }
        desktopInteractionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            let scrolled = event.type == .scrollWheel
            Task { @MainActor in
                if scrolled {
                    self?.lastScrollAt = Date()
                    self?.onDesktopScroll?()
                }
                self?.onDesktopInteraction?()
            }
        }
    }

    func stop() {
        setEscapeCaptureEnabled(false)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let desktopInteractionMonitor { NSEvent.removeMonitor(desktopInteractionMonitor) }
        globalMonitor = nil
        localMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        mouseMonitor = nil
        desktopInteractionMonitor = nil
    }

    /// Closing near the notch should not reopen the panel on the next tiny
    /// mouse movement. The pointer must leave the region and enter again.
    func suppressNotchUntilExit() {
        notchGate.suppressUntilExit(currentlyNear: isPointerNearNotch())
    }

    /// Carbon hotkeys work even when the response card is a non-activating
    /// panel. Register Escape only while Bibbles is visible so other apps keep
    /// their normal Escape behavior when Bibbles is tucked away.
    func setEscapeCaptureEnabled(_ enabled: Bool) {
        if enabled {
            guard escapeHotKey == nil else { return }
            if escapeHandler == nil {
                var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                    guard let context else { return OSStatus(eventNotHandledErr) }
                    let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                    monitor.onAction?(.dismissPanels)
                    return noErr
                }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &escapeHandler)
                guard status == noErr else {
                    NSLog("Bibbles: Escape event handler installation failed (%d)", status)
                    return
                }
            }
            let identifier = EventHotKeyID(signature: OSType(0x42494245), id: 1)
            let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, identifier,
                                             GetApplicationEventTarget(), 0, &escapeHotKey)
            if status != noErr {
                escapeHotKey = nil
                NSLog("Bibbles: Escape hotkey registration failed (%d)", status)
            }
        } else if let escapeHotKey {
            UnregisterEventHotKey(escapeHotKey)
            self.escapeHotKey = nil
        }
    }

    private func handle(_ event: NSEvent) {
        onFocusModifiersChanged?(event.modifierFlags)
        let modifiers = Self.gestureModifiers(event.modifierFlags)
        dispatch(interpreter.consume(modifiers, at: event.timestamp))
    }

    private static func gestureModifiers(_ rawFlags: NSEvent.ModifierFlags) -> GestureModifiers {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: GestureModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }

    /// Delays the end of a push-to-talk or dictation hold until the keys have
    /// stayed released for a moment. If the same keys are held again within
    /// that time, Bibbles keeps listening as one continuous turn.
    private func dispatch(_ actions: [HotkeyAction]) {
        for action in actions {
            switch action {
            case .dictationEnded, .pushToTalkEnded:
                flushPendingRelease()
                pendingRelease = action
                pendingReleaseTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: self.releaseGraceNanoseconds)
                    guard !Task.isCancelled, self.pendingRelease != nil else { return }
                    // Re-check the real key state in case a key event was dropped.
                    let current = Self.gestureModifiers(NSEvent.modifierFlags)
                    let resumed = self.interpreter.consume(current, at: ProcessInfo.processInfo.systemUptime)
                    self.pendingReleaseTask = nil
                    self.dispatch(resumed)
                    if let release = self.pendingRelease {
                        self.pendingRelease = nil
                        self.onAction?(release)
                    }
                }
            case .dictationBegan where pendingRelease == .dictationEnded,
                 .pushToTalkBegan where pendingRelease == .pushToTalkEnded:
                // The same keys came back quickly: keep the current turn going.
                pendingReleaseTask?.cancel()
                pendingReleaseTask = nil
                pendingRelease = nil
            default:
                flushPendingRelease()
                onAction?(action)
            }
        }
    }

    private func flushPendingRelease() {
        guard let release = pendingRelease else { return }
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        pendingRelease = nil
        onAction?(release)
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 {
            onAction?(.dismissPanels)
            return
        }
        guard event.keyCode == 0 else { return }
        let relevant = event.modifierFlags.intersection([.control, .command, .option, .shift, .function])
        guard relevant == [.control, .command] else { return }
        onAction?(.openChatRequested)
    }

    private func checkPointerNearNotch() {
        let nearTopCenter = isPointerNearNotch()
        if notchGate.moved(isNear: nearTopCenter) { onPointerNearNotch?() }
    }

    func isPointerNearNotch() -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return false }
        let cursor = NSEvent.mouseLocation
        return abs(cursor.x - screen.frame.midX) <= 130
            && cursor.y >= screen.frame.maxY - 54
    }

    deinit {
        if let desktopInteractionMonitor { NSEvent.removeMonitor(desktopInteractionMonitor) }
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        if let escapeHandler { RemoveEventHandler(escapeHandler) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }
}
