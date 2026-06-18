import SwiftUI

// MARK: - DemoModeBadge
//
// A small yellow chip that shows when Sampler.isDemoMode is on.
// It lives in the popover header and at the top of the Overview
// page so the user never confuses synthesized data for real data.

struct DemoModeBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.stars")
                .font(.caption2)
            if !compact {
                Text(L("DEMO")).font(.caption2).fontWeight(.bold)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(.orange, in: Capsule())
        .help(L("Sampler is using synthetic data, not real SMC reads."))
    }
}

// MARK: - Observable Sampler wrapper
//
// SwiftUI views need an ObservableObject to react to Sampler
// state changes. We expose isDemoMode through one of these.

final class SamplerObserver: ObservableObject {
    @Published var isDemoMode: Bool
    init() {
        // Read current state synchronously from the singleton.
        self.isDemoMode = Sampler.shared.isDemoMode
    }
}
