import AVKit
import SwiftUI

struct MoviePane: NSViewRepresentable {
    var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared

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
        .preferredColorScheme(.dark)
        .onFileDrop(isTargeted: $model.targeted) { urls in
            if let url = urls.first { model.load(url) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Theme.brass, lineWidth: model.targeted ? 3 : 0)
                .allowsHitTesting(false)
        )
        .onChange(of: model.phrase) { _ in model.refreshPicture() }
        .onChange(of: model.axis) { _ in model.refreshPicture() }
        .onChange(of: model.tile) { _ in model.refreshPicture() }
        .onChange(of: model.run) { _ in model.refreshPicture() }
        .alert("Dragonreel", isPresented: alertShown) {
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
                Text("Dragonreel")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Text("Heighway dragon · tiles on every frame, runs of frames, or both")
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
            ZStack {
                Theme.paper
                if let player = model.player {
                    MoviePane(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(8)
                } else if let still = model.still {
                    Image(nsImage: still)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else {
                    Text("Drop a movie")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.brass.opacity(0.35), lineWidth: 1)
            )

            if model.hasPlain && model.hasFolded {
                Picker("Show", selection: Binding(
                    get: { model.showingFolded },
                    set: { model.show($0) }
                )) {
                    Text("Plain").tag(false)
                    Text("Folded").tag(true)
                }
                .pickerStyle(.segmented)
            }

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
            .frame(height: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.brass.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(16)
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

            Picker("Axis", selection: $model.axis) {
                ForEach(ReelAxis.allCases) { axis in
                    Text(axis.title).tag(axis)
                }
            }
            .pickerStyle(.segmented)
            Text(model.axis.detail)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if model.axis.usesTiles {
                Picker("Tile", selection: $model.tile) {
                    ForEach(tileChoices, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text("\(model.tile) pixels on a side. The same rearrangement on every frame. An edge that does not fill a tile stays put.")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.axis.usesRuns {
                Picker("Run", selection: $model.run) {
                    ForEach(runChoices, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.run == 1
                    ? "One frame at a time. The picture flickers."
                    : "\(model.run) frames move together. Motion inside the run stays in order. A short tail stays at the end.")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(model.layoutLine)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Write the fold note", isOn: $model.includeNote)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.cream)
            Text("The note is the movie's description. Players still play it. The phrase is not in the file.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Treat as folded", isOn: $model.treatAsFolded)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.cream)
            Text("For a movie that was folded with the note turned off. Restore then uses the settings above.")
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
                Button("Export Movie") { model.exportFolded() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(!model.canExportFolded)
            }
            Picker("Length", selection: $model.span) {
                ForEach(ReelSpan.allCases) { span in
                    Text(span.title).tag(span)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.span) { _ in model.spanChanged() }
            Text(model.span.detail)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Open…") { model.openPanel() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(model.busy)
                Button("Save Plain…") { model.savePlain() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(!model.canSavePlain)
                Button("Reel") { model.useReel() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                    .disabled(model.busy)
            }

            Text("This version fits each frame inside 1920×1080.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("Drop a movie anywhere. Space plays. The original file is left alone.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
        }
        .padding(16)
        .background(Theme.ink)
    }

    private var tileChoices: [Int] {
        var values = ReelFold.tiles
        if !values.contains(model.tile) {
            values.append(model.tile)
            values.sort()
        }
        return values
    }

    private var runChoices: [Int] {
        var values = ReelFold.runs
        if !values.contains(model.run) {
            values.append(model.run)
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
            Text("""
            The Heighway dragon is a strip of paper folded in half, over and over, always the same way, then opened so each fold is a right angle. Dragonfold lays sound on that path. Dragonscale lays a picture on it. Dragonreel lays a movie on it.

            Scale uses one tile rearrangement for every frame. The picture stays scrambled. Because each tile keeps coming from the same place, the motion inside it stays continuous.

            Fold moves short runs of frames, the way Dragonfold moves grains of audio. A longer run keeps the motion inside that piece, and the sound inside it. One frame at a time flickers.

            Both does the two rearrangements together. The tiles and the sound move inside each frame, and the runs carry their sound through time.

            A strip that does not fill a tile stays where it is. Frames left over at the end of a run stay at the end. Samples left over at the end of the sound stay at the end. That is how the fold can be undone.

            Automatic uses one pass when the phrase is empty, and 4 to 7 passes when there is a phrase. A number uses that many passes. The phrase is case sensitive, and it is never written into the file.

            The sound is cut into one slice per frame. Scale cuts that slice into the same pieces as the tiles, and uses that rearrangement on every frame. A larger tile keeps a longer piece of sound together. When a frame has fewer samples than tiles, each sample moves. Fold moves the whole slice with the frame. Both does the two.

            This version fits each frame inside 1920×1080. Preview keeps the first 20 seconds, or 600 frames, and stops sooner when the frame cache is full. Full movie keeps the whole file when the temporary files for the loaded frames, the folded frames, and the sound will fit. A smaller picture runs longer. The movie you export is H.264, and the sound is AAC, so a player can play it. Restore puts the loaded frames and the loaded samples back. The codec's own change stays.

            This only rearranges the movie. It is not a lock.
            """)
            .font(.body)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brassDeep)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Theme.ink)
    }
}
