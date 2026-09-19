//
//  BangkeInputController.swift
//  Bangke
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class BangkeInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0
  /// Property the AI plugin raises while an inference is outstanding.
  private static let aiPendingProperty = "ai_predict/pending"
  private static let aiPumpInterval: TimeInterval = 0.15
  /// Hard stop so a composition left open cannot keep this ticking forever.
  private static let aiPumpTimeout: TimeInterval = 3
  /// Property carrying the text before the cursor, read by the AI plugin.
  private static let clientContextProperty = "ai_predict/client_context"
  /// How far back to read. Deliberately generous: the plugin trims to its own
  /// schema-configured limit (`ai_predict/context_window_chars`), so this
  /// constant never has to be kept in step with that knob.
  private static let clientContextReadLimit = 64
  /// Read-back mismatches tolerated before this client stops being trusted.
  private static let clientContextFailureLimit = 2

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  /// Candidates in the menu as of the last refresh. AI-only mode reads it to
  /// tell "a prediction is on screen" from "the model has not answered yet",
  /// which decides whether Space has anything to confirm (see handle).
  private var menuCandidateCount = 0
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: BangkeInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: BangkeInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  private var aiPumpTimer: Timer?
  private var aiPumpDeadline: Date?
  /// Whether this client's attributedSubstring can be believed. Cleared for
  /// the rest of the session once read-back verification fails repeatedly.
  private var trustedClientText = true
  private var clientContextFailures = 0
  private var lastPublishedContext: String?

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to consume the key event; return false to pass it to the client app.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      // Whether the client answers attributedSubstring is a property of the
      // app, not of this session's history, so a switch starts over.
      trustedClientText = true
      clientContextFailures = 0
      lastPublishedContext = nil
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      var rimeModifiers: UInt32 = BangkeKeycode.osxModifiersToRime(modifiers: modifiers)
      // Some remote desktop tools send flagsChanged with keyCode 0; infer the real modifier key when needed.
      var keyCode = event.keyCode
      if !BangkeKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = BangkeKeycode.inferModifierKeycode(from: changes) else {
          lastModifiers = modifiers
          rimeUpdate()
          handled = true
          break
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = BangkeKeycode.osxKeycodeToRime(keycode: keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // Rime expects XK_Caps_Lock before the lock mask changes; NSFlagsChanged has already applied it.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Process releases first because some modifier releases arrive with the next keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) {
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else {
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      // Let client apps handle Command shortcuts.
      if modifiers.contains(.command) {
        break
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      if let char = keyChars?.first {
        let rimeKeycode = BangkeKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          // AI-only mode has no dictionary to fall back on, so its menu is empty
          // for as long as the model takes to answer. rime reads that as "nothing
          // is selected" and Space then confirms the *raw input* -- the pinyin
          // goes to the screen unread, and worse, enters commit history as
          // context for the next prediction. Swallow it instead: with no
          // candidate on screen there is nothing to confirm.
          //
          // The composition check matters: with nothing being composed the menu
          // is empty too, and swallowing Space there would break ordinary
          // typing. Only a live composition has raw input to confirm.
          if NSApp.bangkeAppDelegate.aiOnly, rimeKeycode == XK_space,
             modifiers.isDisjoint(with: [.command, .control, .option]),
             menuCandidateCount == 0,
             let input = rimeAPI.get_input(session), input.pointee != 0 {
            handled = true
            break
          }
          // AI-only mode wants digits and punctuation as ordinary input, but on
          // a live menu they all have another job that gets first refusal:
          // `selector` takes digits, `punctuator` commits punctuation straight
          // through, and `key_binder` claims "," / "." / "[" / "]" for paging
          // before either of them runs. Appending the character to the
          // composition sidesteps that whole chain, so none of those have to be
          // reconfigured or turned off. The composition check keeps the same
          // characters working as themselves when nothing is being composed.
          if NSApp.bangkeAppDelegate.aiOnly,
             modifiers.isDisjoint(with: [.command, .control, .option]),
             BangkeSettings.aiOnlyExtraInput.contains(char),
             let input = rimeAPI.get_input(session), input.pointee != 0 {
            _ = rimeAPI.set_input(session, String(cString: input) + String(char))
            handled = true
            rimeUpdate()
            break
          }
          let rimeModifiers = BangkeKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    var keyboardLayout = NSApp.bangkeAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    // Activation delivers no flagsChanged event, and NSEvent.modifierFlags
    // only reflects this process's own event stream, so lastModifiers may
    // disagree with the actual Caps Lock state by now. Seed it from the
    // session-wide hardware state; otherwise the next Caps Lock press can
    // compare equal to the stale lastModifiers and be dropped by the
    // early-return in handle().
    if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) {
      lastModifiers.insert(.capsLock)
    } else {
      lastModifiers.remove(.capsLock)
    }
    preedit = ""
    if session != 0 {
      let state = rimeAPI.get_option(session, "ascii_mode")
      let label = rimeAPI.get_state_label_abbreviated(session, "ascii_mode", state, true).asString
      NSApp.bangkeAppDelegate.updateStatusIcon(asciiMode: state, schemaLabel: label)
    }
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    super.init(server: server, delegate: delegate, client: client)
    createSession()

    NotificationCenter.default.addObserver(
      forName: .init("BangkeSetASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.handleASCIIModeToggle(notification)
    }

    NotificationCenter.default.addObserver(
      forName: .init("BangkeReportASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.reportASCIIMode(notification)
    }
  }

  override func deactivateServer(_ sender: Any!) {
    hidePalettes()
    stopAIPump()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    stopAIPump()
    NSApp.bangkeAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    guard session != 0 else { return }

    // Commit what the composition would produce, not rime's raw input buffer:
    // the buffer is pinyin, so a client that resets its input context
    // mid-composition (Chromium-based ones do) would otherwise get
    // "jiushizhegeshurukuangshizheyangde" inserted instead of the characters
    // the user actually picked.
    let preview = rimeCommitPreview()
    let text = preview.isEmpty ? rimeInput() : preview
    if !text.isEmpty {
      commit(string: text)
    }
    rimeAPI.clear_composition(session)
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"),
                             action: #selector(BangkeInputController.showSettingsWindow), keyEquivalent: "")
    setting.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(setting)

    return menu
  }

  @objc func deploy() {
    NSApp.bangkeAppDelegate.deploy()
  }

  @objc func showSettingsWindow() {
    NSApp.bangkeAppDelegate.showSettingsWindow()
  }

  private(set) var specialCommentIndices: [ReservedPropertyKey: Set<Int>] = [:]

  func handleReservedProperty(key rawKey: String, value rawValue: String, for sessionId: RimeSessionId) throws(ReservedPropertyError) {
    guard session == sessionId, session != 0, rimeAPI.find_session(session) else { return }
    guard let key = ReservedPropertyKey(rawValue: rawKey) else { throw .unknownInput(rawKey) }
    let parsed = try ReservedPropertyValue.parse(rawValue)
    switch key {
    case .commentHighlight:
      specialCommentIndices[.commentHighlight] = try parsed.indices()
    case .commentWarning:
      specialCommentIndices[.commentWarning] = try parsed.indices()
    case .refreshUI:
      rimeUpdate(clearReservedComments: false)
    }
  }

  deinit {
    destroySession()
  }
}

private extension BangkeInputController {

  /// Re-compose on this thread while the AI plugin has an inference in flight.
  ///
  /// The plugin used to re-compose from its own worker thread so a finished
  /// prediction would reach the menu on its own. That ran a full Compose()
  /// concurrently with this thread's Compose() on the same Context, and
  /// librime's Context/Engine are not thread-safe — crash reports show both
  /// threads in LuaTranslator::Query, one of them taking a bad access in
  /// luajit. The worker now only fills its cache and raises
  /// `ai_predict/pending`; surfacing the result is this side's job.
  func pumpAIPrediction() {
    guard aiPumpTimer == nil,
          session != 0,
          isAIPredictionPending(),
          let input = rimeAPI.get_input(session), input.pointee != 0 else {
      return
    }
    aiPumpDeadline = Date().addingTimeInterval(Self.aiPumpTimeout)
    aiPumpTimer = Timer.scheduledTimer(withTimeInterval: Self.aiPumpInterval, repeats: true) { [weak self] _ in
      self?.onAIPumpTimer()
    }
  }

  func onAIPumpTimer() {
    guard session != 0,
          isAIPredictionPending(),
          let input = rimeAPI.get_input(session), input.pointee != 0,
          let deadline = aiPumpDeadline, Date() < deadline else {
      stopAIPump()
      return
    }
    // Any option update makes ConcreteEngine::OnOptionUpdate call
    // RefreshNonConfirmedComposition() on the calling thread while a
    // composition is active — the re-compose we want, on the right thread.
    // soft_cursor is an option this controller already owns, so re-setting it
    // is side-effect free (rimeUpdate does the same on every keystroke).
    rimeAPI.set_option(session, "soft_cursor", rimeAPI.get_option(session, "soft_cursor"))
    rimeUpdate(clearReservedComments: false)
  }

  func stopAIPump() {
    aiPumpTimer?.invalidate()
    aiPumpTimer = nil
    aiPumpDeadline = nil
  }

  func isAIPredictionPending() -> Bool {
    guard session != 0 else { return false }
    var buffer = [CChar](repeating: 0, count: 16)
    guard rimeAPI.get_property(session, Self.aiPendingProperty, &buffer, buffer.count) else { return false }
    return String(cString: buffer) == "1"
  }

  func onChordTimer(_: Timer) {
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // Chord typing releases are synthesized after the configured timeout.
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.bangkeAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      BangkeInputController.unknownAppCnt &+= 1
      return "UnknownApp\(BangkeInputController.unknownAppCnt)"
    }()
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""
    // A new session owns a fresh Context, so the property we published last is
    // gone. Forget the cached value or an unchanged client text would be
    // skipped as "already published" and the plugin would keep falling back.
    lastPublishedContext = nil
    trustedClientText = true
    clientContextFailures = 0

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.bangkeAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
    if let reportBundleID = NSApp.bangkeAppDelegate.config?.getBool("unsafe/report_bundleid"), reportBundleID {
      currentApp.withCString { name in
        rimeAPI.set_property(session, "client_app", name)
      }
    }
  }

  func destroySession() {
    stopAIPump()
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  /// rime's raw input buffer. Returns "" when there is no composition.
  private func rimeInput() -> String {
    guard session != 0, let input = rimeAPI.get_input(session) else { return "" }
    return String(cString: input)
  }

  /// What rime would commit right now -- the selected candidates -- without
  /// waiting for a commit event. Empty when nothing is selectable.
  private func rimeCommitPreview() -> String {
    var ctx = RimeContext_stdbool.rimeStructInit()
    guard session != 0, rimeAPI.get_context(session, &ctx) else { return "" }
    defer { _ = rimeAPI.free_context(&ctx) }
    return ctx.commit_text_preview.map { String(cString: $0) } ?? ""
  }

  /// The text immediately before the composition, as the host app reports it.
  ///
  /// Returns nil when the client declines to answer -- `attributedSubstring` is
  /// @required but documented as "may return nil" -- which is not the same as a
  /// cursor sitting at the start of the document. Either way the plugin is told
  /// nothing, and it reads that as "fall back to commit history".
  private func readClientContext() -> String? {
    guard let client else { return nil }
    // While composing, selectedRange() points *inside* the marked text, so
    // reading back from it would hand the model our own preedit.
    let marked = client.markedRange()
    let end = marked.location != NSNotFound ? marked.location : client.selectedRange().location
    guard end != NSNotFound, end > 0 else { return "" }
    let start = max(0, end - Self.clientContextReadLimit)
    return client.attributedSubstring(from: NSRange(location: start, length: end - start))?.string
  }

  /// Hand the plugin the text before the cursor.
  ///
  /// Skips the write when the value is unchanged: `Context::set_property` fires
  /// its update notifier on every set, which makes the plugin re-run inference,
  /// and during plain pinyin typing this text does not move at all.
  private func publishClientContext() {
    guard session != 0 else { return }
    let context = trustedClientText ? (readClientContext() ?? "") : ""
    guard context != lastPublishedContext else { return }
    lastPublishedContext = context
    rimeAPI.set_property(session, Self.clientContextProperty, context)
  }

  /// Check that the client reflects text we just inserted.
  ///
  /// A client that cannot echo back its own committed text cannot be trusted to
  /// describe what precedes the cursor either, so stop asking it and let the
  /// plugin fall back. One mismatch is tolerated: a client may legitimately
  /// transform inserted text (smart quotes, autocorrect).
  private func verifyClientText(inserted: String) {
    guard trustedClientText, !inserted.isEmpty, let client else { return }
    // NSNotFound means the client does not report a cursor position at all (Dia
    // does this). That says nothing about whether the text is right, so it must
    // not count as a mismatch -- otherwise a working client gets disabled on a
    // technicality.
    let cursor = client.selectedRange().location
    guard cursor != NSNotFound else { return }
    let units = inserted.utf16.count
    guard cursor >= units else {
      noteClientTextMismatch()
      return
    }
    let range = NSRange(location: cursor - units, length: units)
    guard client.attributedSubstring(from: range)?.string == inserted else {
      noteClientTextMismatch()
      return
    }
    clientContextFailures = 0
  }

  private func noteClientTextMismatch() {
    clientContextFailures += 1
    guard clientContextFailures >= Self.clientContextFailureLimit else { return }
    trustedClientText = false
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    if let panel = NSApp.bangkeAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    // The plugin reads this from inside process_key (Compose -> translator
    // Query), so it has to be in place before the key goes in.
    publishClientContext()

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
        // Committing changed the document, and the AI pump re-composes later
        // (set_option -> RefreshNonComposition -> Compose), which asks the
        // plugin for the window again. Republish now or that pass reads the
        // pre-commit text.
        publishClientContext()
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // Preserve reserved comment marks when librime requests a UI-only refresh.
  func rimeUpdate(clearReservedComments: Bool = true) {
    if clearReservedComments {
      specialCommentIndices = [:]
    }
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.bangkeAppDelegate.loadSettings(for: schemaId)
        if let panel = NSApp.bangkeAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // Use a full-width space placeholder to prevent iTerm2 from echoing raw preedit;
          // half-width placeholders make the Chinese composition baseline unstable.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      menuCandidateCount = candidates.count
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      menuCandidateCount = 0
      hidePalettes()
    }

    pumpAIPrediction()
  }

  func commit(string: String) {
    guard let client = client else { return }
    let forceMarkedText =
      session != 0 &&
      rimeAPI.get_option(session, "force_marked_text_for_direct_commit")

    // A live marked text has to go before inserting. Well-behaved clients
    // replace the marked range with the inserted string, but the ones that
    // don't commit it *and* insert, so the text lands twice. AI-only mode makes
    // that visible: with `inline_candidate` on, the marked text is the whole
    // prediction, so the client ends up with the whole sentence twice.
    if !preedit.isEmpty {
      client.setMarkedText("",
                           selectionRange: NSRange(location: 0, length: 0),
                           replacementRange: .empty)
      preedit = ""
    }

    // Direct commits such as full-width punctuation do not necessarily have an
    // active marked-text phase. Some NSTextInputClient implementations require
    // one before accepting insertText.
    if forceMarkedText && preedit.isEmpty && !string.isEmpty {
      let markedText = NSMutableAttributedString(string: string)
      client.setMarkedText(
        markedText,
        selectionRange: NSRange(location: markedText.length, length: 0),
        replacementRange: .empty
      )
    }

    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()

    // Read back immediately, before anything else can move the cursor.
    verifyClientText(inserted: string)
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.bangkeAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }

  private func handleASCIIModeToggle(_ notification: Notification) {
    guard let enableASCII = notification.object as? Bool else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    rimeAPI.set_option(session, "ascii_mode", enableASCII)
    rimeUpdate()
  }

  private func reportASCIIMode(_: Notification) {
    guard client != nil else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    let isASCIIMode = rimeAPI.get_option(session, "ascii_mode")
    let status = isASCIIMode ? "ascii" : "nascii"

    DistributedNotificationCenter.default().postNotificationName(
      .init("BangkeASCIIModeResponse"),
      object: status
    )
  }

}
