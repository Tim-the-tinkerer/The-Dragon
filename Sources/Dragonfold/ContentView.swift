import SwiftUI

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared

    private static let passChoices = [0, 1, 2, 3, 4, 5, 6, 7]

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                curveColumn
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(width: 420)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
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
        .onChange(of: model.unit) { _ in model.refreshPicture() }
        .onChange(of: model.grain) { _ in model.refreshPicture() }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            model.tick()
        }
        .alert("Dragonfold", isPresented: alertShown) {
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
                Text("Dragonfold")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Text("Heighway dragon · the samples change places, then the WAV plays")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(model.isPlaying ? "PLAYING" : (model.busy ? "WORKING" : "READY"))
                .font(Theme.monoTiny)
                .foregroundStyle(model.isPlaying ? Theme.brass : Theme.dim)
            Button("How it works") { model.showHelp = true }
                .buttonStyle(.bordered)
                .tint(Theme.brass)
            playButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var playButton: some View {
        Button(action: { model.togglePlay() }) {
            ZStack {
                Circle()
                    .fill(model.isPlaying ? Theme.brass : Theme.brass.opacity(0.16))
                    .frame(width: 46, height: 46)
                Circle()
                    .stroke(Theme.brass, lineWidth: 1.4)
                    .frame(width: 46, height: 46)
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(model.isPlaying ? Theme.ink : Theme.brass)
                    .offset(x: model.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(model.isPlaying ? "Stop" : "Play")
        .accessibilityLabel(model.isPlaying ? "Stop" : "Play")
    }

    private var curveColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                CurveCanvas(vertices: model.drawing.vertices)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("North")
                    .font(Theme.monoTiny)
                    .foregroundStyle(Theme.dim)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.brass.opacity(0.35), lineWidth: 1)
            )

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
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.waveIsFolded ? "FOLDED" : "PLAIN")
                    .font(Theme.monoTiny)
                    .foregroundStyle(Theme.dim)
                WaveCanvas(wave: model.wave, playhead: model.isPlaying ? model.playhead : 0, folded: model.waveIsFolded)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.brass.opacity(0.28), lineWidth: 1)
                    )
            }
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
                .frame(width: 160)
                .onChange(of: model.passes) { _ in
                    model.shownPass = 0
                    model.refreshPicture()
                }
            }
            .font(.callout)

            Picker("Unit", selection: $model.unit) {
                ForEach(AudioUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            Text(model.unit.detail)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if model.unit == .grain {
                Picker("Grain", selection: $model.grain) {
                    ForEach(grainChoices, id: \.self) { value in
                        Text(grainLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(grainCaption)
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Reverse right turns", isOn: $model.reverseRight)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(Theme.cream)
                Text("A grain plays backward when that step of the curve turns right. A left turn plays forward.")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(layoutLine)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Hear", selection: hearBinding) {
                Text("Plain").tag(false)
                Text("Folded").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!model.hasPlain || !model.hasFolded)

            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(Theme.dim)
                Slider(value: volumeBinding, in: 0...1)
                    .tint(Theme.brass)
            }
            Text("Volume is playback only. The exported file is full level.")
                .font(.caption)
                .foregroundStyle(Theme.dim)

            Toggle("Write the fold note", isOn: $model.includeNote)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.cream)
            Text("The note is a small chunk after the audio. Players ignore it. The phrase is not in the file.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Treat as folded", isOn: $model.treatAsFolded)
                .toggleStyle(.checkbox)
                .foregroundStyle(Theme.cream)
            Text("For a WAV that was folded with the note turned off. Restore then uses the settings above.")
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
                Button("Export WAV") { model.exportFolded() }
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
                Button("Tone") { model.useTone() }
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
            Text("Drop audio anywhere. The original file is left alone.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
        }
        .padding(16)
        .background(Theme.ink)
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.volume },
            set: { model.setVolume($0) }
        )
    }

    private var hearBinding: Binding<Bool> {
        Binding(
            get: { model.hearFolded },
            set: { model.hear($0) }
        )
    }

    private var grainChoices: [Int] {
        var values = AudioFold.grains
        if !values.contains(model.grain) {
            values.append(model.grain)
            values.sort()
        }
        return values
    }

    private var grainCaption: String {
        let rate = 44_100.0
        let ms = Double(model.grain) / rate * 1000
        return "\(model.grain) frames. About \(Int(ms.rounded())) ms at 44.1 kHz."
    }

    private var layoutLine: String {
        if let limit = model.limitText { return limit }
        let place = model.unit == .sample && model.channelCount > 1 ? "on each channel" : "on the curve"
        var line = "\(model.segmentCount) segment\(model.segmentCount == 1 ? "" : "s") \(place)."
        if model.passCount > 0 {
            line += " \(model.passCount) pass\(model.passCount == 1 ? "" : "es")."
        }
        if model.tailFrames > 0 {
            line += " Last \(model.tailFrames) frames stay put."
        }
        return line
    }
}

private extension ContentView {
    func grainLabel(_ value: Int) -> String {
        if value >= 1024, value % 1024 == 0 { return "\(value / 1024)k" }
        return "\(value)"
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
            The Heighway dragon is a strip of paper folded in half, over and over, always the same way, then opened so each fold is a right angle. Dragonfold lays the audio on that path. The file you export is those same samples, read back in page order.

            Nothing is added and nothing is removed. A player plays the scramble. Restore, with the same phrase, puts every sample back.

            Grain keeps a short piece of the recording together, so you can still hear scraps of it. Frame keeps both channels of one moment together. Sample gives each channel its own dragon. The left channel walks the phrase. The right channel walks the mirror, so a left sample stays on the left. A full song fits. It can take about a minute.

            Reverse right turns is optional, and it starts off. Turn it on and a grain on a right-hand corner plays backward. A left-hand corner plays forward. Nothing is added or removed. Restore, with the same phrase, puts every grain back.

            Automatic uses one pass when the phrase is empty, and 4 to 7 passes when there is a phrase. A number uses that many passes. The phrase is case sensitive, and it is never written into the file.

            The fold note at the end of the WAV tells Dragonfold the unit, the grain, the pass count, whether right turns play backward, and whether each channel has its own dragon. Other players skip it. Turn the note off and the WAV is ordinary PCM. Turn on Treat as folded to restore that file with the settings above.

            This only rearranges the recording. It is not a lock.
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
        .frame(width: 520)
        .background(Theme.ink)
    }
}
