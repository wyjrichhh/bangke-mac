//
//  BangkePreferencesWindow.swift
//  Bangke
//

import AppKit
import SwiftUI

final class BangkeSettingsModel: ObservableObject {
  @Published var settings: BangkeSettings
  @Published var errorMessage: String?

  let colorSchemes: [BangkeSettings.NamedOption]
  let fontFamilies: [String]

  /// Set once the user picks a schema in the dropdown. From then on the page
  /// stops following the schema being typed with — that choice was deliberate.
  private var userPickedSchema = false
  private var schemaObserver: NSObjectProtocol?

  deinit {
    if let schemaObserver {
      NotificationCenter.default.removeObserver(schemaObserver)
    }
  }

  init() {
    let loaded = BangkeSettings.load()
    settings = loaded

    // `native` is the app's own "follow the system" pseudo-scheme, injected
    // when the config does not list it: without it the picker could not
    // represent the value the app defaults to.
    var schemes = BangkeSettings.colorSchemes()
    if !schemes.contains(where: { $0.id == "native" }) {
      schemes.insert(BangkeSettings.NamedOption("native", name: NSLocalizedString("System colors", comment: "")), at: 0)
    }
    colorSchemes = schemes

    var families = NSFontManager.shared.availableFontFamilies.sorted()
    if !loaded.appearance.fontFace.isEmpty, !families.contains(loaded.appearance.fontFace) {
      families.insert(loaded.appearance.fontFace, at: 0)
    }
    fontFamilies = families

    // The window is created when it opens and released when it closes, so a
    // schema added or removed in between is picked up by the next load(). While
    // it is open, follow Ctrl+` switches instead of showing a stale schema.
    schemaObserver = NotificationCenter.default.addObserver(
      forName: BangkeApplicationDelegate.schemaChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let schemaID = notification.object as? String else { return }
      self?.followActiveSchema(schemaID)
    }
  }

  private func followActiveSchema(_ schemaID: String) {
    guard !userPickedSchema, settings.aiSchemas.contains(where: { $0.id == schemaID }) else { return }
    settings.selectedAISchema = schemaID
  }

  /// Marks the dropdown as manually driven, so a later schema switch does not
  /// override the pick.
  var schemaSelection: Binding<String> {
    Binding(
      get: { self.settings.selectedAISchema },
      set: {
        self.settings.selectedAISchema = $0
        self.userPickedSchema = true
      }
    )
  }

  /// Two-way binding for whichever schema's AI settings are on screen.
  var aiBinding: Binding<BangkeSettings.AIPredict> {
    Binding(
      get: { self.settings.aiPredict[self.settings.selectedAISchema] ?? BangkeSettings.AIPredict() },
      set: { self.settings.aiPredict[self.settings.selectedAISchema] = $0 }
    )
  }

  /// Resets appearance and behaviour, plus the AI settings of the schema on
  /// screen — the other schemas keep theirs, matching the page's own scope.
  func restoreDefaults() {
    let schemas = settings.aiSchemas
    let selected = settings.selectedAISchema
    settings = BangkeSettings()
    settings.aiSchemas = schemas
    settings.selectedAISchema = selected
    settings.aiPredict = Dictionary(uniqueKeysWithValues: schemas.map { ($0.id, BangkeSettings.AIPredict()) })
  }

  func save() throws -> BangkeSettings.SaveResult {
    try settings.save()
  }
}

// MARK: - Window

final class BangkePreferencesWindowController: NSWindowController, NSWindowDelegate {
  private let model = BangkeSettingsModel()

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("Bangke Settings", comment: "Preferences window title")
    window.titlebarSeparatorStyle = .none
    self.init(window: window)
    window.delegate = self
    window.contentView = NSHostingView(
      rootView: BangkePreferencesView(
        model: model,
        onClose: { [weak self] in
          self?.close()
        }))
    window.center()
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.bangkeAppDelegate.preferencesDidClose()
  }
}

// MARK: - Navigation

private enum SettingsPage: String, CaseIterable {
  case appearance, behavior, aiPrediction, about

  var title: LocalizedStringKey {
    switch self {
    case .appearance: "Appearance"
    case .behavior: "Behavior"
    case .aiPrediction: "AI Prediction"
    case .about: "About"
    }
  }

}

// MARK: - Root view

struct BangkePreferencesView: View {
  @ObservedObject var model: BangkeSettingsModel
  var onClose: () -> Void
  @State private var page: SettingsPage = .appearance

  var body: some View {
    VStack(spacing: 0) {
      navigation
      Divider()
      content.frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      footer
    }
    .frame(minWidth: 1100, minHeight: 720)
    .background(Color(nsColor: BangkePalette.color(.ground)))
    .foregroundStyle(Color(nsColor: BangkePalette.color(.ink)))
    .tint(Color(nsColor: BangkePalette.color(.accent)))
    .font(.system(size: 14))
    .toggleStyle(.switch)
    .buttonStyle(SettingsButtonStyle())
    .alert("Could not save settings", isPresented: isShowingError) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var navigation: some View {
    ZStack {
      HStack {
        Text(Brand.displayName.isEmpty ? "蚌壳拼音" : Brand.displayName).font(.system(size: 18, weight: .semibold))
        Spacer()
      }
      HStack(spacing: 8) {
        ForEach(SettingsPage.allCases, id: \.self) { item in
          Button {
            page = item
          } label: {
            Text(item.title)
              .font(.system(size: 14, weight: .semibold))
              .padding(.horizontal, 18).padding(.vertical, 12)
              .foregroundStyle(Color(nsColor: BangkePalette.color(page == item ? .accent : .muted)))
              .background(
                Color(nsColor: BangkePalette.color(.soft)).opacity(page == item ? 1 : 0),
                in: RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, 28)
    .frame(height: 72)
  }

  @ViewBuilder
  private var content: some View {
    // Each branch gets a fresh identity so the form's scroll position does
    // not carry over between pages.
    switch page {
    case .appearance:
      AppearanceSettingsPage(
        settings: $model.settings,
        colorSchemes: model.colorSchemes,
        fontFamilies: model.fontFamilies
      )
      .id(SettingsPage.appearance)
    case .behavior:
      BehaviorSettingsPage(settings: $model.settings.behavior, previewSettings: model.settings)
        .id(SettingsPage.behavior)
    case .aiPrediction:
      AIPredictSettingsPage(
        settings: model.aiBinding,
        selectedSchema: model.schemaSelection,
        schemas: model.settings.aiSchemas, previewSettings: model.settings
      )
      .id(SettingsPage.aiPrediction)
    case .about:
      AboutSettingsPage()
        .id(SettingsPage.about)
    }
  }

  private var isShowingError: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Restore Defaults") { model.restoreDefaults() }
      Button("Cancel") { onClose() }
        .keyboardShortcut(.cancelAction)
      Button("Save and Apply") { save() }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(SettingsButtonStyle(primary: true))
    }
    .padding(16)
  }

  private func save() {
    do {
      let result = try model.save()
      // Only touch librime if something actually moved. finalize() tears the
      // engine down while the AI plugin's worker thread is running on it, so
      // restarting for a write that changed nothing buys risk for no gain.
      if result.changed {
        if result.needsFullDeployment {
          // Page size and the AI block feed schema compilation, which only a
          // full maintenance pass picks up.
          NSApp.bangkeAppDelegate.deploy()
        } else {
          NSApp.bangkeAppDelegate.reloadSettings()
        }
      }
      onClose()
    } catch {
      model.errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Page header

private struct SettingsPageHeader: View {
  let title: LocalizedStringKey
  var subtitle: LocalizedStringKey?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 23, weight: .bold))
      if let subtitle {
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 30)
    .padding(.top, subtitle == nil ? 24 : 20)
    .padding(.bottom, 20)
  }
}

// MARK: - Appearance

struct AppearanceSettingsPage: View {
  @Binding var settings: BangkeSettings
  let colorSchemes: [BangkeSettings.NamedOption]
  let fontFamilies: [String]

  /// Keep each appearance's measured size so switching themes never scales the preview.
  @State private var advanced = false

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(title: "Appearance")
      HStack(alignment: .top, spacing: 28) {
        form.frame(maxWidth: .infinity, maxHeight: .infinity)
        preview.frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 30)
      .padding(.bottom, 24)
    }
  }

  private var form: some View {
    SettingsForm {
      SettingsSection("Colors and theme") {
        SettingsChoice("Color scheme", selection: $settings.appearance.colorScheme, options: colorSchemes.map { ($0.id, $0.name) })

      }

      SettingsSection("Text and shape") {
        SettingsChoice("Font", selection: $settings.appearance.fontFace, options: fontFamilies.map { ($0, $0) })
        SettingsSlider(title: "Font size", value: $settings.appearance.fontPoint, range: 8...48, step: 1)
        SettingsSlider(title: "Corner radius", value: $settings.appearance.cornerRadius, range: 0...30, step: 1)
        SettingsChoice(
          "Candidate list", selection: $settings.appearance.candidateListLayout,
          options: choices([
            ("stacked", "Stacked"), ("linear", "Linear")
          ]))
      }

      DisclosureGroup("More appearance options", isExpanded: $advanced) {
        VStack(alignment: .leading, spacing: 22) {
          SettingsSection("Color") {
            SettingsChoice(
              "Dark color scheme", selection: $settings.appearance.colorSchemeDark,
              options: [("", NSLocalizedString("Follow light scheme", comment: ""))]
                + colorSchemes.map { ($0.id, $0.name) })
            SettingsSlider(
              title: "Background transparency",
              hint: "1 is fully transparent, 0 is opaque.",
              value: $settings.appearance.transparency, range: 0...1, step: 0.05)
          }
          SettingsSection("Layout") {
            SettingsChoice(
              "Text orientation", selection: $settings.appearance.textOrientation,
              options: choices([
                ("horizontal", "Horizontal"),
                ("vertical", "Vertical")
              ]))
            SettingsSlider(title: "Highlight corner radius", value: $settings.appearance.hilitedCornerRadius, range: 0...30, step: 1)
            SettingsSlider(title: "Line spacing", value: $settings.appearance.lineSpacing, range: -10...30, step: 1)
            SettingsSlider(title: "Preedit spacing", value: $settings.appearance.spacing, range: -10...30, step: 1)
            SettingsSlider(title: "Shadow size", value: $settings.appearance.shadowSize, range: 0...30, step: 1)
            SettingsSlider(title: "Border height", value: $settings.appearance.borderHeight, range: -10...20, step: 1)
            SettingsSlider(title: "Border width", value: $settings.appearance.borderWidth, range: -10...20, step: 1)
          }
          SettingsSection("Display") {
            Toggle("Show preedit in the input field", isOn: $settings.appearance.inlinePreedit)
            Toggle("Show selected candidate in the input field", isOn: $settings.appearance.inlineCandidate)
            Toggle("Translucent background", isOn: $settings.appearance.translucency)
            Toggle("Stack transparent colors", isOn: $settings.appearance.mutualExclusive)
            Toggle("Keep panel near the screen edge", isOn: $settings.appearance.memorizeSize)
            Toggle("Show paging arrows", isOn: $settings.appearance.showPaging)
          }
          SettingsSection("Format") {
            SettingsRow {
              TextField("", text: $settings.appearance.candidateFormat)
                .labelsHidden()
            } label: {
              SettingLabel(
                "Candidate format",
                hint: "Use [label], [candidate] and [comment] as placeholders.")
            }
            SettingsChoice(
              "Status messages", selection: $settings.appearance.statusMessageType,
              options: choices([
                ("long", "Long"),
                ("short", "Short"),
                ("mix", "Mixed")
              ]))
          }
        }
        .padding(.top, 16)
      }
    }
  }

  private var preview: some View { SettingsLivePreview(settings: settings) }

}

// MARK: - Behavior

struct BehaviorSettingsPage: View {
  @Binding var settings: BangkeSettings.Behavior
  let previewSettings: BangkeSettings

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "Behavior",
        subtitle: "Menu bar and typing behavior.")
      HStack(alignment: .top, spacing: 28) {
        form.frame(maxWidth: .infinity, maxHeight: .infinity)
        SettingsLivePreview(settings: previewSettings).frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 30).padding(.bottom, 24)

    }
  }
  private var form: some View {
    SettingsForm {
      SettingsSection("Menu Bar") {
        Toggle("Show status icon in the menu bar", isOn: $settings.showStatusIcon)
        SettingsChoice(
          "Notifications", selection: $settings.notificationsWhen,
          options: choices([
            ("never", "Never"),
            ("appropriate", "When appropriate"),
            ("always", "Always")
          ]))
      }

      SettingsSection("Typing") {
        SettingsSlider(title: "Candidates per page", value: $settings.pageSize, range: 1...20, step: 1)
        SettingsSlider(title: "Chord duration", value: $settings.chordDuration, range: 0...1, step: 0.01)
        SettingsChoice(
          "Left Shift", selection: $settings.shiftLeftAction,
          options: choices([
            ("commit_code", "Commit code"),
            ("commit_text", "Commit text"),
            ("inline_ascii", "Inline ASCII"),
            ("clear", "Clear"),
            ("noop", "Do nothing")
          ]))
        SettingsChoice(
          "Right Shift", selection: $settings.shiftRightAction,
          options: choices([
            ("commit_code", "Commit code"),
            ("commit_text", "Commit text"),
            ("inline_ascii", "Inline ASCII"),
            ("clear", "Clear"),
            ("noop", "Do nothing")
          ]))
      }

      SettingsSection("Keyboard Layout") {
        SettingsRow {
          TextField("", text: $settings.keyboardLayout)
            .labelsHidden()
        } label: {
          SettingLabel(
            "Layout",
            hint: "Use last, default, or a layout name such as com.apple.keylayout.ABC.")
        }
      }
    }
  }
}

// MARK: - AI prediction

struct AIPredictSettingsPage: View {
  @Binding var settings: BangkeSettings.AIPredict
  @Binding var selectedSchema: String
  let schemas: [BangkeSettings.NamedOption]
  let previewSettings: BangkeSettings

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(
        title: "AI Prediction",
        subtitle: "Model predictions for each input method.")
      // 方案选择用分段滑块、且与配置项同处一张卡片: 切换滑块时整卡内容
      // 一起变化, 直观传达「这套配置属于所选方案」。
      HStack(alignment: .top, spacing: 28) {
        form.frame(maxWidth: .infinity, maxHeight: .infinity)
        SettingsLivePreview(settings: previewSettings, aiSettings: settings).frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 30).padding(.bottom, 24)

    }
  }
  private var form: some View {
    SettingsForm {
      SettingsSection {
        SettingsRow {
          SettingsChoice("", selection: $selectedSchema, options: schemas.map { ($0.id, $0.name) })
        } label: {
          SettingLabel("Input method", hint: "Each input method keeps its own AI settings.")
        }

        Toggle("Enable AI prediction", isOn: $settings.enabled)
        Toggle(isOn: $settings.filterPunctuation) {
          SettingLabel(
            "Filter punctuation",
            hint: "Strips the punctuation the model predicts. Turn off to let candidates keep it.")
        }
        Toggle(isOn: $settings.aiOnly) {
          SettingLabel(
            "AI-only candidates",
            hint: "Candidates come from the model alone: no dictionary words, one suggestion with no label.")
        }
        SettingsSlider(
          title: "Candidate position",
          hint: "AI candidates must sit below the search range to appear.",
          value: $settings.targetIndex, range: 0...20, step: 1)
        SettingsSlider(title: "Minimum input length", value: $settings.minInputLength, range: 1...40, step: 1)
        SettingsSlider(title: "Minimum characters", value: $settings.minHanzi, range: 1...10, step: 1)
        SettingsSlider(
          title: "Debounce (ms)",
          hint: "Applies to every input method that has AI prediction wired in.",
          value: $settings.debounceMs, range: 0...2000, step: 20)

        Divider()

        SettingsSlider(title: "Search range", value: $settings.searchRange, range: 1...50, step: 1)
        SettingsSlider(title: "Context window", value: $settings.contextWindowSize, range: 1...50, step: 1)
        SettingsSlider(title: "Minimum context length", value: $settings.minContextPromptLength, range: 1...20, step: 1)
        SettingsSlider(title: "Max tokens", value: $settings.maxTokens, range: 8...512, step: 8)
        SettingsChoice("Device", selection: $settings.device, options: [("cpu", "CPU")])
      }
    }
  }
}

// MARK: - About

struct AboutSettingsPage: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 128, height: 128)
      Text(Brand.displayName).font(.title2).bold()
      Text(versionText).font(.callout).foregroundStyle(.secondary)
      // Hidden until an appcast feed is configured: without SUFeedURL the
      // updater never starts, and the button would only log a warning.
      if BangkeApplicationDelegate.updatesEnabled {
        Button("Check for Updates") { NSApp.bangkeAppDelegate.checkForUpdates() }
      }
      Spacer()
    }
    .padding(.top, 48)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var versionText: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return NSLocalizedString("Version [version] ([build])", comment: "About page version line")
      .replacingOccurrences(of: "[version]", with: info["CFBundleShortVersionString"] as? String ?? "")
      .replacingOccurrences(of: "[build]", with: info[kCFBundleVersionKey as String] as? String ?? "")
  }
}

// MARK: - Rows

/// 表单行的悬停说明: 鼠标停在小问号上显示完整解释, 取代另起一行的
/// caption 文本, 表单更紧凑。
///
/// 系统气泡(SwiftUI .help 与 NSView.toolTip)在输入法的 accessory 进程里
/// 都不显示(实验验证: 普通进程正常), 只有自制气泡可用; 悬停延迟也由此
/// 自控 —— 系统默认约 2s 且不可按 app 调整。
private struct HintIcon: View {
  let hint: String
  @State private var hovering = false
  @State private var showBubble = false

  var body: some View {
    Image(systemName: "questionmark.circle")
      .imageScale(.small)
      .foregroundStyle(.tertiary)
      .padding(3)
      .contentShape(Rectangle())
      .onHover { entered in
        hovering = entered
        if entered {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if hovering { showBubble = true }
          }
        } else {
          showBubble = false
        }
      }
      .overlay(alignment: .bottomLeading) {
        if showBubble {
          Text(NSLocalizedString(hint, comment: ""))
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            .fixedSize()
            .offset(y: 24)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
  }
}

private struct SettingLabel: View {
  let title: LocalizedStringKey
  var hint: String?

  init(_ title: LocalizedStringKey, hint: String? = nil) {
    self.title = title
    self.hint = hint
  }

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
      if let hint {
        HintIcon(hint: hint)
      }
    }
  }
}

struct SettingsSlider: View {
  let title: LocalizedStringKey
  var hint: String?
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double

  var body: some View {
    SettingsRow {
      HStack(spacing: 8) {
        SettingsTrackSlider(value: $value, range: range, step: step)
          .frame(width: 120).accessibilityLabel(title)
        Text(displayValue)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
      .frame(width: 220)
    } label: {
      SettingLabel(title, hint: hint)
    }
  }

  private var displayValue: String {
    step >= 1 ? String(Int(value.rounded())) : String(format: "%.2f", value)
  }
}

extension SettingsSlider {
  init(title: LocalizedStringKey, hint: String? = nil, value: Binding<Int>, range: ClosedRange<Int>, step: Int) {
    self.init(
      title: title,
      hint: hint,
      value: Binding(
        get: { Double(value.wrappedValue) },
        set: { value.wrappedValue = Int($0.rounded()) }),
      range: Double(range.lowerBound)...Double(range.upperBound),
      step: Double(step))
  }
}
