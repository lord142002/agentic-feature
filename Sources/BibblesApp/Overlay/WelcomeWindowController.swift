import AppKit
import SwiftUI

/// The "Welcome to Bibbles" guide, in the website's dark violet style.
@MainActor
final class WelcomeWindowController {
    private let window: NSWindow
    private let onSetUpPermissions: () -> Void
    private let onSignIn: () -> Void

    init(onSetUpPermissions: @escaping () -> Void, onSignIn: @escaping () -> Void) {
        self.onSetUpPermissions = onSetUpPermissions
        self.onSignIn = onSignIn
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: WelcomeView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Bibbles"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.024, green: 0.024, blue: 0.047, alpha: 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func show() {
        let status = PermissionService.snapshot()
        let needsPermissions = !status.accessibility || status.microphone != .authorized || !status.screenRecording
        window.contentView = NSHostingView(rootView: WelcomeView(
            needsPermissions: needsPermissions,
            onDone: { [weak self] in self?.window.orderOut(nil) },
            onPermissions: { [weak self] in
                self?.window.orderOut(nil)
                self?.onSetUpPermissions()
            },
            onSignIn: { [weak self] in
                self?.window.orderOut(nil)
                self?.onSignIn()
            }
        ))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct WelcomeView: View {
    static let width: CGFloat = 640
    static let height: CGFloat = 720
    let needsPermissions: Bool
    @ObservedObject private var account = AccountSession.shared
    let onDone: () -> Void
    let onPermissions: () -> Void
    let onSignIn: () -> Void

    /// Same palette as Settings → Account.
    private static let rainbow: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 1.0),
        Color(red: 0.66, green: 0.55, blue: 1.0),
        Color(red: 0.98, green: 0.58, blue: 0.86),
        Color(red: 1.0, green: 0.82, blue: 0.50),
        Color(red: 0.58, green: 0.95, blue: 0.74)
    ]
    /// Only these limits are shown; the server still enforces all of them.
    private static let visibleCounterIDs = ["asks", "deep_tasks", "deep", "screen_help"]

    private let gradient = LinearGradient(colors: [BibblesStyle.accent, BibblesStyle.accentSecondary],
                                          startPoint: .leading, endPoint: .trailing)
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title, clear of the window buttons.
            HStack(alignment: .center, spacing: 16) {
                BibblesBrandMark(size: 52)
                    .shadow(color: BibblesStyle.accent.opacity(0.45), radius: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Bibbles")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Your AI assistant for the whole Mac.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)

            if let email = account.email {
                accountCard(email: email)
                    .padding(.bottom, 12)
                usageCard
                    .padding(.bottom, 20)
            } else {
                signedOutCard
                    .padding(.bottom, 20)
            }

            label("Shortcuts")
            LazyVGrid(columns: columns, spacing: 12) {
                shortcut(["⌃", "⌥"], "Hold to ask", "Talk, then let go. Ask anything, even about your screen.")
                shortcut(["fn", "⌃"], "Hold to dictate", "Types what you say into any app.")
                shortcut(["⌃", "⌃"], "Type instead", "Press Control twice to type to Bibbles.")
                shortcut(["⌃", "⌘", "A"], "Open chat", "All your conversations in one place.")
            }

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button(account.email == nil ? "Sign in or create account" : "Manage account", action: onSignIn)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                if needsPermissions {
                    Button(action: onPermissions) {
                        Text("Set Up Permissions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onDone) {
                    Text("Get Started")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(gradient))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                        .shadow(color: BibblesStyle.accent.opacity(0.4), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 50)
        .padding(.bottom, 26)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(
            ZStack {
                LinearGradient(colors: [BibblesStyle.brandNight, BibblesStyle.brandBackground],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [BibblesStyle.accent.opacity(0.18), .clear],
                               center: .topTrailing, startRadius: 10, endRadius: 460)
            }
        )
        .environment(\.colorScheme, .dark)
        .onExitCommand(perform: onDone)
        .task(id: account.email) {
            if account.email != nil { await account.refreshWorkerUsage() }
        }
    }

    // MARK: Account

    private var planName: String? { account.effectivePlanName }
    private var isPremium: Bool { PlanEntitlement.isPremium(plan: planName) }

    private func accountCard(email: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(String(email.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LinearGradient(colors: [Self.rainbow[0], Self.rainbow[1]],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(email)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    Label("Signed in", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.52, green: 0.88, blue: 0.72))
                }
                Spacer(minLength: 8)
                planBadge
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            HStack(spacing: 10) {
                Image(systemName: isPremium ? "calendar.badge.clock" : "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isPremium ? Self.rainbow[1] : Self.rainbow[3])
                Text(planLine)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(planDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(planWarning ? Color(red: 1, green: 0.68, blue: 0.49) : .white.opacity(0.5))
                Spacer(minLength: 8)
                if let action = planAction {
                    Button { PlansWindowController.shared.show() } label: {
                        Text(action)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Capsule().fill(LinearGradient(colors: [Self.rainbow[0], Self.rainbow[1], Self.rainbow[2]],
                                                                      startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.055), Color.white.opacity(0.02)],
                                 startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isPremium
                          ? AnyShapeStyle(LinearGradient(colors: Self.rainbow.map { $0.opacity(0.45) },
                                                         startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(BibblesStyle.hairline), lineWidth: 1))
    }

    private var planBadge: some View {
        HStack(spacing: 5) {
            if isPremium { Image(systemName: "crown.fill").font(.system(size: 9.5, weight: .bold)) }
            Text(planName?.replacingOccurrences(of: "_", with: " ").capitalized ?? "—")
                .font(.system(size: 11.5, weight: .bold))
        }
        .foregroundStyle(isPremium ? Color.black : Color.white.opacity(0.75))
        .padding(.horizontal, 11)
        .frame(height: 24)
        .background(Capsule().fill(isPremium
            ? AnyShapeStyle(LinearGradient(colors: [Self.rainbow[3], Self.rainbow[2]], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(Color.white.opacity(0.08))))
    }

    private var planLine: String {
        guard planName != nil else { return account.usageIsRefreshing ? "Loading your plan…" : "Plan unavailable" }
        guard isPremium else { return "Alpha (free) plan" }
        if let expires = account.planEntitlement?.expiresAt {
            return expires < Date() ? "Expired \(shortDate(expires))" : "Premium until \(shortDate(expires))"
        }
        if let renews = account.planEntitlement?.renewsAt { return "Renews \(shortDate(renews))" }
        return "Premium is active"
    }

    private var planDetail: String {
        guard isPremium, let expires = account.planEntitlement?.expiresAt else { return "" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: expires)).day ?? 0
        if days < 0 { return "" }
        if days == 0 { return "· expires today" }
        return days == 1 ? "· 1 day left" : "· \(days) days left"
    }

    private var planWarning: Bool {
        guard isPremium, let expires = account.planEntitlement?.expiresAt else { return false }
        return expires.timeIntervalSinceNow < 7 * 86_400
    }

    /// Both open the "Choose your plan" window (Alpha / Sigma / Omega).
    private var planAction: String? {
        guard planName != nil else { return nil }
        return isPremium ? "Change plan" : "Upgrade"
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    // MARK: Usage

    private var shownCounters: [WorkerUsageSnapshot.Counter] {
        (account.workerUsage?.counters ?? [])
            .filter { Self.visibleCounterIDs.contains($0.id.lowercased()) }
            .sorted { Self.visibleCounterIDs.firstIndex(of: $0.id.lowercased()) ?? 0
                    < Self.visibleCounterIDs.firstIndex(of: $1.id.lowercased()) ?? 0 }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Monthly usage")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                if let month = account.workerUsage?.month {
                    Text(monthTitle(month))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if account.usageIsRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await account.refreshWorkerUsage() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh usage")
                }
            }
            if shownCounters.isEmpty {
                Text(account.usageError ?? (account.usageIsRefreshing ? "Loading your usage…" : "Usage isn’t available yet."))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(shownCounters) { counter in usageMetric(counter) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BibblesStyle.hairline, lineWidth: 1))
    }

    private func usageMetric(_ counter: WorkerUsageSnapshot.Counter) -> some View {
        let fraction = counter.limit > 0 ? min(1, Double(counter.used) / Double(counter.limit)) : (counter.used > 0 ? 1 : 0)
        let ink = fraction >= 0.9 ? Color(red: 1, green: 0.68, blue: 0.49) : Self.rainbow[0]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(counter.title)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(counter.limit > 0 ? "\(counter.remaining.formatted()) left" : "Not included")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.white.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(ink).frame(width: geometry.size.width * fraction)
                    }
            }
            .frame(height: 3)
            Text("\(counter.used.formatted()) / \(counter.limit.formatted()) used")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthTitle(_ month: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: month) else { return month }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: date)
    }

    // MARK: Signed out

    private var signedOutCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Self.rainbow[1])
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign in to start using Bibbles")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Your plan and monthly usage appear here.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            Button(action: onSignIn) {
                Text("Sign in")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule().fill(LinearGradient(colors: [Self.rainbow[0], Self.rainbow[1]],
                                                              startPoint: .leading, endPoint: .trailing)))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BibblesStyle.hairline, lineWidth: 1))
    }

    // MARK: Shortcuts

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.bottom, 10)
    }

    private func shortcut(_ keys: [String], _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(minWidth: 24, minHeight: 24)
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                }
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BibblesStyle.hairline, lineWidth: 1))
    }
}

/// Lays chips out left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 560
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
