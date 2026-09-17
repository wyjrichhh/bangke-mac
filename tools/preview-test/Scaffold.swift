import AppKit

// Stand-ins for the app-level symbols the preview reaches for.
//
// Main.swift owns @main, so it cannot join a test binary that has its own
// main.swift; and the real BangkeApplicationDelegate pulls in Sparkle and the
// whole IMK stack. BangkeSettings only ever reads `NSApp.bangkeAppDelegate.config`
// and `BangkeApp.userDir`, so these two are enough to link against the real
// preview code.

enum BangkeApp {
  /// Sandbox for the settings round-trip checks; main.swift clears it on start.
  static let userDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("bangke-preview-test-rime", isDirectory: true)
}

final class BangkeApplicationDelegate {
  var config: BangkeConfig?
}

/// librime's schema API dereferences engine state that only exists after
/// setup() + initialize(), and BangkeSettings.load() reaches it through
/// aiWiredSchemas(). The real app is always initialized before the settings
/// window can be opened from the IME menu, so this is harness-only setup —
/// kept in its own directory so it cannot touch the settings sandbox.
func initializeRimeForHarness() {
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bangke-preview-test-engine")
  let shared = root.appendingPathComponent("shared")
  let user = root.appendingPathComponent("user")
  for dir in [shared, user] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  var traits = RimeTraits.rimeStructInit()
  traits.setCString(shared.path(), to: \.shared_data_dir)
  traits.setCString(user.path(), to: \.user_data_dir)
  traits.setCString(root.path(), to: \.log_dir)
  rimeAPI.setup(&traits)
  rimeAPI.initialize(nil)
}

extension NSApplication {
  var bangkeAppDelegate: BangkeApplicationDelegate { BangkeApplicationDelegate() }
}
