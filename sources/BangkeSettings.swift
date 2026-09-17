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
    var targetIndex = 1
    var minInputLength = 12
    var minHanzi = 2
    var debounceMs = 200
    var maxTokens = 64
    var quality = -1.0
    var searchRange = 10
    var contextWindowSize = 10
    var minContextPromptLength = 2
    var device = "cpu"
  }

  var appearance = Appearance()
  var behavior = Behavior()
  var aiPredict = AIPredict()
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
  static func aiWiredSchemas() -> [String] {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
    var list = RimeSchemaList()
    guard rimeAPI.get_schema_list(&list) else { return [] }
    defer { rimeAPI.free_schema_list(&list) }

    var schemas: [String] = []
    for index in 0..<Int(list.size) {
      guard let rawId = list.list[index].schema_id else { continue }
      let schemaID = String(cString: rawId)
      let config = BangkeConfig()
      if config.open(schemaID: schemaID, baseConfig: nil),
         config.getString("ai_predict/model_path") != nil {
        schemas.append(schemaID)
      }
      config.close()
    }
    return schemas
  }

  /// Names of the shipped colour schemes, for the picker.
  static func colorSchemeNames() -> [String] {
    guard let config = NSApp.bangkeAppDelegate.config, config.isOpen else { return [] }
    return config.mapKeys(inSection: "preset_color_schemes")
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

    settings.aiPredict = loadAI()
    return settings
  }

  private static func loadAI() -> AIPredict {
    guard let schemaID = aiWiredSchemas().first else { return AIPredict() }
    return loadAI(for: schemaID)
  }

  /// AI-wired schemas whose settings differ from the first one's. Empty in the
  /// normal case, since saving fans the same values out to all of them; a
  /// non-empty result means someone hand-edited one file and saving would
  /// flatten that difference.
  static func divergentAISchemas() -> [String] {
    let schemas = aiWiredSchemas()
    guard let reference = schemas.first else { return [] }
    let baseline = loadAI(for: reference)
    return schemas.dropFirst().filter { loadAI(for: $0) != baseline }
  }

  private static func loadAI(for schemaID: String) -> AIPredict {
    var predict = AIPredict()
    let file = RimePatchFile(contentsOf: customFile(schemaID))
    let config = BangkeConfig()
    let isOpen = config.open(schemaID: schemaID, baseConfig: nil)
    defer { config.close() }

    predict.enabled = block(file, "enabled", isOpen ? config.getBool("ai_predict/enabled") : nil, predict.enabled)
    predict.device = block(file, "device", isOpen ? config.getString("ai_predict/device") : nil, predict.device)
    predict.targetIndex = block(file, "target_index", isOpen ? config.getInt("ai_predict/target_index") : nil, predict.targetIndex)
    predict.minInputLength = block(file, "min_input_length", isOpen ? config.getInt("ai_predict/min_input_length") : nil, predict.minInputLength)
    predict.minHanzi = block(file, "min_hanzi", isOpen ? config.getInt("ai_predict/min_hanzi") : nil, predict.minHanzi)
    predict.debounceMs = block(file, "debounce_ms", isOpen ? config.getInt("ai_predict/debounce_ms") : nil, predict.debounceMs)
    predict.maxTokens = block(file, "max_tokens", isOpen ? config.getInt("ai_predict/max_tokens") : nil, predict.maxTokens)
    predict.quality = block(file, "quality", isOpen ? config.getDouble("ai_predict/quality")?.native : nil, predict.quality)
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
  ///   flatten a schema that had been tuned differently. Callers pass `false`
  ///   when the AI values still match what was loaded.
  func save(writeAI: Bool) throws -> Bool {
    var fullDeployment = false

    var bangke = RimePatchFile(contentsOf: Self.customFile(Brand.configName))
    for (key, value) in appearanceEntries() {
      bangke.setScalar(key, to: value.yaml)
    }
    for (key, value) in behaviorEntries() {
      bangke.setScalar(key, to: value.yaml)
    }
    try bangke.write(to: Self.customFile(Brand.configName))

    var defaultConfig = RimePatchFile(contentsOf: Self.customFile("default"))
    let defaultBefore = defaultConfig.text
    defaultConfig.setScalar("menu/page_size", to: PatchValue.int(behavior.pageSize).yaml)
    defaultConfig.setScalar("ascii_composer/switch_key/Shift_L", to: PatchValue.string(behavior.shiftLeftAction).yaml)
    defaultConfig.setScalar("ascii_composer/switch_key/Shift_R", to: PatchValue.string(behavior.shiftRightAction).yaml)
    fullDeployment = defaultConfig.text != defaultBefore
    try defaultConfig.write(to: Self.customFile("default"))

    // The schema files are left alone entirely when the AI values did not move:
    // not writing is the only way to guarantee a schema that diverged keeps its
    // own values until the user actually asks for a change.
    if writeAI {
      for schemaID in Self.aiWiredSchemas() {
        var file = RimePatchFile(contentsOf: Self.customFile(schemaID))
        let before = file.text
        for (key, value) in aiEntries() {
          file.setScalar(inBlock: Self.aiBlock, key, to: value.yaml)
        }
        if file.text != before {
          fullDeployment = true
          try file.write(to: Self.customFile(schemaID))
        }
      }
    }
    return fullDeployment
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

  /// Keys written into each schema's `ai_predict:` block. `model_path` is
  /// deliberately absent: it is installed, not user-editable, and dropping it
  /// would leave the translator with no model to load.
  func aiEntries() -> [(String, PatchValue)] {
    [
      ("enabled", .bool(aiPredict.enabled)),
      ("target_index", .int(aiPredict.targetIndex)),
      ("min_input_length", .int(aiPredict.minInputLength)),
      ("min_hanzi", .int(aiPredict.minHanzi)),
      ("debounce_ms", .int(aiPredict.debounceMs)),
      ("max_tokens", .int(aiPredict.maxTokens)),
      ("quality", .double(aiPredict.quality)),
      ("search_range", .int(aiPredict.searchRange)),
      ("context_window_size", .int(aiPredict.contextWindowSize)),
      ("min_context_prompt_length", .int(aiPredict.minContextPromptLength)),
      ("device", .string(aiPredict.device))
    ]
  }
}

// MARK: - Installer merge

extension BangkeSettings {
  /// Patch keys the settings window owns, preserved across an upgrade.
  static let preservedKeys = ["menu/page_size"]

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

  static func block(_ file: RimePatchFile, _ key: String, _ effective: Double?, _ fallback: Double) -> Double {
    file.scalar(inBlock: aiBlock, key).flatMap(Double.init) ?? effective ?? fallback
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
