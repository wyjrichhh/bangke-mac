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
  /// has the same identity (both are ~/Library/BangkePinyin).
  static let userDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("bangke-preview-test-rime", isDirectory: true)
}

final class BangkeApplicationDelegate {
  /// Same name and value as the real one, so the settings model and the tests
  /// agree on the notification the delegate posts on a schema switch.
  static let schemaChangedNotification = Notification.Name("BangkeSchemaChangedNotification")

  var config: BangkeConfig?
  private(set) var currentSchemaID = ""

  /// Mirrors the real delegate's contract for this one field: it records which
  /// schema is in use and announces it. The real one also reloads the panel
  /// theme, which needs a panel the harness does not have.
  func loadSettings(for schemaID: String) {
    if schemaID.count == 0 || schemaID.first == "." { return }
    currentSchemaID = schemaID
    NotificationCenter.default.post(name: Self.schemaChangedNotification, object: schemaID)
  }

  // No-ops: BangkePreferencesView wires buttons to these, and the harness never
  // presses them.
  func deploy() {}
  func reloadSettings() {}
  func preferencesDidClose() {}

  /// Resolve the About page dependencies without starting background checks.
  static let updateNotificationIdentifier = "preview-test-update"
  let unifiedUpdater = BangkeUpdateChecker()
  static var updatesEnabled: Bool { false }
  func checkForUpdates() {}
}

extension NSApplication {
  /// One shared instance (and a nil config, so BangkeSettings.load() resolves
  /// values from the patch files alone — the path a fresh install takes). Shared
  /// so a test can put a schema in place the way the controller would, by
  /// calling loadSettings(for:) on it.
  private static let testDelegate = BangkeApplicationDelegate()
  var bangkeAppDelegate: BangkeApplicationDelegate { Self.testDelegate }
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

/// Carries every key the settings window writes, at its shipped default, so a
/// save with nothing changed is a genuine no-op and section 10 can tell that
/// apart from a real edit.
private func customYAML(_ id: String) -> String {
  """
  patch:
    ai_predict:
      model_path: predict_models/zh-base-ct2-int8
      enabled: true
      target_index: 1
      min_input_length: 12
      min_hanzi: 2
      debounce_ms: 200
      max_tokens: 64
      quality: -1
      search_range: 10
      context_window_size: 10
      min_context_prompt_length: 2
      device: cpu
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

/// Re-runs deployment, which is what a real schema removal (via plum, or by
/// deleting the file) goes through — `get_schema_list()` reports the deployed
/// state, not what happens to be on disk right now.
func redeployForHarness() {
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  _ = rimeAPI.start_maintenance(true)
}
