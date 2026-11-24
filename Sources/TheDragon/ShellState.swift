import DragonCurve
import Dragonfold
import Dragonreel
import Dragonscale
import SwiftUI

final class ShellState: ObservableObject {
    static let shared = ShellState()

    @Published private(set) var section: Wing = .curve
    @Published private(set) var mounted: Set<Wing> = [.curve]

    func show(_ wing: Wing) {
        guard wing != section else { return }
        switch section {
        case .fold:
            DragonfoldHost.stop()
        case .reel:
            DragonreelHost.pause()
        case .curve, .scale:
            break
        }
        if !mounted.contains(wing) {
            var next = mounted
            next.insert(wing)
            mounted = next
        }
        section = wing
        AppDelegate.shared.sectionChanged()
    }

    func open(_ url: URL) {
        let wing = Wing.forURL(url)
        show(wing)
        switch wing {
        case .curve:
            DragonCurveHost.open([url])
        case .scale:
            DragonscaleHost.open(url)
        case .fold:
            DragonfoldHost.open(url)
        case .reel:
            DragonreelHost.open(url)
        }
    }
}
