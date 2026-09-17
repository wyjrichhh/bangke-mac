import AppKit

// Stand-ins for the app-level symbols the preview reaches for.
//
// Main.swift owns @main, so it cannot join a test binary that has its own
// main.swift; and the real BangkeApplicationDelegate pulls in Sparkle and the
// whole IMK stack. BangkeSettings only ever reads `NSApp.bangkeAppDelegate.config`
// and `BangkeApp.userDir`, so these two are enough to link against the real
// preview code.

enum BangkeApp {
  /// Throwaway Rime user dir. Doubles as librime's user_data_dir below, because
  /// BangkeSettings resolves <schema>.custom.yaml relative to it — production
  /// has the same identity (both are ~/Library/Rime).
  static let userDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("bangke-preview-test-rime", isDirectory: true)
}

final class BangkeApplicationDelegate {
  var config: BangkeConfig?
}

extension NSApplication {
  /// nil config, so BangkeSettings.load() resolves values from the patch files
  /// alone — the same fallback path a fresh install takes.
  var bangkeAppDelegate: BangkeApplicationDelegate { BangkeApplicationDelegate() }
}

/// Minimal schema that librime will accept, so `get_schema_list()` has
/// something to return and the AI-wiring checks in BangkeSettings run for real
/// rather than short-circuiting on an empty list.
private func schemaYAML(_ id: String) -> String {
  """
  schema:
    schema_id: \(id)
    name: \(id)
    version: "1"
  switches:
    - name: ascii_mode
      reset: 0
      states: [ 中, Ａ ]
  engine:
    translators:
      - punct_translator
    filters:
      - uniquifier
  """
}

private func customYAML(_ id: String) -> String {
  """
  patch:
    ai_predict:
      model_path: predict_models/zh-base-ct2-int8
      min_input_length: 12
      max_tokens: 64
      target_index: 1
  """
}

/// Builds a throwaway Rime user dir with two AI-wired schemas and deploys it.
///
/// librime's schema API dereferences engine state that only exists after
/// setup() + initialize(), and BangkeSettings reaches it through
/// aiWiredSchemas(). The real app is always initialized before the settings
/// window can be opened from the IME menu, so this is harness-only setup.
func initializeRimeForHarness() {
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  let user = BangkeApp.userDir
  let shared = user.appendingPathComponent("shared", isDirectory: true)
  try? FileManager.default.removeItem(at: user)
  for dir in [user, shared] {
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  func write(_ text: String, _ name: String, in dir: URL) {
    try! text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  // The base config has to exist for default.custom.yaml to patch — without it
  // deployment finds no schema_list and get_schema_list() stays empty.
  write("config_version: \"1.0\"\n", "default.yaml", in: shared)
  write("patch:\n  schema_list:\n    - schema: luna_pinyin\n    - schema: rime_ice\n",
        "default.custom.yaml", in: user)
  for id in ["luna_pinyin", "rime_ice"] {
    write(schemaYAML(id), "\(id).schema.yaml", in: shared)
    write(customYAML(id), "\(id).custom.yaml", in: user)
  }

  var traits = RimeTraits.rimeStructInit()
  traits.setCString(shared.path(), to: \.shared_data_dir)
  traits.setCString(user.path(), to: \.user_data_dir)
  traits.setCString(user.path(), to: \.log_dir)
  rimeAPI.setup(&traits)
  rimeAPI.initialize(nil)
  // Deployment finishes asynchronously; section 9 is what confirms the schemas
  // actually landed, so measuring here would only report a misleading zero.
  _ = rimeAPI.start_maintenance(true)
}
