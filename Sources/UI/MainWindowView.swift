import SwiftUI

// MARK: - MainWindowView
//
// The dashboard window. Six sections selected via a custom top tab bar:
//
//   Overview — at-a-glance summary cards + 24h sparkline + 7d bars
//   Live     — 24h raw samples in detail
//   History  — full date range with range picker, aggregation, export
//   Heatmap  — GitHub-style calendar of daily peaks
//   Compare  — baseline vs recent at the most-degraded P-State
//   Settings — sampler config
//
// We deliberately avoid SwiftUI's default `TabView` here: on macOS it is
// backed by NSTabView, whose tab strip and its background are drawn by the
// system and frequently misalign with the window chrome (especially when
// `.tabItem` carries an icon). A self-drawn segmented bar keeps the buttons
// and their background in one container, so alignment is exact and the look
// is fully under our control. Overview is the default — it's the first thing
// most users want to see.

struct MainWindowView: View {
    @State private var selection: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case overview, live, history, heatmap, compare, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return L("Overview")
            case .live:     return L("Live")
            case .history:  return L("History")
            case .heatmap:  return L("Heatmap")
            case .compare:  return L("Compare")
            case .settings: return L("Settings")
            }
        }

        var icon: String {
            switch self {
            case .overview: return "rectangle.grid.2x2"
            case .live:     return "waveform.path.ecg"
            case .history:  return "clock.arrow.circlepath"
            case .heatmap:  return "square.grid.3x3"
            case .compare:  return "rectangle.split.2x1"
            case .settings: return "gear"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 580)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                TabBarButton(
                    tab: tab,
                    isSelected: selection == tab
                ) {
                    selection = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .overview: OverviewView()
        case .live:     ChartsView(mode: .live)
        case .history:  ChartsView(mode: .history)
        case .heatmap:  HeatmapView()
        case .compare:  ChartsView(mode: .compare)
        case .settings: ConfigView()
        }
    }
}

// MARK: - TabBarButton
//
// A single segmented-style tab button: icon + label, with a soft accent
// pill behind the selected item. Uses `.plain` button style so we own the
// entire appearance (the default macOS button chrome would reintroduce the
// alignment/background mismatch we're trying to eliminate).

private struct TabBarButton: View {
    let tab: MainWindowView.Tab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .imageScale(.medium)
                Text(tab.title)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .font(.callout)
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.title)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if isSelected {
            shape.fill(Color.accentColor.opacity(0.15))
        } else if hovering {
            shape.fill(Color.primary.opacity(0.07))
        } else {
            shape.fill(Color.clear)
        }
    }
}
