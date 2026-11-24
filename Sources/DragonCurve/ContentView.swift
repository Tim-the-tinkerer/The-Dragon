import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    /// Automatic and 1...7 in one list. A separate Automatic row plus
    /// ForEach(1...7) makes the macOS menu leave the choice at 6.
    private static let passChoices = [0, 1, 2, 3, 4, 5, 6, 7]

    private var picture: DragonEngine.CurvePicture {
        model.picture
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                curveColumn
                    .frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                noteColumn
                    .frame(width: 460)
                    .frame(maxHeight: .infinity)
            }
            Divider().overlay(Theme.brass.opacity(0.25))
            fileBar
        }
        .frame(minWidth: 980, minHeight: 760)
        .background(Theme.ink)
        .onFileDrop(isTargeted: $model.targeted) { model.addFiles($0) }
        .alert("Dragon Curve", isPresented: alertShown) {
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
                Text("Dragon Curve")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Text("Heighway dragon · paperfolding transposition")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(DragonEngine.version)
                .font(Theme.monoTiny)
                .foregroundStyle(Theme.dim)
            Button("How it works") { model.showHelp = true }
                .buttonStyle(.bordered)
                .tint(Theme.brass)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var curveColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                CurveCanvas(picture: picture)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if picture.path.isEmpty && picture.marks.isEmpty {
                    Text(picture.summary.contains("too long") ? "Too long to draw." : "Nothing on the curve.")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                }
                VStack {
                    HStack {
                        Spacer()
                        Text("North")
                            .font(Theme.monoTiny)
                            .foregroundStyle(Theme.dim)
                            .padding(8)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.brass.opacity(0.35), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summaryHeadline.isEmpty ? " " : summaryHeadline)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.cream)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if model.passTotal > 1 {
                        Menu {
                            Picker("Map pass", selection: $model.mapPass) {
                                ForEach(1...model.passTotal, id: \.self) { number in
                                    Text("Pass \(number)").tag(number)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text("Map pass \(model.shownMapPass)")
                        }
                        .fixedSize()
                    }
                }
                if !summaryDetail.isEmpty {
                    ScrollView {
                        Text(summaryDetail)
                            .font(Theme.monoTiny)
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(height: 168)
                    .scrollIndicators(.visible)
                }
            }
        }
        .padding(16)
    }

    private var summaryHeadline: String {
        let summary = picture.summary
        guard let split = summary.firstIndex(of: "\n") else { return summary }
        return String(summary[..<split])
    }

    private var summaryDetail: String {
        let summary = picture.summary
        guard let split = summary.firstIndex(of: "\n") else { return "" }
        return String(summary[summary.index(after: split)...])
    }

    private var noteColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            keyRow
            Toggle("Character header", isOn: $model.header)
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(Theme.cream)
                .disabled(model.busy)
                .onChange(of: model.header) { _ in model.markStale() }

            Text("Off, the note is the characters alone, the same as the script. On, a DATA/3 character header records the pass count. The phrase is not stored. Old TEXT/1 and TEXT/2 notes need an earlier release.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            fieldLabel("Plaintext")
            InkTextView(text: $model.plaintext, onEdit: model.markStale)
                .frame(minHeight: 90, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                fieldLabel("Ciphertext")
                Spacer()
                if model.stale {
                    Text("Encrypt again")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            InkTextView(text: $model.ciphertext)
                .frame(minHeight: 90, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button("Encrypt") { model.encryptNote() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brassDeep)
                Button("Decrypt") { model.decryptNote() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                Button("Clear") { model.clearNote() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
                Spacer()
            }
            .disabled(model.busy)

            Text(model.status)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(Theme.ink)
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            Group {
                if model.showKey {
                    TextField("Phrase", text: keyBinding, prompt: Text("Phrase. Empty is the plain curve."))
                } else {
                    SecureField("Phrase", text: keyBinding, prompt: Text("Phrase. Empty is the plain curve."))
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundStyle(Theme.cream)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.lift)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.brass.opacity(0.35), lineWidth: 1)
            )
            Button(model.showKey ? "Hide" : "Show") {
                model.showKey.toggle()
            }
            .buttonStyle(.bordered)
            .tint(Theme.brass)
        }
    }

    private var keyBinding: Binding<String> {
        Binding(
            get: { model.key },
            set: {
                model.key = $0
                model.markStale()
            }
        )
    }

    private var fileBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("File")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Picker("Unit", selection: $model.unit) {
                    ForEach(DragonEngine.Unit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                Menu {
                    Picker("Passes", selection: $model.passCount) {
                        ForEach(Self.passChoices, id: \.self) { count in
                            Text(count == 0 ? "Automatic" : "\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.passCount == 0 ? "Passes: Automatic" : "Passes: \(model.passCount)")
                        .frame(minWidth: 148, alignment: .leading)
                }
                .fixedSize()
                .onChange(of: model.passCount) { _ in model.markStale() }
                Toggle("Header", isOn: $model.fileHeader)
                    .toggleStyle(.checkbox)
                Toggle("Scramble name", isOn: $model.scrambleName)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Encrypt File") { model.encryptFiles() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brassDeep)
                Button("Decrypt File") { model.decryptFiles() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
            }
            .disabled(model.busy)

            HStack(spacing: 12) {
                Text("Folder")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.cream)
                Picker("Folder unit", selection: $model.folderUnit) {
                    Text("Byte").tag(DragonEngine.Unit.byte)
                    Text("Hex digit").tag(DragonEngine.Unit.hex)
                    Text("Bit").tag(DragonEngine.Unit.bit)
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                Picker("ZIP", selection: $model.compression) {
                    ForEach(DragonFolder.Compression.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                Toggle("Cross-chunk weave", isOn: $model.crossWeave)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Encrypt Folder") { model.encryptFolders() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brassDeep)
                Button("Decrypt Folder") { model.decryptFolders() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brass)
            }
            .disabled(model.busy)

            Text(model.unit.detail + " Automatic follows the phrase. A number, including 7, is used as written. A header already on a file overrides both. Scramble name writes dc-….dragon and restores the original name on decrypt. A folder is zipped, then folded in chunks. Weave mixes distant chunks and writes folder format 2.")
                .font(.caption)
                .foregroundStyle(Theme.dim)

            if model.files.isEmpty && model.folders.isEmpty {
                Text(model.targeted ? "Release to add it." : "Drop a file or a folder anywhere on the window. The original is kept.")
                    .font(.callout)
                    .foregroundStyle(model.targeted ? Theme.brass : Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                model.targeted ? Theme.brass : Theme.dim.opacity(0.6),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    )
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.folders, id: \.path) { url in
                        HStack {
                            Text(url.lastPathComponent)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.cream)
                                .lineLimit(1)
                            Text("folder")
                                .font(Theme.monoTiny)
                                .foregroundStyle(Theme.dim)
                            Spacer()
                            Button("Remove") { model.removeFolder(url) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    ForEach(model.files, id: \.path) { url in
                        HStack {
                            Text(url.lastPathComponent)
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.cream)
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") { model.removeFile(url) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }

            Text("This rearranges a message. A folder package can tell a wrong phrase from a damaged file, and still does not hide the bytes from someone who can try the phrase. It is not a substitute for FileVault.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Theme.lift.opacity(model.targeted ? 1 : 0.65))
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.muted)
    }
}

private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How the curve encrypts")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text(help)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var help: String {
        """
        The Heighway dragon is the curve you get by folding a strip of paper in half, always the same way, then opening each fold to a right angle. The note is laid on that path, one character on each segment. The ciphertext is those characters read from the top of the page downward, and from left to right along a row.

        A phrase picks 4 to 7 passes. Each pass has its own fold, starting direction, starting segment, and one of eight ways to read the page. Decrypting undoes the passes, last first. The phrase is never stored. Map pass draws the note as it enters that pass.

        Passes can be Automatic or a number from 1 to 7. Automatic lets the phrase choose. Choosing 7 uses seven passes. Character header writes a DATA/3 character line so the count is stored. Without it, the note is only the rearranged characters.

        TEXT/1 and TEXT/2 notes are retired. An earlier release can still open them.

        Character, hex digit, byte, and bit modes reorder those units and leave their values alone. Scramble name hides the file name in the header and writes a dc- name. Decrypt puts the original name back when that name is free.

        A folder is packed as a ZIP, Deflate or Store, then rearranged in chunks. Cross-chunk weave mixes distant chunks first and writes folder format 2. Format 1 is the same package without the weave. The package stores a checksum of the zip, so a wrong phrase or a changed byte is reported. That checksum is not a seal against someone who can rewrite the file.

        The same note and the same phrase always give the same result. This is a rearrangement, the same kind of obfuscation as ROT13. Originals are never replaced.
        """
    }
}
