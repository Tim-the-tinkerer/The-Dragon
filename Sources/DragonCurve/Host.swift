import SwiftUI

public struct DragonCurveSection: View {
    @StateObject private var model = AppModel()

    public init() {}

    public var body: some View {
        ContentView()
            .environmentObject(model)
            .onAppear { DragonCurveHost.bind(model) }
    }
}

public enum DragonCurveHost {
    public static var versionLine: String { "\(DragonEngine.version) (\(DragonEngine.build))" }

    public static func command(_ args: [String]) -> Int32 {
        if let code = CurveCLI.dispatch(args) { return code }
        fputs("Dragon Curve: that starts the window. Use --help for jobs.\n\(CurveCLI.usage)\n", stderr)
        return 2
    }

    public static func selfTest() -> String? {
        CurveCLI.failureReport()
    }

    public static func open(_ urls: [URL]) {
        MainActor.assumeIsolated {
            if let bound {
                bound.addFiles(urls)
            } else {
                pending.append(contentsOf: urls)
            }
        }
    }

    public static func openNote() { act { $0.openNote() } }
    public static func encryptNote() { act { $0.encryptNote() } }
    public static func decryptNote() { act { $0.decryptNote() } }
    public static func clearNote() { act { $0.clearNote() } }
    public static func saveCiphertext() { act { $0.saveCiphertext() } }
    public static func savePlaintext() { act { $0.savePlaintext() } }
    public static func encryptFiles() { act { $0.encryptFiles() } }
    public static func decryptFiles() { act { $0.decryptFiles() } }
    public static func encryptFolders() { act { $0.encryptFolders() } }
    public static func decryptFolders() { act { $0.decryptFolders() } }

    static func bind(_ model: AppModel) {
        MainActor.assumeIsolated {
            bound = model
            guard !pending.isEmpty else { return }
            let urls = pending
            pending.removeAll()
            model.addFiles(urls)
        }
    }

    private static func act(_ body: @MainActor (AppModel) -> Void) {
        MainActor.assumeIsolated {
            guard let bound else { return }
            body(bound)
        }
    }

    @MainActor private static weak var bound: AppModel?
    @MainActor private static var pending: [URL] = []
}
