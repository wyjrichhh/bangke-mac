import AppKit

// Stand-ins for the app-level symbols the preview reaches for.
//
// Main.swift owns @main, so it cannot join a test binary that has its own
// main.swift; and the real BangkeApplicationDelegate pulls in Sparkle and the
// whole IMK stack. BangkeSettings only ever reads `NSApp.bangkeAppDelegate.config`
// and `BangkeApp.userDir`, so these two are enough to link against the real
// preview code.

enum BangkeApp {
  /// Never read by the preview; BangkeSettings.customFile is the only user.
  static let userDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bangke-preview-test")
}

final class BangkeApplicationDelegate {
  var config: BangkeConfig?
}

extension NSApplication {
  var bangkeAppDelegate: BangkeApplicationDelegate { BangkeApplicationDelegate() }
}
