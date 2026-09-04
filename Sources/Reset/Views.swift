import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isRefreshHovered = false
    @State private var isSettingsHovered = false
    @State private var measuredCardsHeight: CGFloat = 0
    @State private var measuredHeaderHeight: CGFloat = 0

    var body: some View {
        dashboard
            .frame(width: 330, alignment: .topLeading)
            .frame(height: dashboardHeight, alignment: .top)
    }

    private var dashboardHeight: CGFloat {
        let activeScreen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        let available = activeScreen?.visibleFrame.height ?? 800
        let maximum = max(360, available - 96)
        guard measuredHeaderHeight > 0, measuredCardsHeight > 0 else {
            return min(520, maximum)
        }
        return min(maximum, ceil(measuredHeaderHeight + measuredCardsHeight + 16))
    }

    @ViewBuilder
    private var dashboard: some View {
        ScrollView(.vertical) {
            Group {
                if model.statuses.isEmpty && model.visibleBuildIntegrations.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.isRefreshing ? "正在读取 Agent 与额度…" : "正在准备 Agent 状态…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                } else {
                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(model.visibleStatuses) { status in
                                QuotaCard(status: status) { model.openAgent(status.provider) }
                            }
                            ForEach(model.visibleBuildIntegrations) { status in
                                BuildIntegrationCard(status: status)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DashboardCardsHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                }
            }
            .background(ScrollElasticityConfigurator())
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .safeAreaBar(edge: .top, spacing: 0) {
            dashboardHeader
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: DashboardHeaderHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .frame(width: 330, alignment: .topLeading)
        .onPreferenceChange(DashboardCardsHeightKey.self) { measuredCardsHeight = $0 }
        .onPreferenceChange(DashboardHeaderHeightKey.self) { measuredHeaderHeight = $0 }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RESET!").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 8) {
                        Text("额度总览").font(.title2.weight(.bold))
                    }
                    Text(model.lastUpdated.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未更新")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                HStack(alignment: .center, spacing: 8) {
                    Button { Task { await model.refresh() } } label: {
                        Group {
                            if model.isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title3.weight(.medium))
                            }
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Color.primary.opacity(isRefreshHovered ? 0.12 : 0)))
                    .contentShape(Circle())
                    .onHover { isRefreshHovered = $0 }
                    .help("刷新额度")
                    .disabled(model.isRefreshing)
                    Button {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: ResetWindow.settings)
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            NSApp.activate(ignoringOtherApps: true)
                            let settingsWindow = NSApp.windows.first {
                                $0.canBecomeKey && $0.level == .normal
                                    && ($0.identifier?.rawValue == ResetWindow.settings || $0.title == "设置")
                            }
                            settingsWindow?.deminiaturize(nil)
                            settingsWindow?.makeKeyAndOrderFront(nil)
                            settingsWindow?.orderFrontRegardless()
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Color.primary.opacity(isSettingsHovered ? 0.12 : 0)))
                    .contentShape(Circle())
                    .onHover { isSettingsHovered = $0 }
                    .help("设置")
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

}

private struct CursorQuotaList: View {
    let usage: ProviderUsage
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let window = usage.cursorAutoComposer {
                QuotaMetric(
                    title: "Auto + Composer 额度",
                    window: window,
                    tint: gradient.last ?? .indigo,
                    gradient: gradient
                )
            }
            if let window = usage.displayableCursorAPIWindow {
                QuotaMetric(
                    title: "API 额度",
                    window: window,
                    tint: gradient.last ?? .indigo,
                    gradient: gradient
                )
            }
            if usage.subscriptionTier?.localizedCaseInsensitiveContains("free") == true {
                Text("Cursor Free 账户额度仅供参考，有可能剩余额度但仍然无法使用，请以 App 内显示为准或升级 Pro 套餐")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct QuotaCard: View {
    let status: AgentStatus
    var onOpen: (() -> Void)? = nil
    @State private var showsModelDetails = false
    @State private var isAgentIconHovered = false

    private var tint: Color { status.provider.accent }
    private var tintGradient: [Color] { status.provider.accentGradient }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let onOpen {
                    Button(action: onOpen) {
                        ZStack {
                            AgentIcon(provider: status.provider, size: 38)
                                // Alter only the image pixels. No overlay is used,
                                // so the hover treatment cannot extend past the icon.
                                .colorMultiply(isAgentIconHovered ? Color(white: 0.5) : .white)
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                                .opacity(isAgentIconHovered ? 1 : 0)
                                .scaleEffect(isAgentIconHovered ? 1 : 0.7)
                        }
                        .frame(width: 38, height: 38)
                        .animation(.easeInOut(duration: 0.18), value: isAgentIconHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { isAgentIconHovered = $0 }
                    .help("打开 \(status.provider.title)")
                } else {
                    AgentIcon(provider: status.provider, size: 38)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.provider.title).font(.headline.weight(.semibold))
                    Text(status.provider.company)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(state: status.state)
            }

            if let usage = status.usage {
                if status.provider == .cursor {
                    CursorQuotaList(usage: usage, gradient: tintGradient)
                } else if status.provider == .googleAntigravity {
                    AntigravityCompactQuotaList(groups: usage.groups)
                    if let credits = usage.displayableAICredits {
                        AntigravityCreditsRow(credits: credits)
                    }
                } else if usage.groups.isEmpty {
                    if let fiveHour = usage.fiveHour {
                        QuotaMetric(title: "5 小时内额度", window: fiveHour, tint: tint, gradient: tintGradient)
                    }
                    if let longWindow = usage.sevenDay ?? usage.monthly {
                        QuotaMetric(
                            title: usage.sevenDay != nil ? "一周额度" : "账单周期",
                            window: longWindow,
                            tint: tint,
                            gradient: tintGradient
                        )
                    }
                    if let api = usage.displayableAPIWindow {
                        QuotaMetric(title: "API 额度", window: api, tint: tint, gradient: tintGradient)
                    }
                    if status.provider == .kimiCode,
                       let balance = usage.extraUsageBalance,
                       let currency = usage.extraUsageCurrency {
                        KimiExtraUsageRow(balance: balance, currency: currency)
                    }
                } else {
                    let summary = usage.groups.compactSummary
                    QuotaMetric(title: "模型额度（\(usage.groups.count) 个模型）", window: summary.window, tint: tint, gradient: tintGradient)
                    if let credits = usage.displayableAICredits {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(.yellow)
                            Text("AI Credits").font(.caption.weight(.medium))
                            Spacer()
                            Text("\(Int(credits))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.35, extraBounce: 0)) {
                            showsModelDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                            Text(showsModelDetails ? "收起模型明细" : "展开模型明细")
                            Spacer()
                            Text("\(usage.groups.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    if showsModelDetails {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(usage.groups.enumerated()), id: \.offset) { _, group in
                                CompactModelTile(group: group)
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
            }
        }
        .padding(14)
        .quotaGlass(cornerRadius: 12)
    }
}

private struct KimiExtraUsageRow: View {
    let balance: Double
    let currency: String

    private var formattedBalance: String {
        let code = currency.uppercased()
        let symbol = code == "CNY" ? "¥" : (code == "USD" ? "$" : "\(code) ")
        return "\(symbol)\(balance.formatted(.number.precision(.fractionLength(2))))"
    }

    var body: some View {
        HStack {
            Text("额外用量余额")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(formattedBalance)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

private func antigravityGroupOrder(_ lhs: QuotaGroup, _ rhs: QuotaGroup) -> Bool {
    func rank(_ name: String) -> Int {
        name == "Gemini Models" ? 0 : name == "Claude and GPT models" ? 1 : 2
    }
    return rank(lhs.name) < rank(rhs.name)
}

private struct AntigravityCompactQuotaList: View {
    let groups: [QuotaGroup]

    private var gemini: QuotaGroup? {
        groups.first { $0.name.localizedCaseInsensitiveContains("gemini") }
    }

    private var thirdParty: QuotaGroup? {
        groups.first { !$0.name.localizedCaseInsensitiveContains("gemini") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // Keep each shared model pool together so its short and long windows
            // can be understood as a single quota at a glance.
            if let window = gemini?.fiveHour {
                AntigravityCompactQuotaRow(
                    groupName: "Gemini models",
                    quotaName: "5 小时内额度",
                    window: window,
                    gradient: [.blue, .cyan]
                )
            }
            if let window = gemini?.sevenDay {
                AntigravityCompactQuotaRow(
                    groupName: "Gemini models",
                    quotaName: "一周额度",
                    window: window,
                    gradient: [.blue, .cyan]
                )
            }
            if (gemini?.fiveHour != nil || gemini?.sevenDay != nil),
               (thirdParty?.fiveHour != nil || thirdParty?.sevenDay != nil) {
                Divider().opacity(0.5)
            }
            if let window = thirdParty?.fiveHour {
                AntigravityCompactQuotaRow(
                    groupName: "Claude/ChatGPT models",
                    quotaName: "5 小时内额度",
                    window: window,
                    gradient: thirdPartyGradient
                )
            }
            if let window = thirdParty?.sevenDay {
                AntigravityCompactQuotaRow(
                    groupName: "Claude/ChatGPT models",
                    quotaName: "一周额度",
                    window: window,
                    gradient: thirdPartyGradient
                )
            }
        }
    }

    private var thirdPartyGradient: [Color] {
        [
            Color(red: 0.72, green: 0.49, blue: 0.02),
            Color(red: 0.96, green: 0.73, blue: 0.08)
        ]
    }
}

private struct AntigravityCreditsRow: View {
    let credits: Double

    var body: some View {
        HStack {
            Text("API 额度")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("剩余 \(credits.formatted(.number.precision(.fractionLength(0...2))))")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(credits > 0 ? Color.secondary : Color.red)
        }
    }
}

private struct AntigravityCompactQuotaRow: View {
    let groupName: String
    let quotaName: String
    let window: QuotaWindow
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(groupName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(gradient.first ?? .blue)
                    .lineLimit(1)
                Text(quotaName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("剩余 \(Int(window.remaining))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(window.remaining < 20 ? .red : gradient.last ?? .blue)
                    .fixedSize()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: window.remaining < 20 ? [.red, .orange] : gradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(5, proxy.size.width * window.remaining / 100))
                }
            }
            .frame(height: 8)
            Text(window.resetsAt.map { "重置于 \(chineseDateTime($0))" } ?? "重置时间未提供")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AntigravityQuotaGroupView: View {
    let group: QuotaGroup
    let tint: Color
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(group.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let fiveHour = group.fiveHour {
                QuotaMetric(title: "5 小时内额度", window: fiveHour, tint: tint, gradient: gradient)
            }
            if let weekly = group.sevenDay {
                QuotaMetric(title: "一周额度", window: weekly, tint: tint, gradient: gradient)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AgentIcon: View {
    let provider: ProviderKind
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: provider.iconResource, withExtension: "png", subdirectory: "AgentIcons") ??
                Bundle.main.url(forResource: provider.iconResource, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "cpu").resizable().scaledToFit().padding(8)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

private struct StatusPill: View {
    let state: AgentState

    private var symbol: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .installed: "checkmark.circle"
        case .needsLogin: "person.crop.circle.badge.exclamationmark"
        case .tokenStale: "arrow.triangle.2.circlepath.circle"
        case .unavailable: "exclamationmark.circle"
        case .notInstalled: "minus.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .connected: Color(nsColor: .systemGreen)
        case .needsLogin, .tokenStale: Color(nsColor: .systemOrange)
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 16, height: 16)
            Text(state.title)
                .foregroundStyle(.secondary)
                .font(.caption.weight(.medium))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaMetric: View {
    let title: String
    let window: QuotaWindow
    let tint: Color
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("剩余 \(Int(window.remaining))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(window.remaining < 20 ? .red : tint)
                    .contentTransition(.numericText(value: window.remaining))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(window.remaining < 20
                        ? LinearGradient(colors: [.red.opacity(0.82), .pink.opacity(0.72)], startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * window.remaining / 100))
                }
            }
            .frame(height: 8)
            Text(window.resetsAt.map { "重置于 \(chineseDateTime($0))" } ?? "重置时间未提供")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private let chineseResetDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
}()

private func chineseDateTime(_ date: Date) -> String {
    chineseResetDateFormatter.string(from: date)
}

private struct ScrollElasticityConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(from: view) }
    }

    private func configure(from view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }
}

private extension View {
    @ViewBuilder
    func quotaGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

private struct ModelQuotaRow: View {
    let group: QuotaGroup

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill((group.fiveHour ?? group.sevenDay)?.remaining ?? 0 < 20 ? .red : .green).frame(width: 6, height: 6)
            Text(group.name).lineLimit(1).font(.caption2)
            Spacer()
            if let window = group.fiveHour ?? group.sevenDay {
                Text("\(Int(window.remaining))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CompactModelTile: View {
    let group: QuotaGroup

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill((group.fiveHour ?? group.sevenDay)?.remaining ?? 0 < 20 ? .red : .green)
                .frame(width: 6, height: 6)
            Text(group.name)
                .font(.caption2)
                .lineLimit(1)
            Spacer(minLength: 2)
            if let window = group.fiveHour ?? group.sevenDay {
                Text("\(Int(window.remaining))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

private struct ModelDetailsView: View {
    let provider: ProviderKind
    let groups: [QuotaGroup]
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                AgentIcon(provider: provider, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).font(.headline)
                    Text("模型额度明细").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(groups.count) 个模型").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in ModelQuotaRow(group: group) }
                }
                .padding(.bottom, 8)
            }
            .frame(height: 520)
        }
        .padding(18)
        .frame(width: 330, alignment: .topLeading)
    }
}

private extension Array where Element == QuotaGroup {
    var compactSummary: (window: QuotaWindow, reset: Date?) {
        let windows = compactMap { $0.fiveHour ?? $0.sevenDay }
        let remaining = windows.map(\.remaining).min() ?? 0
        let reset = windows.compactMap(\.resetsAt).min()
        return (QuotaWindow(utilization: 100 - remaining, resetsAt: reset, windowSeconds: 5 * 3600), reset)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sparkle = SparkleUpdateController.shared
    @State private var selectedPane: SettingsPane = .general
    @State private var backStack: [SettingsPane] = []
    @State private var forwardStack: [SettingsPane] = []
    @State private var isHistoryNavigation = false

    private enum SettingsPane: String, CaseIterable, Identifiable {
        case general, about
        var id: Self { self }
        var title: String {
            switch self {
            case .general: "通用"
            case .about: "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 210)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                switch selectedPane {
                case .general:
                    Section("启动") {
                        Toggle("登录时打开 Reset!", isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        if model.launchAtLoginRequiresApproval {
                            LabeledContent("需要系统批准") {
                                Button("打开登录项设置") { model.openLoginItemsSettings() }
                            }
                        }
                    }
                    Section("通知") {
                        Toggle("允许 Reset! 发送设备通知", isOn: Binding(
                            get: { model.deviceNotificationsEnabled },
                            set: { enabled in Task { await model.setDeviceNotificationsEnabled(enabled) } }
                        ))
                    }
                    Section {
                        ForEach(ProviderKind.allCases) { provider in
                            Toggle(isOn: Binding(
                                get: { model.providerEnabled(provider) },
                                set: { model.setProvider(provider, enabled: $0) }
                            )) {
                                ProviderIntegrationLabel(provider: provider)
                            }
                        }
                        Toggle(isOn: Binding(
                            get: { model.grokBuildIntegrationEnabled },
                            set: { model.setBuildIntegration(.grokBuild, enabled: $0) }
                        )) {
                            BuildIntegrationLabel(integration: .grokBuild)
                        }
                    } header: {
                        Text("Agent 接入")
                    }
                case .about:
                    Section {
                        VStack(spacing: 10) {
                            Image(nsImage: NSApplication.shared.applicationIconImage)
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .scaledToFit()
                                .frame(width: 76, height: 76)

                            VStack(spacing: 3) {
                                Text("Reset!")
                                    .font(.title2.weight(.semibold))
                                Text("版本 \(model.appVersion)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    Section("更新") {
                        LabeledContent("更新状态", value: sparkle.statusMessage)
                        if let version = sparkle.latestVersion {
                            Text("最新版本 \(version) 已发布。Sparkle 会引导你安装更新。")
                                .foregroundStyle(.secondary)
                        }
                        Button(sparkle.isChecking ? "检查中…" : "检查更新", systemImage: "arrow.clockwise") {
                            model.checkForUpdates(force: true)
                        }
                        .disabled(sparkle.isChecking)
                    }

                    Section("项目") {
                        Button {
                            model.openRepository()
                        } label: {
                            HStack(spacing: 12) {
                                Image(nsImage: NSApplication.shared.applicationIconImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .antialiased(true)
                                    .scaledToFit()
                                    .frame(width: 38, height: 38)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Reset!")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("EEliberto/Reset-macOS")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 12) {
                        SettingsNavigationButtons(
                            canGoBack: !backStack.isEmpty,
                            canGoForward: !forwardStack.isEmpty,
                            goBack: goBack,
                            goForward: goForward
                        )
                        Text(selectedPane.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .title)
        .background(SettingsWindowConfigurator())
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: selectedPane) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if isHistoryNavigation {
                isHistoryNavigation = false
            } else {
                backStack.append(oldValue)
                forwardStack.removeAll()
            }
        }
    }

    private func goBack() {
        guard let destination = backStack.popLast() else { return }
        forwardStack.append(selectedPane)
        isHistoryNavigation = true
        selectedPane = destination
    }

    private func goForward() {
        guard let destination = forwardStack.popLast() else { return }
        backStack.append(selectedPane)
        isHistoryNavigation = true
        selectedPane = destination
    }
}

private struct BuildIntegrationCard: View {
    let status: BuildIntegrationStatus

    private var stateTitle: String {
        switch status.state {
        case .running: "正在执行"
        case .completed: "刚刚完成"
        case .failed: "任务失败"
        case nil: "等待活动"
        }
    }

    private var stateSymbol: String {
        switch status.state {
        case .running: "bolt.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case nil: "clock"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BuildIntegrationIcon(integration: status.integration, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.integration.title).font(.headline.weight(.semibold))
                    Text(status.integration.company).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Label(stateTitle, systemImage: stateSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.state == .failed ? .red : .secondary)
            }
            if let summary = status.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(status.observedAt.map { "最近活动：\(chineseDateTime($0))" } ?? "等待本地 Agent 活动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .quotaGlass(cornerRadius: 12)
    }
}

private struct DashboardCardsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DashboardHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BuildIntegrationLabel: View {
    let integration: BuildIntegrationKind

    var body: some View {
        HStack(spacing: 10) {
            BuildIntegrationIcon(integration: integration, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(integration.title)
                Text(integration.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderIntegrationLabel: View {
    let provider: ProviderKind

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                Text("启用额度查询、主页显示与提醒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BuildIntegrationIcon: View {
    let integration: BuildIntegrationKind
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(
                forResource: integration.iconResource,
                withExtension: "png",
                subdirectory: "AgentIcons"
            ) ?? Bundle.main.url(forResource: integration.iconResource, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit().padding(5)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

private struct SettingsNavigationButtons: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            navigationButton("chevron.left", enabled: canGoBack, action: goBack)
            Divider().frame(height: 17).opacity(0.35)
            navigationButton("chevron.right", enabled: canGoForward, action: goForward)
        }
        .frame(width: 72, height: 32)
        .glassEffect(.regular, in: Capsule())
    }

    private func navigationButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 35, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.28))
        .disabled(!enabled)
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: view.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert([.resizable, .fullSizeContentView])
        window.level = .normal
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.remove(.moveToActiveSpace)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 700, height: 480)
        window.contentMaxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }
}
