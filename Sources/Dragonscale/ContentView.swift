import SwiftUI

private struct WellFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var wellFrames: [String: CGRect] = [:]
    @State private var dropLanding: DropLanding = .window

    private static let passChoices = [0, 1, 2, 3, 4, 5, 6, 7]

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                pictureColumn
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(width: 400)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1040, minHeight: 720)
        .background(Theme.ink)
        .coordinateSpace(name: "dragonscale")
        .preferredColorScheme(.dark)
        .onFileDrop(isTargeted: $model.targeted, hover: { point in
            dropLanding = landing(at: point)
        }) { urls, point in
            model.loadDropped(urls, ontoSecond: landing(at: point) == .second)
        }
        .onPreferenceChange(WellFramesKey.self) { wellFrames = $0 }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Theme.brass, lineWidth: model.targeted && dropLanding == .window ? 3 : 0)
                .allowsHitTesting(false)
        )
        .onChange(of: model.phrase) { _ in model.refreshPicture() }
        .onChange(of: model.unit) { _ in model.refreshPicture() }
        .onChange(of: model.tile) { _ in model.refreshPicture() }
        .alert("Dragonscale", isPresented: alertShown) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .sheet(isPresented: $model.showHelp) {
            HelpSheet()
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dragonscale")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Text("Heighway dragon · the pixels change places, then you export the picture")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(model.busy ? "WORKING" : "READY")
                .font(Theme.monoTiny)
                .foregroundStyle(model.busy ? Theme.brass : Theme.dim)
            Button("How it works") { model.showHelp = true }
                .buttonStyle(.bordered)
                .tint(Theme.brass)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var pictureColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                well(
                    model.plainImage,
                    id: "first",
                    title: model.pairPictures ? "FIRST" : "PLAIN",
                    empty: model.pairPictures ? "Drop the first picture" : "No plain picture",
                    hint: model.pairPictures ? "Drop the first picture" : nil,
                    highlighted: dropLanding == .first
                )
                well(
                    model.foldedImage,
                    id: "second",
                    title: model.pairPictures ? "SECOND" : "FOLDED",
                    empty: model.pairPictures ? "Drop the second picture" : "Fold to scramble the picture",
                    hint: model.pairPictures ? "Drop the second picture" : nil,
                    highlighted: dropLanding == .second
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(model.drawing.headline)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Spacer()
                Button(action: { model.stepPass(-1) }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .tint(Theme.brass)
                .disabled(model.passCount < 2)
                Button(action: { model.stepPass(1) }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .tint(Theme.brass)
                .disabled(model.passCount < 2)
            }
            Text(model.drawing.detail)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.muted)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            ZStack(alignment: .topLeading) {
                CurveCanvas(vertices: model.drawing.vertices)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("North")
                    .font(Theme.monoTiny)
                    .foregroundStyle(Theme.dim)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.brass.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(16)
    }

    private func landing(at point: CGPoint?) -> DropLanding {
        guard let point else { return .window }
        return DropTarget.choose(
            point: point,
            pairOn: model.pairPictures,
            first: wellFrames["first"] ?? .zero,
            second: wellFrames["second"] ?? .zero,
            secondIsStandIn: model.secondIsStandIn
        )
    }

    private func well(
        _ image: NSImage?,
        id: String,
        title: String,
        empty: String,
        hint: String?,
        highlighted: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.paper
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("\(title) picture")
            } else {
                Text(empty)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(title)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.dim)
                .padding(10)
            if let hint {
                VStack {
                    Spacer()
                    Text(hint)
                        .font(Theme.monoTiny)
                        .foregroundStyle(Theme.cream)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.ink.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(highlighted ? Theme.brass : Theme.brass.opacity(0.35), lineWidth: highlighted ? 3 : 1)
        )
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: WellFramesKey.self,
                value: [id: geo.frame(in: .named("dragonscale"))]
            )
        })
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Group {
                    if model.showPhrase {
                        TextField("Phrase", text: $model.phrase, prompt: Text("Phrase. Empty is the plain curve."))
                    } else {
                        SecureField("Phrase", text: $model.phrase, prompt: Text("Phrase. Empty is the plain curve."))
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button(model.showPhrase ? "Hide" : "Show") { model.showPhrase.toggle() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
            }

            HStack {
                Text("Passes")
                    .foregroundStyle(Theme.muted)
                Spacer()
                Picker("Passes", selection: $model.passes) {
                    ForEach(Self.passChoices, id: \.self) { value in
                        Text(value == 0 ? "Automatic" : "\(value)").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .onChange(of: model.passes) { _ in
                    model.shownPass = 0
                    model.refreshPicture()
                }
            }
            .font(.callout)

            Picker("Unit", selection: $model.unit) {
                ForEach(ImageUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            Text(model.unit.detail)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if model.unit != .pixel {
                Picker(model.unit == .tile ? "Tile" : "Strip", selection: $model.tile) {
                    ForEach(tileChoices, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.unit.sizeLine(model.tile))
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.unit == .pixel {
                Toggle("Split channels", isOn: $model.splitChannels)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(Theme.cream)
                Text("Red walks the phrase. Blue walks the mirror. Green walks the plain curve. Alpha stays put.")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.unit == .tile {
                Toggle("Spin tiles", isOn: $model.spinTiles)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(Theme.cream)
                Text("Each square turns with the pen. East stays. North is 90°. West is 180°. South is 270°. A one-pixel tile does not turn.")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Pair pictures", isOn: Binding(
                get: { model.pairPictures },
                set: { model.setPair($0) }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(Theme.cream)
            Text("Two pictures share one dragon. Pixels, tiles, or strips can cross. An edge stays in its own picture.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Second…") { model.openSecondPanel() }
                .buttonStyle(.bordered)
                .tint(Theme.brass)
                .disabled(model.busy)

            Text(model.layoutLine)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Write the fold note", isOn: $model.includeNote)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.cream)
            Text("The note is a small chunk in the PNG. Other programs ignore it. The phrase is not in the file.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Treat as folded", isOn: $model.treatAsFolded)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.cream)
            Text("For a PNG that was folded with the note turned off. Restore then uses the settings above.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Fold") { model.fold() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brassDeep)
                    .disabled(!model.canFold)
                Button("Restore") { model.restore() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(!model.canRestore)
                Button("Export PNG") { model.exportFolded() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(!model.canExportFolded)
            }
            HStack(spacing: 8) {
                Button("Open…") { model.openPanel() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(model.busy)
                Button("Save Plain…") { model.savePlain() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(!model.canSavePlain)
                Button("Card") { model.useCard() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(model.busy)
            }

            Text(model.fileLine)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.cream)
                .textSelection(.enabled)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text(model.pairPictures
                ? "Drop the second picture on the right. While the night card is there, a drop outside the left well replaces it."
                : "Drop an image anywhere. The original file is left alone.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
        }
        .padding(16)
        .background(Theme.ink)
    }

    private var tileChoices: [Int] {
        var values = ImageFold.tiles
        if !values.contains(model.tile) {
            values.append(model.tile)
            values.sort()
        }
        return values
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How the fold works")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.cream)
            ScrollView {
            Text("""
            The Heighway dragon is a strip of paper folded in half, over and over, always the same way, then opened so each fold is a right angle. Dragonscale lays the picture on that path. The file you export is those same pixels, read back in page order.

            Nothing is added and nothing is removed. The scramble is the picture. Restore, with the same phrase, puts every pixel back.

            Tile keeps a square scrap of the picture together, so you can still see pieces of it. Pixel lets every pixel take its own step, which looks closer to static. Rows cut the picture into horizontal ribbons, and Columns into vertical ribbons. A ribbon runs the whole length, so a face becomes strips along the dragon.

            Spin tiles is optional, and it starts off. Turn it on and each square turns with that step of the curve. East stays upright. North turns 90°. West turns 180°. South turns 270°. Another pass turns the square again. Pixel and ribbons do not turn.

            Split channels is optional, and it starts off. It is a pixel fold. Red walks the phrase. Blue walks the same passes with the fold turned the other way. Green walks the plain curve. Alpha stays on its pixel. A photo becomes a colored ghost of the curve. Restore puts each channel back.

            Pair pictures is optional, and it starts off. Two pictures share one dragon. Drop the second picture on the right well. While the night card is still there, a drop anywhere but the left well replaces that card. Drop the first picture on the left well. You can also drop the two files together. The pieces of the first are laid down, then the pieces of the second, and the curve mixes that line. Pixels, tiles, or strips can cross. A scrap that does not fill a segment stays in its own picture. Restore uses the same phrase and puts both pictures back. The export is one PNG, the first picture on top and the second below.

            The edge that does not fill a tile or a ribbon stays where it is. That is how the fold can be undone.

            Automatic uses one pass when the phrase is empty, and 4 to 7 passes when there is a phrase. A number uses that many passes. The phrase is case sensitive, and it is never written into the file.

            The fold note inside the PNG tells Dragonscale the unit, the tile, the pass count, whether the tiles turned, whether the channels split, and whether two pictures were mixed. Other programs ignore it. Turn the note off and the PNG is an ordinary picture. Turn on Treat as folded to restore that file with the settings above.

            This only rearranges the picture. It is not a lock.
            """)
            .font(.body)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brassDeep)
            }
        }
        .padding(24)
        .frame(width: 560, height: 640)
        .background(Theme.ink)
    }
}
