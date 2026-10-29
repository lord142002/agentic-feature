import AppKit
import SwiftUI

/// "Choose your plan": Alpha, Sigma and Omega side by side with live Dodo
/// prices. Picking a paid plan opens Dodo checkout (or switches the running
/// subscription); payment never happens inside the app.
@MainActor
final class PlansWindowController: NSObject, NSWindowDelegate {
    static let shared = PlansWindowController()

    private let window: NSWindow
    private let model = PlansModel()

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Choose your plan"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.067, alpha: 1)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: PlansView(model: model, close: { [weak self] in self?.hide() }))
    }

    func show() {
        ProductAnalytics.shared.screen(.plans)
        model.load()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        ProductAnalytics.shared.leaveScreen(.plans)
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ProductAnalytics.shared.leaveScreen(.plans)
    }
}

@MainActor
final class PlansModel: ObservableObject {
    enum State: Equatable { case loading, loaded([BillingPlan]), failed(String) }
    @Published private(set) var state: State = .loading
    @Published var choosing: String?
    private var loadTask: Task<Void, Never>?

    func load() {
        loadTask?.cancel()
        if case .loaded = state {} else { state = .loading }
        loadTask = Task { [weak self] in
            do {
                let plans = try await BillingAPI.plans()
                guard !Task.isCancelled else { return }
                self?.state = .loaded(plans)
            } catch {
                guard !Task.isCancelled, let self else { return }
                if case .loaded = self.state { return } // keep showing the last good list
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}

private enum PlansTheme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.067)
    static let rainbow: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 1.0),
        Color(red: 0.66, green: 0.55, blue: 1.0),
        Color(red: 0.98, green: 0.58, blue: 0.86),
        Color(red: 1.0, green: 0.82, blue: 0.50),
        Color(red: 0.58, green: 0.95, blue: 0.74)
    ]
    static let gradient = LinearGradient(colors: [rainbow[0], rainbow[1], rainbow[2]], startPoint: .leading, endPoint: .trailing)
    static let mint = Color(red: 0.58, green: 0.95, blue: 0.74)
}

private struct PlansView: View {
    @ObservedObject var model: PlansModel
    @ObservedObject private var account = AccountSession.shared
    let close: () -> Void

    private var currentPlan: String { (account.effectivePlanName ?? "alpha").lowercased() }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(minWidth: 860, minHeight: 600)
        .background(PlansTheme.background)
        .onChange(of: account.effectivePlanName) { _ in model.choosing = nil }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Choose your plan")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("Upgrade any time. Cancel any time — you keep your plan until the month you paid for ends.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("Loading plans…").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5))
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button("Try again") { model.load() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18).frame(height: 32)
                    .background(Capsule().fill(Color.white))
            }
        case .loaded(let plans):
            HStack(alignment: .top, spacing: 16) {
                ForEach(plans) { plan in
                    PlanCard(plan: plan, isCurrent: plan.id == currentPlan, button: button(for: plan),
                             workingText: workingText(for: plan))
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = account.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.68, blue: 0.49))
            } else if account.awaitingPayment, let pending = account.pendingPlan {
                Label("Waiting for Dodo to confirm \(pending.capitalized)… this updates by itself.",
                      systemImage: "hourglass")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 14) {
                Label("Secure payment by Dodo Payments", systemImage: "lock.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42))
                Spacer()
                if account.billingStatus?.manageAvailable == true {
                    Button("Manage billing & invoices") { Task { await account.openBillingPortal() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button("Close") { close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.top, 18)
    }

    private func workingText(for plan: BillingPlan) -> String? {
        guard model.choosing == plan.id else { return nil }
        if account.billingBusy { return "Opening checkout…" }
        if account.awaitingPayment && account.pendingPlan == plan.id { return "Waiting for payment…" }
        return nil
    }

    private func button(for plan: BillingPlan) -> PlanCard.ButtonSpec {
        if plan.id == currentPlan { return .init(title: "Current plan", style: .current, action: nil) }
        let onPaidPlan = PlanEntitlement.isPremium(plan: currentPlan)
        if plan.isFree {
            // Going back to free = cancelling, which Dodo's portal handles.
            guard onPaidPlan, account.billingStatus?.manageAvailable == true else {
                return .init(title: "Free", style: .quiet, action: nil)
            }
            return .init(title: "Cancel paid plan", style: .quiet) { Task { await account.openBillingPortal() } }
        }
        guard plan.isPurchasable else { return .init(title: "Coming soon", style: .quiet, action: nil) }
        let title = onPaidPlan ? "Switch to \(plan.name)" : "Choose \(plan.name)"
        return .init(title: title, style: plan.isHighlighted ? .primary : .secondary) {
            model.choosing = plan.id
            Task {
                let started = await account.startCheckout(plan: plan.id)
                if !started { model.choosing = nil }
            }
        }
    }
}

private struct PlanCard: View {
    struct ButtonSpec {
        enum Style { case primary, secondary, current, quiet }
        let title: String
        let style: Style
        let action: (() -> Void)?
    }

    let plan: BillingPlan
    let isCurrent: Bool
    let button: ButtonSpec
    /// Shown with a spinner while this plan's checkout is opening or awaiting payment.
    let workingText: String?
    private var isWorking: Bool { workingText != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(plan.name)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                if isCurrent {
                    badge("Your plan", fill: AnyShapeStyle(PlansTheme.mint.opacity(0.18)), ink: PlansTheme.mint)
                } else if plan.isHighlighted {
                    badge("Most popular", fill: AnyShapeStyle(PlansTheme.gradient), ink: .black)
                }
            }
            if !plan.tagline.isEmpty {
                Text(plan.tagline)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
            }

            priceLine.padding(.top, 20)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.features, id: \.self) { feature in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(plan.isHighlighted ? PlansTheme.rainbow[1] : PlansTheme.mint)
                        Text(feature)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 20)
            actionButton
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(plan.isHighlighted ? 0.075 : 0.05), Color.white.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(plan.isHighlighted
                              ? AnyShapeStyle(LinearGradient(colors: PlansTheme.rainbow.map { $0.opacity(0.6) },
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.white.opacity(isCurrent ? 0.22 : 0.09)),
                              lineWidth: plan.isHighlighted ? 1.5 : 1)
        )
    }

    @ViewBuilder private var priceLine: some View {
        if plan.isFree {
            Text("Free").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
        } else if let price = plan.price {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price.formatted).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(price.period).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                if price.taxInclusive == true {
                    Text("Taxes included").font(.system(size: 11)).foregroundStyle(.white.opacity(0.38))
                }
            }
        } else {
            Text("—").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var actionButton: some View {
        Button { button.action?() } label: {
            HStack(spacing: 8) {
                if isWorking { ProgressView().controlSize(.small).tint(button.style == .primary ? .black : .white) }
                Text(workingText ?? button.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(background)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(button.action == nil || isWorking)
    }

    private var foreground: Color {
        switch button.style {
        case .primary: return .black
        case .secondary: return .black
        case .current: return PlansTheme.mint
        case .quiet: return .white.opacity(0.6)
        }
    }

    @ViewBuilder private var background: some View {
        switch button.style {
        case .primary: Capsule().fill(PlansTheme.gradient)
        case .secondary: Capsule().fill(Color.white)
        case .current: Capsule().strokeBorder(PlansTheme.mint.opacity(0.45), lineWidth: 1)
        case .quiet: Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func badge(_ text: String, fill: AnyShapeStyle, ink: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Capsule().fill(fill))
    }
}
