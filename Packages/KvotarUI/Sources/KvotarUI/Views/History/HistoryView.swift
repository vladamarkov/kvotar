import SwiftUI
import KvotarCore

/// The History window (STEP_109; three-view experience STEP_160 — REV-84 / D-108; four modes
/// STEP_182 — REV-93 / D-115): the last 30 days of the local corpus and of what the providers
/// themselves reported, as four switchable views — `Weekly recap | Explore quota | Explore usage
/// | Hard blocks`. Reads only from `HistoryViewModel` (PATTERNS.md — views hold no business
/// logic); every string arrives pre-formatted in `HistoryExperience`, and the only arithmetic
/// here is a bar's width from a supplied 0…1 fraction. Calendar time, never plan windows — see
/// `HistoryReport`.
///
/// Variant A keeps stable window chrome above a mode-specific page heading. Provider controls
/// live beside that evidence heading, never in the titlebar and never on Weekly recap.
public struct HistoryView: View {
    @ObservedObject private var vm: HistoryViewModel
    private let initialExploreGrain: ExploreModeView.Grain?

    private let topAnchor = "history-top"

    public init(viewModel: HistoryViewModel) {
        self.vm = viewModel
        self.initialExploreGrain = nil
    }

    /// Deterministic visual-evidence entry point. Production always uses the public initializer;
    /// the snapshot harness can start on a non-default usage grain without UI scripting.
    init(viewModel: HistoryViewModel, initialExploreGrain: ExploreModeView.Grain?) {
        self.vm = viewModel
        self.initialExploreGrain = initialExploreGrain
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
            Divider().overlay(HistoryTheme.line)
            if let experience = vm.experience {
                if let message = experience.emptyMessage {
                    // The whole-report empty state keeps the controls above it (§6.0).
                    Spacer()
                    Text(message)
                        .font(HistoryTheme.body)
                        .foregroundStyle(HistoryTheme.tertiary)
                        .padding(16)
                    Spacer()
                } else {
                    content(experience)
                        .frame(minHeight: 0)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(-1)
                }
                Divider().overlay(HistoryTheme.line)
                Text(experience.footer)
                    .font(HistoryTheme.note)
                    .foregroundStyle(HistoryTheme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(HistoryTheme.window)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
            } else {
                // First open before the first report lands — never a spinner over an empty page
                // for long: the reader is a handful of indexed queries.
                Spacer()
                Text(vm.isLoading ? "Reading local records…" : "No local records yet.")
                    .font(HistoryTheme.body)
                    .foregroundStyle(HistoryTheme.tertiary)
                Spacer()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(HistoryTheme.page)
        // One overlay at the root, as the popover mounts exactly one `ExplanationCardOverlay`:
        // the day card is drawn against the whole window so it can flip above near the bottom.
        .overlayPreferenceValue(DayHoverAnchorKey.self) { anchors in
            DayHoverOverlay(anchors: anchors, vm: vm)
        }
        .onExitCommand { vm.releaseDayPeek() }
    }

    private func content(_ experience: HistoryExperience) -> some View {
        let pages = experience.pages(vm.provider)
        return ScrollViewReader { proxy in
            GeometryReader { geometry in
                let narrow = geometry.size.width <= 700
                let evidencePadding: CGFloat = narrow ? 18 : 28
                ScrollView {
                    Group {
                        if vm.mode == .weeklyRecap {
                            WeeklyRecapModeView(section: experience.recap, vm: vm)
                                .padding(.horizontal, narrow ? 18 : 30)
                                .padding(.top, narrow ? 28 : 42)
                                .padding(.bottom, narrow ? 48 : 58)
                        } else {
                            evidencePage(experience, pages: pages, narrow: narrow)
                                .frame(width: min(960, geometry.size.width
                                                  - evidencePadding * 2),
                                       alignment: .leading)
                                .padding(.horizontal, evidencePadding)
                                .padding(.top, narrow ? 24 : 30)
                                .padding(.bottom, narrow ? 48 : 54)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .id(topAnchor)
                }
                // A mode or provider is a different page, and a reader who scrolled to the
                // bottom of one has no reason to land halfway down the next (REV-84 §2).
                .onChange(of: vm.mode) { _, _ in
                    vm.releaseDayPeek()
                    proxy.scrollTo(topAnchor, anchor: .top)
                }
                .onChange(of: vm.provider) { _, _ in
                    vm.releaseDayPeek()
                    proxy.scrollTo(topAnchor, anchor: .top)
                }
            }
        }
    }

    private func evidencePage(_ experience: HistoryExperience,
                              pages: HistoryExperience.ProviderPages,
                              narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            evidenceHeading(experience)
                .padding(.bottom, 22)
            if let scope = vm.scope {
                ScopeBannerView(scope: scope, vm: vm)
                    .padding(.top, -2)
                    .padding(.bottom, 18)
            }
            switch vm.mode {
            case .weeklyRecap:
                EmptyView()
            case .exploreQuota:
                ExploreQuotaModeView(page: pages.quota,
                                     periodLabel: experience.header.subtitle, vm: vm)
            case .exploreUsage:
                ExploreModeView(page: pages.explore,
                                pricingNote: experience.pricingNote, vm: vm,
                                initialGrain: initialExploreGrain ?? .day)
            case .hardBlocks:
                HardBlocksModeView(page: pages.hardBlocks, vm: vm, isNarrow: narrow)
            }
        }
    }

    private func evidenceHeading(_ experience: HistoryExperience) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                evidenceTitle(experience)
                    .frame(width: 520, alignment: .leading)
                Spacer(minLength: 12)
                providerPicker
            }
            VStack(alignment: .leading, spacing: 14) {
                evidenceTitle(experience)
                providerPicker
            }
        }
    }

    private func evidenceTitle(_ experience: HistoryExperience) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HistoryEyebrow(text: experience.header.evidenceEyebrow)
            Text(vm.mode.label)
                .font(HistoryTheme.modeTitle)
                .tracking(-0.65)
                .foregroundStyle(HistoryTheme.text)
            if let subtitle = vm.mode.evidenceSubtitle {
                Text(subtitle)
                    .font(Font.system(size: 13))
                    .foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                titleBlock
                Spacer(minLength: 8)
                if vm.isLoading { ProgressView().controlSize(.small) }
            }
            .frame(minHeight: 55)
            .padding(.horizontal, 26)
            .padding(.top, 15)
            .padding(.bottom, 12)
            Divider().overlay(HistoryTheme.line)
            ViewThatFits(in: .horizontal) {
                modeTabBar(spacing: 34)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 26)
                ScrollView(.horizontal, showsIndicators: false) {
                    modeTabBar(spacing: 22)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HistoryTheme.surface)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(vm.experience?.header.title ?? "History")
                .font(HistoryTheme.title)
                .tracking(-0.55)
                .foregroundStyle(HistoryTheme.text)
            Text(vm.mode.windowSubtitle)
                .font(Font.system(size: 13))
                .foregroundStyle(HistoryTheme.secondary)
        }
    }

    @ViewBuilder private var providerPicker: some View {
        if let experience = vm.experience {
            // Bound through the view model's computed accessor rather than a `@Published`
            // projection: the provider is **per mode** since STEP_183, so there is one stored
            // value per mode and one binding onto whichever mode is showing.
            Picker("", selection: Binding(get: { vm.provider },
                                          set: { vm.provider = $0 })) {
                ForEach(experience.providers, id: \.self) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Provider")
        }
    }

    /// The underline mode tabs (`Weekly recap | Explore quota | Explore usage | Hard blocks`) —
    /// the prototype's
    /// `.kh-tabs` row, drawn by the shared `UnderlineTabBar` that Explore's dimension control
    /// also uses (STEP_163). No baseline of its own: the header's divider is already under it.
    @ViewBuilder private func modeTabBar(spacing: CGFloat) -> some View {
        if vm.experience != nil {
            UnderlineTabBar(items: HistoryExperience.Mode.allCases,
                            label: \.label,
                            selection: $vm.mode,
                            spacing: spacing)
                .accessibilityLabel("History view")
        }
    }
}

/// `From weekly recap · Claude · Sep 1 – Sep 7`, with the two ways out of it (§6.2). The banner
/// says where the reader came from; the mode below it still shows its full 30 days, and the scope
/// moves attention — a selected point, a selected day, a highlighted row — rather than silently
/// re-basing a figure the copy describes as thirty days.
struct ScopeBannerView: View {
    let scope: HistoryViewModel.Scope
    @ObservedObject var vm: HistoryViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(scope.banner)
                .font(HistoryTheme.small)
                .foregroundStyle(HistoryTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Back to weekly recap") { vm.backToWeeklyRecap() }
                .buttonStyle(.plain)
                .font(HistoryTheme.small)
                .foregroundStyle(HistoryTheme.claudeAccent)
            Button {
                vm.clearScope()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HistoryTheme.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear scope")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HistoryTheme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(HistoryTheme.line, lineWidth: 1)
        }
    }
}
