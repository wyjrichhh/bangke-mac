//
//  BangkeSettings.swift
//  Bangke
//

import AppKit

/// Everything the settings window owns, plus the only code that writes it back.
///
/// The write target differs by setting: frontend appearance and frontend
/// behaviour live in the `bangke` config, `menu/page_size` and the Shift keys
/// belong to the engine's `default` config, and `ai_predict:` is read by the
/// plugin from the *schema* config (`predict_translator.cc` uses
/// `engine_->schema()->config()`), so it is written per schema. The UI still
/// presents one global AI page and fans the values out on save.
struct BangkeSettings {
  struct Appearance {
    var colorScheme = "native"
    var colorSchemeDark = ""
    var fontFace = "Avenir"
    var fontPoint = 16.0
    var candidateListLayout = "linear"
    var textOrientation = "horizontal"
    var inlinePreedit = true
    var inlineCandidate = false
    var translucency = false
    var mutualExclusive = false
    var memorizeSize = true
    var showPaging = false
    var cornerRadius = 7.0
    var hilitedCornerRadius = 0.0
    var borderHeight = -2.0
    var borderWidth = -2.0
    var lineSpacing = 5.0
    var spacing = 8.0
    var shadowSize = 0.0
    var alpha = 1.0
    var candidateFormat = "[label]. [candidate] [comment]"
    var statusMessageType = "mix"
  }

  struct Behavior {
    var showStatusIcon = false
    var notificationsWhen = "appropriate"
    var keyboardLayout = "last"
    var chordDuration = 0.1
    var pageSize = 5
    var shiftLeftAction = "commit_code"
    var shiftRightAction = "commit_code"
  }

  struct AIPredict: Equatable {
    var enabled = true
    var filterPunctuation = true
    var aiOnly = false
    var targetIndex = 1
    var minInputLength = 12
    var minHanzi = 2
    var debounceMs = 200
    var maxTokens = 64
    var searchRange = 10
    var contextWindowSize = 10
    var minContextPromptLength = 2
    var device = "cpu"
  }

  var appearance = Appearance()
  var behavior = Behavior()

  /// AI-wired schemas, in the order librime lists them.
  var aiSchemas: [NamedOption] = []
  /// AI settings per schema. `ai_predict` is read by the plugin from the schema
  /// config, so these are genuinely per-schema; the AI page edits one at a time.
  var aiPredict: [String: AIPredict] = [:]
  /// Which schema the AI page is showing. Defaults to the one being typed with.
  var selectedAISchema = ""
}

// MARK: - Paths

extension BangkeSettings {
  static let aiBlock = "ai_predict"

  static func customFile(_ configName: String) -> URL {
    BangkeApp.userDir.appendingPathComponent("\(configName).custom.yaml")
  }

  /// Schemas whose config already resolves `ai_predict/model_path` — the ones
  /// the installer wired the translator and filter into. Writing AI settings
  /// anywhere else would have no effect.
  static func aiWiredSchemas() -> [NamedOption] {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
    var list = RimeSchemaList()
    guard rimeAPI.get_schema_list(&list) else { return [] }
    defer { rimeAPI.free_schema_list(&list) }

    var schemas: [NamedOption] = []
    for index in 0..<Int(list.size) {
      guard let rawId = list.list[index].schema_id else { continue }
      let schemaID = String(cString: rawId)
      let config = BangkeConfig()
      if config.open(schemaID: schemaID, baseConfig: nil),
         config.getString("ai_predict/model_path") != nil {
        schemas.append(NamedOption(schemaID, name: config.getString("schema/name")))
      }
      config.close()
    }
    return schemas
  }

  /// A config entry the pickers show by name while storing its key. Both the
  /// colour schemes (`style/color_scheme` stores the key) and the AI-wired
  /// schemas (`aiPredict` is keyed by the id) work this way: the key is an
  /// ASCII identifier the user has no use for, the name is what the config
  /// calls it in Chinese. The key is the fallback for an entry that has none.
  struct NamedOption: Hashable, Identifiable {
    let id: String
    let name: String

    init(_ id: String, name: String? = nil) {
      self.id = id
      self.name = name ?? id
    }
  }

  /// The shipped colour schemes, in config order.
  static func colorSchemes() -> [NamedOption] {
    guard let config = NSApp.bangkeAppDelegate.config, config.isOpen else { return [] }
    return config.mapKeys(inSection: "preset_color_schemes").map { key in
      NamedOption(key, name: config.getString("preset_color_schemes/\(key)/name"))
    }
  }
}

// MARK: - Loading

extension BangkeSettings {
  static func load() -> BangkeSettings {
    var settings = BangkeSettings()
    let config = NSApp.bangkeAppDelegate.config
    let bangke = RimePatchFile(contentsOf: customFile(Brand.configName))
    let defaultConfig = RimePatchFile(contentsOf: customFile("default"))

    var appearance = Appearance()
    appearance.colorScheme = string(bangke, "style/color_scheme", config, appearance.colorScheme)
    appearance.colorSchemeDark = bangke.scalar("style/color_scheme_dark")
      ?? config?.getString("style/color_scheme_dark") ?? ""
    appearance.fontFace = string(bangke, "style/font_face", config, appearance.fontFace)
    appearance.fontPoint = double(bangke, "style/font_point", config, appearance.fontPoint)
    appearance.candidateListLayout = string(bangke, "style/candidate_list_layout", config, appearance.candidateListLayout)
    appearance.textOrientation = string(bangke, "style/text_orientation", config, appearance.textOrientation)
    appearance.inlinePreedit = boolean(bangke, "style/inline_preedit", config, appearance.inlinePreedit)
    appearance.inlineCandidate = boolean(bangke, "style/inline_candidate", config, appearance.inlineCandidate)
    appearance.translucency = boolean(bangke, "style/translucency", config, appearance.translucency)
    appearance.mutualExclusive = boolean(bangke, "style/mutual_exclusive", config, appearance.mutualExclusive)
    appearance.memorizeSize = boolean(bangke, "style/memorize_size", config, appearance.memorizeSize)
    appearance.showPaging = boolean(bangke, "style/show_paging", config, appearance.showPaging)
    appearance.cornerRadius = double(bangke, "style/corner_radius", config, appearance.cornerRadius)
    appearance.hilitedCornerRadius = double(bangke, "style/hilited_corner_radius", config, appearance.hilitedCornerRadius)
    appearance.borderHeight = double(bangke, "style/border_height", config, appearance.borderHeight)
    appearance.borderWidth = double(bangke, "style/border_width", config, appearance.borderWidth)
    appearance.lineSpacing = double(bangke, "style/line_spacing", config, appearance.lineSpacing)
    appearance.spacing = double(bangke, "style/spacing", config, appearance.spacing)
    appearance.shadowSize = double(bangke, "style/shadow_size", config, appearance.shadowSize)
    appearance.alpha = double(bangke, "style/alpha", config, appearance.alpha)
    appearance.candidateFormat = string(bangke, "style/candidate_format", config, appearance.candidateFormat)
    appearance.statusMessageType = string(bangke, "style/status_message_type", config, appearance.statusMessageType)
    settings.appearance = appearance

    var behavior = Behavior()
    behavior.showStatusIcon = boolean(bangke, "status_icon/show", config, behavior.showStatusIcon)
    behavior.notificationsWhen = string(bangke, "show_notifications_when", config, behavior.notificationsWhen)
    behavior.keyboardLayout = string(bangke, "keyboard_layout", config, behavior.keyboardLayout)
    behavior.chordDuration = double(bangke, "chord_duration", config, behavior.chordDuration)
    behavior.pageSize = integer(defaultConfig, "menu/page_size", config, behavior.pageSize)
    behavior.shiftLeftAction = string(defaultConfig, "ascii_composer/switch_key/Shift_L", config, behavior.shiftLeftAction)
    behavior.shiftRightAction = string(defaultConfig, "ascii_composer/switch_key/Shift_R", config, behavior.shiftRightAction)
    settings.behavior = behavior

    let schemas = aiWiredSchemas()
    settings.aiSchemas = schemas
    settings.aiPredict = Dictionary(uniqueKeysWithValues: schemas.map { ($0.id, loadAI(for: $0.id)) })
    // Open on the schema the user is actually typing with, so the page shows
    // settings that are in effect rather than an arbitrary one.
    let active = NSApp.bangkeAppDelegate.currentSchemaID
    settings.selectedAISchema = schemas.contains(where: { $0.id == active })
      ? active : (schemas.first?.id ?? "")
    return settings
  }

  private static func loadAI(for schemaID: String) -> AIPredict {
    var predict = AIPredict()
    let file = RimePatchFile(contentsOf: customFile(schemaID))
    let config = BangkeConfig()
    let isOpen = config.open(schemaID: schemaID, baseConfig: nil)
    defer { config.close() }

    predict.enabled = block(file, "enabled", isOpen ? config.getBool("ai_predict/enabled") : nil, predict.enabled)
    predict.filterPunctuation = block(file, "filter_punctuation",
                                      isOpen ? config.getBool("ai_predict/filter_punctuation") : nil,
                                      predict.filterPunctuation)
    predict.aiOnly = block(file, "ai_only",
                           isOpen ? config.getBool("ai_predict/ai_only") : nil,
                           predict.aiOnly)
    predict.device = block(file, "device", isOpen ? config.getString("ai_predict/device") : nil, predict.device)
    predict.targetIndex = block(file, "target_index", isOpen ? config.getInt("ai_predict/target_index") : nil, predict.targetIndex)
    predict.minInputLength = block(file, "min_input_length", isOpen ? config.getInt("ai_predict/min_input_length") : nil, predict.minInputLength)
    predict.minHanzi = block(file, "min_hanzi", isOpen ? config.getInt("ai_predict/min_hanzi") : nil, predict.minHanzi)
    predict.debounceMs = block(file, "debounce_ms", isOpen ? config.getInt("ai_predict/debounce_ms") : nil, predict.debounceMs)
    predict.maxTokens = block(file, "max_tokens", isOpen ? config.getInt("ai_predict/max_tokens") : nil, predict.maxTokens)
    predict.searchRange = block(file, "search_range", isOpen ? config.getInt("ai_predict/search_range") : nil, predict.searchRange)
    predict.contextWindowSize = block(file, "context_window_size", isOpen ? config.getInt("ai_predict/context_window_size") : nil, predict.contextWindowSize)
    predict.minContextPromptLength = block(file, "min_context_prompt_length",
                                      isOpen ? config.getInt("ai_predict/min_context_prompt_length") : nil,
                                      predict.minContextPromptLength)
    return predict
  }
}

// MARK: - Saving

extension BangkeSettings {
  /// Returns whether the engine needs a full deployment. Frontend style changes
  /// only need librime restarted; `menu/page_size` and the AI block feed schema
  /// compilation, which a quick maintenance pass is not guaranteed to pick up.
  /// - Parameter writeAI: whether the per-schema `ai_predict` blocks may be
  ///   rewritten. The AI page shows one schema's values and fans them out to
  ///   all of them, so writing when the user changed nothing would silently
  /// What a save actually did. The caller uses this to avoid restarting librime
  /// for a write that turned out to be a no-op — `finalize()` tears the engine
  /// down, and the AI plugin's worker thread is running on top of it.
  struct SaveResult {
    /// False when every file already held these values.
    var changed = false
    /// True when a schema-affecting file changed, which needs a full deployment
    /// rather than a plain restart.
    var needsFullDeployment = false
  }

  func save() throws -> SaveResult {
    var result = SaveResult()

    var bangke = RimePatchFile(contentsOf: Self.customFile(Brand.configName))
    let bangkeBefore = bangke.text
    for (key, value) in appearanceEntries() {
      bangke.setScalar(key, to: value.yaml)
    }
    for (key, value) in behaviorEntries() {
      bangke.setScalar(key, to: value.yaml)
    }
    if bangke.text != bangkeBefore {
      result.changed = true
      try bangke.write(to: Self.customFile(Brand.configName))
    }

    var defaultConfig = RimePatchFile(contentsOf: Self.customFile("default"))
    let defaultBefore = defaultConfig.text
    defaultConfig.setScalar("menu/page_size", to: PatchValue.int(behavior.pageSize).yaml)
    defaultConfig.setScalar("ascii_composer/switch_key/Shift_L", to: PatchValue.string(behavior.shiftLeftAction).yaml)
    defaultConfig.setScalar("ascii_composer/switch_key/Shift_R", to: PatchValue.string(behavior.shiftRightAction).yaml)
    if defaultConfig.text != defaultBefore {
      result.changed = true
      result.needsFullDeployment = true
      try defaultConfig.write(to: Self.customFile("default"))
    }

    // Each schema carries its own AI settings now, so a schema is written only
    // when its own values moved — editing the one on screen never disturbs the
    // others.
    //
    // Re-enumerated rather than reusing the load-time list: schemas can be added
    // or removed while the window sits open, and writing to one that is gone
    // would resurrect an orphan .custom.yaml. A schema added since load has no
    // entry in aiPredict and is skipped, which is what we want — it keeps
    // whatever it shipped with.
    for schema in Self.aiWiredSchemas() {
      guard let predict = aiPredict[schema.id] else { continue }
      var file = RimePatchFile(contentsOf: Self.customFile(schema.id))
      let before = file.text
      for (key, value) in Self.aiEntries(for: predict) {
        file.setScalar(inBlock: Self.aiBlock, key, to: value.yaml)
      }
      Self.applySpellerAlphabet(for: predict, schemaID: schema.id, file: &file)
      for key in Self.retiredAIKeys {
        file.removeScalar(inBlock: Self.aiBlock, key)
      }
      if file.text != before {
        result.changed = true
        result.needsFullDeployment = true
        try file.write(to: Self.customFile(schema.id))
      }
    }
    return result
  }

  /// Flat `patch:` paths for the `bangke` config, in the order they appear.
  func appearanceEntries() -> [(String, PatchValue)] {
    var entries: [(String, PatchValue)] = [
      ("style/color_scheme", .string(appearance.colorScheme)),
      ("style/font_face", .string(appearance.fontFace)),
      ("style/font_point", .double(appearance.fontPoint)),
      ("style/candidate_list_layout", .string(appearance.candidateListLayout)),
      ("style/text_orientation", .string(appearance.textOrientation)),
      ("style/inline_preedit", .bool(appearance.inlinePreedit)),
      ("style/inline_candidate", .bool(appearance.inlineCandidate)),
      ("style/translucency", .bool(appearance.translucency)),
      ("style/mutual_exclusive", .bool(appearance.mutualExclusive)),
      ("style/memorize_size", .bool(appearance.memorizeSize)),
      ("style/show_paging", .bool(appearance.showPaging)),
      ("style/corner_radius", .double(appearance.cornerRadius)),
      ("style/hilited_corner_radius", .double(appearance.hilitedCornerRadius)),
      ("style/border_height", .double(appearance.borderHeight)),
      ("style/border_width", .double(appearance.borderWidth)),
      ("style/line_spacing", .double(appearance.lineSpacing)),
      ("style/spacing", .double(appearance.spacing)),
      ("style/shadow_size", .double(appearance.shadowSize)),
      ("style/alpha", .double(appearance.alpha)),
      ("style/candidate_format", .string(appearance.candidateFormat)),
      ("style/status_message_type", .string(appearance.statusMessageType))
    ]
    if !appearance.colorSchemeDark.isEmpty {
      entries.insert(("style/color_scheme_dark", .string(appearance.colorSchemeDark)), at: 1)
    }
    return entries
  }

  func behaviorEntries() -> [(String, PatchValue)] {
    [
      ("status_icon/show", .bool(behavior.showStatusIcon)),
      ("show_notifications_when", .string(behavior.notificationsWhen)),
      ("keyboard_layout", .string(behavior.keyboardLayout)),
      ("chord_duration", .double(behavior.chordDuration)),
      ("menu/page_size", .int(behavior.pageSize)),
      ("ascii_composer/switch_key/Shift_L", .string(behavior.shiftLeftAction)),
      ("ascii_composer/switch_key/Shift_R", .string(behavior.shiftRightAction))
    ]
  }

  /// Keys the window used to write into `ai_predict:` and no longer owns. They
  /// are dropped on the next save rather than left behind for good — the plugin
  /// ignores an unknown key, so nothing else would ever remove it.
  static let retiredAIKeys = ["quality"]

  /// Characters the AI-only mode adds to a schema's speller alphabet.
  ///
  /// Digits and this punctuation set all have a job on the menu in normal use —
  /// digits select a candidate, punctuation is committed straight through — and
  /// the point of the mode is that they are plain input instead. Listing them in
  /// the alphabet is what keeps them inside the pinyin segment, so the model
  /// actually receives them; the frontend then feeds them with `set_input`
  /// rather than as key events, which is what stops the selector and the
  /// key_binder paging bindings from taking them first.
  static let aiOnlyExtraInput = "1234567890,.;:!?"

  /// Where the mode stashes the alphabet it replaced. It lives inside the
  /// `ai_predict` block rather than a side file so it travels with the setting
  /// it belongs to and survives the installer's block-preserving upgrade.
  static let alphabetBackupKey = "alphabet_backup"

  /// Set when the mode *created* the `speller/alphabet` line rather than
  /// overrunning one the user already had. Turning the mode off deletes our own
  /// line outright — restoring by writing the old value back would leave a line
  /// that no longer does anything — but a line the user wrote is theirs, and it
  /// gets its value back instead.
  static let alphabetAddedKey = "alphabet_added"

  /// Let digits ride along inside the pinyin segment.
  ///
  /// `abc_segmentor` decides what belongs to a segment by looking each character
  /// up in `speller/alphabet`, and the plugin only ever sees a segment's own
  /// input — so a digit the alphabet does not list becomes a segment of its own
  /// and never reaches the model. The alphabet therefore has to carry digits,
  /// and it cannot do so unconditionally: `speller` sits ahead of `selector` in
  /// the schema's processor list, so listing digits there would also stop them
  /// from selecting candidates in normal use. Extend on the way in, restore on
  /// the way out.
  private static func applySpellerAlphabet(for predict: AIPredict,
                                           schemaID: String,
                                           file: inout RimePatchFile) {
    if predict.aiOnly {
      // The original is captured once, off the effective alphabet, and only the
      // first time — later saves must not back up the value they themselves
      // extended, or the digits would become permanent.
      //
      // The extension itself is re-asserted on *every* save rather than only
      // the first. That is what makes the mode survive an install: the installer
      // rebuilds these files from the shipped copy and only carries over the
      // keys it knows about, so anything it drops would otherwise stay dropped
      // until the user toggled the mode off and back on.
      let backup: String
      if let captured = file.scalar(inBlock: aiBlock, alphabetBackupKey) {
        backup = captured
      } else if let original = spellerAlphabet(for: schemaID) {
        backup = original
        file.setScalar(inBlock: aiBlock, alphabetBackupKey,
                       to: PatchValue.string(original).yaml)
        // Recorded before the line is written, so it answers "did the user
        // already have one?" rather than "is there one now?".
        if file.scalar("speller/alphabet") == nil {
          file.setScalar(inBlock: aiBlock, alphabetAddedKey,
                         to: PatchValue.bool(true).yaml)
        }
      } else {
        return
      }
      file.setScalar("speller/alphabet",
                     to: PatchValue.string(backup + aiOnlyExtraInput).yaml)
    } else if let backup = file.scalar(inBlock: aiBlock, alphabetBackupKey) {
      if file.scalar(inBlock: aiBlock, alphabetAddedKey) != nil {
        file.removeScalar("speller/alphabet")
      } else {
        file.setScalar("speller/alphabet", to: PatchValue.string(backup).yaml)
      }
      file.removeScalar(inBlock: aiBlock, alphabetAddedKey)
      file.removeScalar(inBlock: aiBlock, alphabetBackupKey)
    }
  }

  /// The schema's effective `speller/alphabet`: what the mode extends, and what
  /// turning it off has to put back.
  private static func spellerAlphabet(for schemaID: String) -> String? {
    let config = BangkeConfig()
    defer { config.close() }
    guard config.open(schemaID: schemaID, baseConfig: nil) else { return nil }
    return config.getString("speller/alphabet")
  }

  /// Keys written into a schema's `ai_predict:` block. `model_path` is
  /// deliberately absent: it is installed, not user-editable, and dropping it
  /// would leave the translator with no model to load.
  static func aiEntries(for predict: AIPredict) -> [(String, PatchValue)] {
    [
      ("enabled", .bool(predict.enabled)),
      ("filter_punctuation", .bool(predict.filterPunctuation)),
      ("ai_only", .bool(predict.aiOnly)),
      ("target_index", .int(predict.targetIndex)),
      ("min_input_length", .int(predict.minInputLength)),
      ("min_hanzi", .int(predict.minHanzi)),
      ("debounce_ms", .int(predict.debounceMs)),
      ("max_tokens", .int(predict.maxTokens)),
      ("search_range", .int(predict.searchRange)),
      ("context_window_size", .int(predict.contextWindowSize)),
      ("min_context_prompt_length", .int(predict.minContextPromptLength)),
      ("device", .string(predict.device))
    ]
  }
}

// MARK: - Installer merge

extension BangkeSettings {
  /// Patch keys the settings window owns, preserved across an upgrade.
  ///
  /// `speller/alphabet` belongs here for the same reason as `menu/page_size`:
  /// the window writes it (the AI-only mode appends digits — see
  /// applySpellerAlphabet), so an install that came with a fresh custom.yaml
  /// would silently drop it, and the mode would lose digits inside the pinyin
  /// segment. Dropping it looks exactly like "the feature stopped working":
  /// digits fall back to the selector.
  static let preservedKeys = ["menu/page_size", "speller/alphabet"]

  /// Key families the settings window owns. `ascii_composer/switch_key/*` only
  /// exists because the window wrote it — the shipped file has no such key.
  static let preservedKeyPrefixes = ["ascii_composer/switch_key/"]

  /// Write the shipped patch file to `destination` while keeping the values the
  /// user chose for the keys this window owns.
  ///
  /// Engine wiring in the same files (translators, filters, the recognizer
  /// pattern) is deliberately *not* preserved — it has to be replaced when the
  /// bundled plugins change, and it is the reason the installer overwrites these
  /// files at all. The trade-off is that a future change to a shipped default
  /// cannot reach users who have that key: their value is indistinguishable from
  /// a deliberate choice, so it wins.
  @discardableResult
  static func installCustomConfig(factory: URL, destination: URL) -> Bool {
    var file = RimePatchFile(contentsOf: factory)
    guard !file.text.isEmpty else { return false }

    let existing = RimePatchFile(contentsOf: destination)
    for key in preservedKeys {
      if let value = existing.scalar(key) {
        file.setScalar(key, to: value)
      }
    }
    for prefix in preservedKeyPrefixes {
      for (key, value) in existing.scalars(withPrefix: prefix) {
        file.setScalar(key, to: value)
      }
    }
    // The whole ai_predict block is user-tunable; a key added to the shipped
    // file still lands, because only the keys the user has are carried over.
    for (key, value) in existing.scalars(inBlock: aiBlock) {
      file.setScalar(inBlock: aiBlock, key, to: value)
    }

    // The alphabet extension is *derived* from the block — it exists only while
    // `ai_only` is on, and it sits outside `ai_predict`, so carrying the block
    // over only keeps it when the user's file happened to still have it. Any
    // install that dropped it (which is exactly what this function used to do)
    // would then need a settings save to repair. Recomputing it here makes an
    // install land self-consistent, with no manual step.
    if file.scalar(inBlock: aiBlock, "ai_only") == "true",
       let backup = file.scalar(inBlock: aiBlock, alphabetBackupKey) {
      file.setScalar("speller/alphabet",
                     to: PatchValue.string(backup + aiOnlyExtraInput).yaml)
    }

    do {
      try file.write(to: destination)
      return true
    } catch {
      print("Could not write \(destination.path): \(error.localizedDescription)")
      return false
    }
  }
}

// MARK: - Value resolution

private extension BangkeSettings {
  static func string(_ file: RimePatchFile, _ key: String, _ config: BangkeConfig?, _ fallback: String) -> String {
    file.scalar(key) ?? config?.getString(key) ?? fallback
  }

  static func boolean(_ file: RimePatchFile, _ key: String, _ config: BangkeConfig?, _ fallback: Bool) -> Bool {
    bool(file.scalar(key)) ?? config?.getBool(key) ?? fallback
  }

  static func integer(_ file: RimePatchFile, _ key: String, _ config: BangkeConfig?, _ fallback: Int) -> Int {
    file.scalar(key).flatMap(Int.init) ?? config?.getInt(key) ?? fallback
  }

  static func double(_ file: RimePatchFile, _ key: String, _ config: BangkeConfig?, _ fallback: Double) -> Double {
    file.scalar(key).flatMap(Double.init) ?? config?.getDouble(key)?.native ?? fallback
  }

  static func block(_ file: RimePatchFile, _ key: String, _ effective: Bool?, _ fallback: Bool) -> Bool {
    bool(file.scalar(inBlock: aiBlock, key)) ?? effective ?? fallback
  }

  static func block(_ file: RimePatchFile, _ key: String, _ effective: Int?, _ fallback: Int) -> Int {
    file.scalar(inBlock: aiBlock, key).flatMap(Int.init) ?? effective ?? fallback
  }

  static func block(_ file: RimePatchFile, _ key: String, _ effective: String?, _ fallback: String) -> String {
    file.scalar(inBlock: aiBlock, key) ?? effective ?? fallback
  }

  static func bool(_ raw: String?) -> Bool? {
    switch raw?.lowercased() {
    case "true", "yes", "on": true
    case "false", "no", "off": false
    default: nil
    }
  }
}

/// A scalar in a patch file. Rime parses these from YAML, so `true`/`false` must
/// stay unquoted while strings that YAML would misread need quoting.
enum PatchValue {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)

  var yaml: String {
    switch self {
    case .bool(let value):
      return value ? "true" : "false"
    case .int(let value):
      return String(value)
    case .double(let value):
      return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    case .string(let value):
      return Self.quoted(value)
    }
  }

  private static func quoted(_ value: String) -> String {
    let indicators = "-?:,[]{}#&*!|>'\"%@`"
    let needsQuoting = value.isEmpty
      || value.contains("#")
      || value.contains("'")
      || value.contains("\"")
      || value.contains(": ")
      || (value.first.map { indicators.contains($0) } ?? false)
    guard needsQuoting else { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
  }
}
