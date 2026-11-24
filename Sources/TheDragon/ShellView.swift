import DragonCurve
import Dragonfold
import Dragonreel
import Dragonscale
import SwiftUI

struct ShellView: View {
    @ObservedObject private var shell = ShellState.shared

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(ShellTheme.brass.opacity(0.35))
                .frame(width: 1)
            ZStack {
                if shell.mounted.contains(.curve) {
                    placed(DragonCurveSection(), wing: .curve)
                }
                if shell.mounted.contains(.scale) {
                    placed(DragonscaleSection(), wing: .scale)
                }
                if shell.mounted.contains(.fold) {
                    placed(DragonfoldSection(), wing: .fold)
                }
                if shell.mounted.contains(.reel) {
                    placed(DragonreelSection(), wing: .reel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1240, minHeight: 780)
        .background(ShellTheme.ink)
        .preferredColorScheme(.dark)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The Dragon")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(ShellTheme.cream)
                Text("Four folds")
                    .font(.caption)
                    .foregroundStyle(ShellTheme.muted)
            }
            VStack(spacing: 6) {
                ForEach(Wing.allCases) { wing in
                    sectionButton(wing)
                }
            }
            Spacer(minLength: 0)
            Text("A fold, not a lock.")
                .font(.caption)
                .foregroundStyle(ShellTheme.dim)
            Text(AppInfo.version)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(ShellTheme.dim)
        }
        .padding(16)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(ShellTheme.lift)
    }

    private func sectionButton(_ wing: Wing) -> some View {
        let on = shell.section == wing
        return Button {
            shell.show(wing)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(wing.title)
                    .font(.system(size: 16, weight: on ? .semibold : .regular, design: .serif))
                    .foregroundStyle(on ? ShellTheme.cream : ShellTheme.muted)
                Text(wing.detail)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(on ? ShellTheme.brass : ShellTheme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? ShellTheme.paper : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ShellTheme.brass.opacity(on ? 0.85 : 0), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func placed<Content: View>(_ content: Content, wing: Wing) -> some View {
        let on = shell.section == wing
        return content
            .opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .disabled(!on)
            .zIndex(on ? 1 : 0)
    }
}
