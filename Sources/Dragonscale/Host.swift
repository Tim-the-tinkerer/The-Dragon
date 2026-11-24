import SwiftUI

public struct DragonscaleSection: View {
    public init() {}

    public var body: some View {
        ContentView()
    }
}

public enum DragonscaleHost {
    public static var versionLine: String { "\(AppInfo.version) (\(AppInfo.build))" }

    public static func command(_ args: [String]) -> Int32 {
        if let code = CLI.command(args) { return code }
        fputs("Dragonscale: that starts the window. Use --help for jobs.\n\(CLI.usage)\n", stderr)
        return 2
    }

    public static func selfTest() -> String? { SelfTest.run() }

    public static func open(_ url: URL) { AppModel.shared.load(url) }
    public static func openPanel() { AppModel.shared.openPanel() }
    public static func openSecondPanel() { AppModel.shared.openSecondPanel() }
    public static func fold() { AppModel.shared.fold() }
    public static func restore() { AppModel.shared.restore() }
    public static func foldAgain() { AppModel.shared.foldAgain() }
    public static func exportFolded() { AppModel.shared.exportFolded() }
    public static func savePlain() { AppModel.shared.savePlain() }
    public static func useCard() { AppModel.shared.useCard() }
    public static func setPasses(_ value: Int) { AppModel.shared.setPasses(value) }

    public static var canFold: Bool { AppModel.shared.canFold }
    public static var canRestore: Bool { AppModel.shared.canRestore }
    public static var canExportFolded: Bool { AppModel.shared.canExportFolded }
    public static var canSavePlain: Bool { AppModel.shared.canSavePlain }
    public static var canFoldAgain: Bool { AppModel.shared.canFoldAgain }
    public static var busy: Bool { AppModel.shared.busy }
}
