import AppKit
import SwiftUI

/// Nonactivating overlays must accept the first click while another app is active.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the Bibbles bar sits at the top of a screen. On a Mac with a notch
/// it wraps the notch with a "wing" on each side; elsewhere it is a small
/// bar at the top centre of the menu bar.
enum NotchGeometry {
    /// Just wide enough for the logo and the badge, so menu-bar items next
    /// to the notch stay clickable.
    static let wing: CGFloat = 46
    /// While Bibbles is working the bar widens to show what it's doing
    /// ("Listening", "Thinking"…), like HeyClicky.
    static let activeWing: CGFloat = 120
    /// The bar hangs a little below the menu bar, like a tab under the notch.
    static let drop: CGFloat = 4
    /// Roundness of the bar's bottom corners.
    static let cornerRadius: CGFloat = 13
    /// Above the menu bar when the visibility policy permits the notch.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    /// Base behavior. Full-screen auxiliary is added only for Bibbles' own key window.
    static let everySpace: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    /// The camera notch, in screen coordinates, or nil when there is none.
    static func notchRect(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        guard width > 40 else { return nil }
        let height = screen.safeAreaInsets.top
        return CGRect(x: left.maxX, y: screen.frame.maxY - height, width: width, height: height)
    }

    static func barFrame(on screen: NSScreen, wing: CGFloat = NotchGeometry.wing) -> CGRect {
        if let notch = notchRect(on: screen) {
            var frame = notch.insetBy(dx: -wing, dy: 0)
            frame.origin.y -= drop
            frame.size.height += drop
            return frame
        }
        let height = NSStatusBar.system.thickness + drop
        let width: CGFloat = wing > NotchGeometry.wing ? 330 : 220
        return CGRect(x: (screen.frame.midX - width / 2).rounded(), y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    /// The built-in screen (the one with the notch) if there is one.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { notchRect(on: $0) != nil } ?? NSScreen.screens.first
    }
}

/// Is the screen currently showing a full-screen app (its own Space)?
/// macOS shows a menu-bar app's windows even there, so Bibbles checks and
/// hides the bar itself, the way the menu bar hides.
enum FullScreenDetector {
    struct SpaceState: Equatable {
        let fullScreen: Bool
        let identifier: String?
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    /// RTLD_DEFAULT: search every loaded library.
    private static let everyLibrary = UnsafeMutableRawPointer(bitPattern: -2)

    /// Takes only value snapshots so window-server work can run off the main thread.
    static func snapshot(displayID: CGDirectDisplayID, frame: CGRect, frontmostPID: pid_t?) -> SpaceState {
        if let managed = managedSpace(displayID: displayID) { return managed }
        return SpaceState(fullScreen: frontWindowFillsScreen(frame: frame, frontmostPID: frontmostPID), identifier: nil)
    }

    /// Asks the window server what kind of Space is showing on the screen
    /// (type 4 is a full-screen app). Returns nil if it can't tell.
    private static func managedSpace(displayID: CGDirectDisplayID) -> SpaceState? {
        guard let mainSymbol = dlsym(everyLibrary, "CGSMainConnectionID"),
              let copySymbol = dlsym(everyLibrary, "CGSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(mainSymbol, to: MainConnection.self)()
        let copySpaces = unsafeBitCast(copySymbol, to: CopyManagedDisplaySpaces.self)
        guard let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }
        let uuid = displayUUID(displayID)
        // With one shared set of Spaces there is a single entry ("Main").
        let display: [String: Any]
        if displays.count == 1 {
            display = displays[0]
        } else {
            guard let uuid,
                  let match = displays.first(where: { ($0["Display Identifier"] as? String) == uuid }) else { return nil }
            display = match
        }
        guard let current = display["Current Space"] as? [String: Any],
              let type = current["type"] as? Int else { return nil }
        let identifier = (current["id64"] as? NSNumber)?.stringValue
            ?? (current["ManagedSpaceID"] as? NSNumber)?.stringValue
            ?? current["uuid"] as? String
        return SpaceState(fullScreen: type == 4, identifier: identifier)
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid)
        else { return nil }
        return string as String
    }

    /// Fallback: the front app has a window covering the whole screen.
    private static func frontWindowFillsScreen(frame: CGRect, frontmostPID: pid_t?) -> Bool {
        guard let pid = frontmostPID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Width"] ?? 0) >= frame.width - 1 && (bounds["Height"] ?? 0) >= frame.height - 1
        }
    }
}

/// Separate from AppKit so all space and key-window transitions share one rule.
enum NotchVisibilityPolicy {
    static func shouldShow(enabled: Bool, checkingSpace: Bool, fullScreen: Bool,
                           appHasKeyWindow: Bool, interactionActive: Bool) -> Bool {
        enabled && (interactionActive || (!checkingSpace && (appHasKeyWindow || !fullScreen)))
    }
}

/// What the bar is showing: how wide its sides are and Bibbles' status.
@MainActor
final class NotchPillState: ObservableObject {
    @Published var wing: CGFloat = NotchGeometry.wing
    @Published var status: String?
}

/// The Bibbles bar follows desktop Spaces, and stays out of other apps'
/// full-screen Spaces. Window-server checks never run on the UI thread.
@MainActor
final class NotchPillController {
    private let panel: NSPanel
    private let onHover: () -> Void
    private let onHidden: () -> Void
    private let activity: () -> String?
    private let interactionActive: () -> Bool
    private let state = NotchPillState()
    private let detectionQueue = DispatchQueue(label: "in.bibbles.notch.space", qos: .utility)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var spaceGeneration = 0
    private var checkingSpace = true
    private var timer: Timer?
    private var pointerWasInside = false
    private var fullScreen = false
    private var lastInteractionActive = false
    private var lastPresentationAttempt = Date.distantPast
    private var hoverTask: Task<Void, Never>?
    private var hoverSuppressedUntilExit = false
    private var pendingSpaceCheck: DispatchWorkItem?

    /// - activity: what Bibbles is doing right now ("Listening", "Thinking",
    ///   "Speaking"), or nil when idle.
    init(store: ChatConversationStore,
         activity: @escaping () -> String?, interactionActive: @escaping () -> Bool,
         onHover: @escaping () -> Void,
         onHidden: @escaping () -> Void, onClick: @escaping () -> Void) {
        self.onHover = onHover
        self.activity = activity
        self.interactionActive = interactionActive
        self.onHidden = onHidden
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, so the bar sits beside the notch.
        panel.level = NotchGeometry.overlayLevel
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = NotchGeometry.everySpace
        panel.contentView = NotchHostingView(rootView: NotchPillView(
            history: store.taskHistory, state: state, onClick: onClick,
            onPointerChanged: { [weak self] inside in self?.pointerChanged(inside) }
        ))
    }

    var isVisible: Bool { panel.isVisible }
    var isOnActiveSpace: Bool {
        panel.isVisible && panel.isOnActiveSpace &&
            NotchVisibilityPolicy.shouldShow(enabled: timer != nil, checkingSpace: checkingSpace,
                                             fullScreen: fullScreen, appHasKeyWindow: appHasKeyWindow,
                                             interactionActive: interactionActive())
    }
    var frame: CGRect { panel.isVisible ? panel.frame : targetFrame }

    private var targetFrame: CGRect {
        NotchGeometry.preferredScreen().map { NotchGeometry.barFrame(on: $0, wing: state.wing) } ?? panel.frame
    }

    private var appHasKeyWindow: Bool {
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow, keyWindow !== panel else { return false }
        return keyWindow.isOnActiveSpace
    }

    /// Turns the bar on and begins event-driven Space observation.
    func show() {
        guard timer == nil else {
            updateVisibility()
            return
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification, refreshSpace: true)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, refreshSpace: true)
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification, refreshSpace: false)
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification, refreshSpace: false)
        observe(NotificationCenter.default, NSWindow.didBecomeKeyNotification, refreshSpace: false)
        observe(NotificationCenter.default, NSWindow.didResignKeyNotification, refreshSpace: false)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshSpace()
        tick()
    }

    /// Hotkeys call this immediately, before a nonactivating panel becomes key.
    func interactionDidBegin() {
        guard timer != nil else { return }
        lastPresentationAttempt = .distantPast
        tick()
        updateVisibility()
    }

    /// Shared by native tracking and the global fallback; only one dwell can be pending.
    func requestHover() {
        pointerChanged(panel.isVisible && panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation))
    }

    func suppressHoverUntilExit() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverSuppressedUntilExit = panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func pointerChanged(_ inside: Bool) {
        if !inside {
            pointerWasInside = false
            hoverSuppressedUntilExit = false
            hoverTask?.cancel()
            hoverTask = nil
            return
        }
        guard !pointerWasInside, !hoverSuppressedUntilExit, isOnActiveSpace,
              NSEvent.pressedMouseButtons == 0 else { return }
        pointerWasInside = true
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 70_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.isOnActiveSpace, !self.hoverSuppressedUntilExit,
                  self.panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation),
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.hoverTask = nil
            self.onHover()
        }
    }

    /// Turns the bar off completely.
    func hide() {
        spaceGeneration += 1 // Ignore an in-flight window-server response.
        pendingSpaceCheck?.cancel()
        pendingSpaceCheck = nil
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        conceal()
    }

    private func tick() {
        // Widen and show the status while Bibbles is working.
        let status = activity()
        let isInteracting = interactionActive()
        let visibilityChanged = lastInteractionActive != isInteracting
        lastInteractionActive = isInteracting
        if state.status != status { state.status = status }
        if visibilityChanged {
            lastPresentationAttempt = .distantPast
            updateVisibility()
        }
        let wing = status != nil ? NotchGeometry.activeWing : NotchGeometry.wing
        if state.wing != wing {
            state.wing = wing
            if panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                    self.panel.animator().setFrame(self.targetFrame, display: true)
                }
            }
        }
        if !isOnActiveSpace {
            pointerWasInside = false
            // AppKit can report a window as visible even when it remained on
            // the previous Space. Retry at most once per second, only while
            // our visibility rule says the notch should be present.
            if !checkingSpace, !panel.isOnActiveSpace,
               NotchVisibilityPolicy.shouldShow(enabled: true, checkingSpace: false,
                                                fullScreen: fullScreen, appHasKeyWindow: appHasKeyWindow,
                                                interactionActive: isInteracting) {
                updateVisibility()
            }
            return
        }
        requestHover()
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name, refreshSpace: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.timer != nil else { return }
                if name == NSApplication.didChangeScreenParametersNotification {
                    self.reposition()
                }
                if refreshSpace { self.refreshSpace() }
                else { self.updateVisibility() }
            }
        }
        observers.append((center, token))
    }

    private func refreshSpace() {
        pendingSpaceCheck?.cancel()
        spaceGeneration += 1
        let generation = spaceGeneration
        checkingSpace = true
        if interactionActive() { updateVisibility() }
        else { conceal() } // No idle overlay during a Space switch.
        guard let screen = NotchGeometry.preferredScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            checkingSpace = false
            fullScreen = false
            updateVisibility()
            return
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let frame = screen.frame
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // The notification can arrive before the window server finishes the
        // transition. Wait briefly on the utility queue for the new Space ID.
        let work = DispatchWorkItem { [weak self] in
            let result = FullScreenDetector.snapshot(displayID: displayID, frame: frame,
                                                     frontmostPID: frontmostPID)
            Task { @MainActor [weak self] in
                guard let self, self.timer != nil, generation == self.spaceGeneration else { return }
                self.fullScreen = result.fullScreen
                self.checkingSpace = false
                self.lastPresentationAttempt = .distantPast
                self.updateVisibility()
            }
        }
        pendingSpaceCheck = work
        detectionQueue.asyncAfter(deadline: .now() + .milliseconds(60), execute: work)
    }

    private func updateVisibility() {
        let hasKeyWindow = appHasKeyWindow
        let isInteracting = interactionActive()
        let shouldShow = NotchVisibilityPolicy.shouldShow(enabled: timer != nil, checkingSpace: checkingSpace,
                                                          fullScreen: fullScreen, appHasKeyWindow: hasKeyWindow,
                                                          interactionActive: isInteracting)
        if !shouldShow { conceal(); return }
        let behavior = isInteracting || (fullScreen && hasKeyWindow)
            ? NotchGeometry.everySpace.union(.fullScreenAuxiliary) : NotchGeometry.everySpace
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
        if panel.isVisible && panel.isOnActiveSpace { return }
        guard Date().timeIntervalSince(lastPresentationAttempt) >= 0.8 else { return }
        lastPresentationAttempt = Date()
        if panel.isVisible { panel.orderOut(nil) }
        reposition()
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        panel.orderFrontRegardless()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func conceal() {
        hoverTask?.cancel()
        hoverTask = nil
        pointerWasInside = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onHidden()
    }

    private func reposition() {
        let frame = targetFrame
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }
}

private struct NotchPillView: View {
    @ObservedObject var history: TaskHistorySnapshot
    @ObservedObject var state: NotchPillState
    let onClick: () -> Void
    let onPointerChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pulse = false
    private static let tallBars: [CGFloat] = [9, 14, 11, 7]
    private static let shortBars: [CGFloat] = [5, 8, 6, 4]

    private var tasksToday: Int {
        history.items.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                NotchShape(radius: min(NotchGeometry.cornerRadius, proxy.size.height * 0.42))
                    .fill(Color.black)
                HStack(spacing: 0) {
                    leftWing
                        .frame(width: state.wing)
                    Spacer(minLength: 0)
                    rightWing
                        .frame(width: state.wing)
                }
                // Keep the icons level with the menu bar, above the extra drop.
                .padding(.bottom, NotchGeometry.drop)
                #if BIBBLES_DEVELOPER
                if LocalMode.isOn {
                    // Developer builds: requests go straight to the providers.
                    VStack {
                        Spacer(minLength: 0)
                        Text("LOCAL MODE")
                            .font(.system(size: 7, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(Color.orange)
                            .padding(.bottom, 1)
                    }
                    .allowsHitTesting(false)
                }
                #endif
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in hovering = inside; onPointerChanged(inside) }
        .onTapGesture(perform: onClick)
        .help("Bibbles · task history")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bibbles task history")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onClick() }
    }

    private var leftWing: some View {
        HStack(spacing: 7) {
            Image(nsImage: BibblesBrandIcon.menuBarImage())
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 15)
                .foregroundStyle(hovering ? BibblesStyle.accentDeep : Color.white.opacity(0.92))
                .shadow(color: BibblesStyle.accent.opacity(hovering ? 0.8 : 0.35), radius: hovering ? 6 : 3)
            if let status = state.status {
                Text(status)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, state.status == nil ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: state.status == nil ? .center : .leading)
        .animation(.easeOut(duration: 0.18), value: state.status)
    }

    @ViewBuilder private var rightWing: some View {
        if state.status == "Speaking" || state.status == "Listening" || state.status == "Dictating" {
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(BibblesStyle.barColors[index])
                        .frame(width: 2.5, height: pulse ? Self.tallBars[index] : Self.shortBars[index])
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = !reduceMotion }
            .onChange(of: reduceMotion) { pulse = !$0 }
            .onDisappear { pulse = false }
        } else if state.status != nil {
            ProgressView()
                .controlSize(.mini)
                .tint(BibblesStyle.accent)
        } else if tasksToday > 0 {
            Text("\(min(tasksToday, 99))")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 18, minHeight: 18)
                .background(
                    LinearGradient(colors: [BibblesStyle.accent, BibblesStyle.accentSecondary],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .help("\(tasksToday) task\(tasksToday == 1 ? "" : "s") today")
        } else {
            Circle()
                .fill(BibblesStyle.accent)
                .frame(width: 6, height: 6)
                .shadow(color: BibblesStyle.accent, radius: 4)
        }
    }
}

/// Flat along the top edge, with smooth, generously rounded bottom corners,
/// like a tab hanging from the notch.
private struct NotchShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        // Control points at 0.45 of the radius give a softer, "continuous" curve.
        let k = r * 0.45
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.maxY - r + k + r * 0.1),
                      control2: CGPoint(x: rect.maxX - r + k, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                      control1: CGPoint(x: rect.minX + r - k, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.maxY - r + k + r * 0.1))
        path.closeSubpath()
        return path
    }
}
