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
      schemes.insert(BangkeSettings.NamedOption("native"), at: 0)
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
      set: { self.settings.selectedAISchema = $0; self.userPickedSchema = true }
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
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = NSLocalizedString("Bangke Settings", comment: "Preferences window title")
    window.titlebarSeparatorStyle = .none
    self.init(window: window)
    window.delegate = self
    window.contentView = NSHostingView(rootView: BangkePreferencesView(model: model, onClose: { [weak self] in
      self?.close()
    }))
    window.center()
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.bangkeAppDelegate.preferencesDidClose()
  }
}

// MARK: - Navigation

private enum SettingsPage: String, CaseIterable, Identifiable {
  case appearance, behavior, aiPrediction, about

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .appearance: "Appearance"
    case .behavior: "Behavior"
    case .aiPrediction: "AI Prediction"
    case .about: "About"
    }
  }

  var icon: String {
    switch self {
    case .appearance: "paintpalette"
    case .behavior: "keyboard"
    case .aiPrediction: "sparkles"
    case .about: "info.circle"
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
      HStack(spacing: 0) {
        sidebar
        Divider()
        content
      }
      Divider()
      footer
    }
    .frame(minWidth: 700, minHeight: 620)
    .alert("Could not save settings", isPresented: isShowingError) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  /// Plain Button rows rather than a selection-driven List: List selection
  /// goes through AppKit's text-selection machinery, which is unreliable in a
  /// hand-made NSWindow + NSHostingView inside an accessory-launched app.
  /// Buttons work regardless of how the window became key.
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(SettingsPage.allCases) { item in
        SidebarRow(page: item, isSelected: page == item) { page = item }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(width: 200)
    .background(SidebarBackdrop())
  }

  @ViewBuilder
  private var content: some View {
    // Each branch gets a fresh identity so the form's scroll position does
    // not carry over between pages.
    switch page {
    case .appearance:
      AppearanceSettingsPage(settings: $model.settings,
                             colorSchemes: model.colorSchemes,
                             fontFamilies: model.fontFamilies)
        .id(SettingsPage.appearance)
    case .behavior:
      BehaviorSettingsPage(settings: $model.settings.behavior)
        .id(SettingsPage.behavior)
    case .aiPrediction:
      AIPredictSettingsPage(settings: model.aiBinding,
                            selectedSchema: model.schemaSelection,
                            schemas: model.settings.aiSchemas)
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
      Button("Restore Defaults") { model.restoreDefaults() }
      Spacer()
      Button("Cancel") { onClose() }
        .keyboardShortcut(.cancelAction)
      Button("Save and Apply") { save() }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
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

// MARK: - Sidebar

private struct SidebarRow: View {
  let page: SettingsPage
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: page.icon).imageScale(.medium)
        Text(page.title)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.22) : .clear)
      )
    }
    .buttonStyle(.plain)
  }
}

/// The sidebar's vibrancy panel; SwiftUI has no direct sidebar material.
private struct SidebarBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Page header

private struct SettingsPageHeader: View {
  let title: LocalizedStringKey
  var subtitle: LocalizedStringKey? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.title2).bold()
      if let subtitle {
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.top, subtitle == nil ? 24 : 20)
    .padding(.bottom, 6)
  }
}

// MARK: - Appearance

struct AppearanceSettingsPage: View {
  @Binding var settings: BangkeSettings
  let colorSchemes: [BangkeSettings.NamedOption]
  let fontFamilies: [String]

  /// Measured by each preview canvas and pushed back in; drives that panel's
  /// aspect-fit frame on the next layout pass (see BangkePreviewRepresentable
  /// .onPanelSize). 配色方案可自带布局/排版覆盖键(如冷漠强制水平排列),
  /// 浅深两块的固有形状可能不同, 各测各的, 不能共用一个宽高比。
  @State private var lightSize: CGSize = .zero
  @State private var darkSize: CGSize = .zero

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(title: "Appearance")
      preview
      Divider()
      form
    }
  }

  private var form: some View {
    Form {
      Section("Color") {
        Picker("Color scheme", selection: $settings.appearance.colorScheme) {
          ForEach(colorSchemes) { Text($0.name).tag($0.id) }
        }
        Picker("Dark color scheme", selection: $settings.appearance.colorSchemeDark) {
          Text("Follow light scheme").tag("")
          ForEach(colorSchemes) { Text($0.name).tag($0.id) }
        }
        SettingsSlider(title: "Background transparency",
                       hint: "1 is fully transparent, 0 is opaque.",
                       value: $settings.appearance.transparency, range: 0...1, step: 0.05)
      }

      Section("Font") {
        Picker("Font", selection: $settings.appearance.fontFace) {
          ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
        }
        SettingsSlider(title: "Font size", value: $settings.appearance.fontPoint, range: 8...48, step: 1)
      }

      Section("Layout") {
        Picker("Candidate list", selection: $settings.appearance.candidateListLayout) {
          Text("Stacked").tag("stacked")
          Text("Linear").tag("linear")
        }
        Picker("Text orientation", selection: $settings.appearance.textOrientation) {
          Text("Horizontal").tag("horizontal")
          Text("Vertical").tag("vertical")
        }
        SettingsSlider(title: "Corner radius", value: $settings.appearance.cornerRadius, range: 0...30, step: 1)
        SettingsSlider(title: "Highlight corner radius", value: $settings.appearance.hilitedCornerRadius, range: 0...30, step: 1)
        SettingsSlider(title: "Line spacing", value: $settings.appearance.lineSpacing, range: -10...30, step: 1)
        SettingsSlider(title: "Preedit spacing", value: $settings.appearance.spacing, range: -10...30, step: 1)
        SettingsSlider(title: "Shadow size", value: $settings.appearance.shadowSize, range: 0...30, step: 1)
        SettingsSlider(title: "Border height", value: $settings.appearance.borderHeight, range: -10...20, step: 1)
        SettingsSlider(title: "Border width", value: $settings.appearance.borderWidth, range: -10...20, step: 1)
      }

      Section("Display") {
        Toggle("Show preedit in the input field", isOn: $settings.appearance.inlinePreedit)
        Toggle("Show selected candidate in the input field", isOn: $settings.appearance.inlineCandidate)
        Toggle("Translucent background", isOn: $settings.appearance.translucency)
        Toggle("Stack transparent colors", isOn: $settings.appearance.mutualExclusive)
        Toggle("Keep panel near the screen edge", isOn: $settings.appearance.memorizeSize)
        Toggle("Show paging arrows", isOn: $settings.appearance.showPaging)
      }

      Section("Format") {
        LabeledContent {
          TextField("", text: $settings.appearance.candidateFormat)
            .labelsHidden()
        } label: {
          SettingLabel("Candidate format",
                       hint: "Use [label], [candidate] and [comment] as placeholders.")
        }
        Picker("Status messages", selection: $settings.appearance.statusMessageType) {
          Text("Long").tag("long")
          Text("Short").tag("short")
          Text("Mixed").tag("mix")
        }
      }
    }
    .formStyle(.grouped)
  }

  private var preview: some View {
    VStack(spacing: 8) {
      Text("Preview").font(.caption).foregroundStyle(.secondary)
      // 浅色、深色两块面板, 中间一道直线分界, 整体居中。切分方向随面板形态
      // 自适应: 单行横条上下切分(浅上深下), 多行/竖排左右切分(浅左深右)。
      // 两块各按自身测量值等比缩放并限高; 外框圆角, 两半左上角各标明暗模式。
      ZStack {
        Group {
          if isWidePanel {
            VStack(spacing: 12) {
              previewPanel(dark: false)
              previewPanel(dark: true)
            }
          } else {
            HStack(spacing: 16) {
              previewPanel(dark: false)
              previewPanel(dark: true)
            }
          }
        }
        .frame(maxHeight: 280)
        .frame(maxWidth: .infinity)
        modeLabels
      }
      .background(SplitBackdrop(horizontal: isWidePanel))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      // 固定高度：预览是展示条，不参与和表单的空间谈判。改成定高前，
      // 角标的 maxHeight: .infinity 让整条无限贪高，叠加 layoutPriority(1)
      // 必赢，表单被挤到 0 高——任何触发重排的拖动（如圆角）都会复现。
      .frame(height: 280)
    }
    .padding(16)
    .frame(maxWidth: .infinity)
  }

  /// 两半各占一格, 左上角放模式角标, 与切分方向同步。
  private var modeLabels: some View {
    Group {
      if isWidePanel {
        VStack(spacing: 0) {
          modeLabel("Light").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          modeLabel("Dark").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      } else {
        HStack(spacing: 0) {
          modeLabel("Light").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          modeLabel("Dark").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
    .padding(8)
    .allowsHitTesting(false)
  }

  private func modeLabel(_ key: LocalizedStringKey) -> some View {
    Text(key)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(.thinMaterial, in: Capsule())
  }

  /// 单行横条又宽又矮, 左右并排会被压得很小 —— 上下切分各得全宽。
  private var isWidePanel: Bool {
    lightSize.width > lightSize.height
  }

  private func previewPanel(dark: Bool) -> some View {
    let size = dark ? darkSize : lightSize
    return BangkePreviewRepresentable(settings: settings,
                               dark: dark,
                               onPanelSize: { if dark { darkSize = $0 } else { lightSize = $0 } })
      .aspectRatio(size.width > 0 ? size.width / size.height : 1,
                   contentMode: .fit)
      .frame(maxHeight: 280)
  }

}

/// 预览背板: 浅色/深色两半、中间一道直线分界。背板用固定色号
/// (浅色 C0C0C0 / 深色 696969), 不随系统外观漂移, 两半永远稳定可辨。
/// horizontal = 上浅下深(适合单行横条), 否则左浅右深(适合多行/竖排)。
private struct SplitBackdrop: View {
  var horizontal = false

  var body: some View {
    ZStack {
      if horizontal {
        VStack(spacing: 0) { halves }
        separator.frame(height: 1)
      } else {
        HStack(spacing: 0) { halves }
        separator.frame(width: 1)
      }
    }
  }

  @ViewBuilder private var halves: some View {
    Rectangle().fill(Color(nsColor: Self.resolved(dark: false)))
    Rectangle().fill(Color(nsColor: Self.resolved(dark: true)))
  }

  private var separator: some View {
    Rectangle().fill(Color.primary.opacity(0.2))
  }

  private static func resolved(dark: Bool) -> NSColor {
    let gray = CGFloat((dark ? 0x69 : 0xC0)) / 255
    return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
  }
}

// MARK: - Behavior

struct BehaviorSettingsPage: View {
  @Binding var settings: BangkeSettings.Behavior

  /// Config value paired with the label the picker shows. The value is what
  /// `ascii_composer/switch_key` stores, so only the label is translatable.
  private let shiftActions: [(value: String, label: LocalizedStringKey)] = [
    ("commit_code", "Commit code"),
    ("commit_text", "Commit text"),
    ("inline_ascii", "Inline ASCII"),
    ("clear", "Clear"),
    ("noop", "Do nothing")
  ]

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(title: "Behavior",
                         subtitle: "Menu bar and typing behavior.")
      Form {
        Section("Menu Bar") {
          Toggle("Show status icon in the menu bar", isOn: $settings.showStatusIcon)
          Picker("Notifications", selection: $settings.notificationsWhen) {
            Text("Never").tag("never")
            Text("When appropriate").tag("appropriate")
            Text("Always").tag("always")
          }
        }

        Section("Typing") {
          SettingsSlider(title: "Candidates per page", value: $settings.pageSize, range: 1...20, step: 1)
          SettingsSlider(title: "Chord duration", value: $settings.chordDuration, range: 0...1, step: 0.01)
          Picker("Left Shift", selection: $settings.shiftLeftAction) {
            ForEach(shiftActions, id: \.value) { Text($0.label).tag($0.value) }
          }
          Picker("Right Shift", selection: $settings.shiftRightAction) {
            ForEach(shiftActions, id: \.value) { Text($0.label).tag($0.value) }
          }
        }

        Section("Keyboard Layout") {
          LabeledContent {
            TextField("", text: $settings.keyboardLayout)
              .labelsHidden()
          } label: {
            SettingLabel("Layout",
                         hint: "Use last, default, or a layout name such as com.apple.keylayout.ABC.")
          }
        }
      }
      .formStyle(.grouped)
    }
  }
}

// MARK: - AI prediction

struct AIPredictSettingsPage: View {
  @Binding var settings: BangkeSettings.AIPredict
  @Binding var selectedSchema: String
  let schemas: [BangkeSettings.NamedOption]

  var body: some View {
    VStack(spacing: 0) {
      SettingsPageHeader(title: "AI Prediction",
                         subtitle: "Model predictions for each input method.")
      // 方案选择用分段滑块、且与配置项同处一张卡片: 切换滑块时整卡内容
      // 一起变化, 直观传达「这套配置属于所选方案」。
      Form {
        Section {
          LabeledContent {
            Picker("", selection: $selectedSchema) {
              ForEach(schemas) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .trailing)
          } label: {
            SettingLabel("Input method", hint: "Each input method keeps its own AI settings.")
          }

          Toggle("Enable AI prediction", isOn: $settings.enabled)
          Toggle(isOn: $settings.filterPunctuation) {
            SettingLabel("Filter punctuation",
                         hint: "Strips the punctuation the model predicts. Turn off to let candidates keep it.")
          }
          Toggle(isOn: $settings.aiOnly) {
            SettingLabel("AI-only candidates",
                         hint: "Candidates come from the model alone: no dictionary words, one suggestion with no label.")
          }
          SettingsSlider(title: "Candidate position",
                         hint: "AI candidates must sit below the search range to appear.",
                         value: $settings.targetIndex, range: 0...20, step: 1)
          SettingsSlider(title: "Minimum input length", value: $settings.minInputLength, range: 1...40, step: 1)
          SettingsSlider(title: "Minimum characters", value: $settings.minHanzi, range: 1...10, step: 1)
          SettingsSlider(title: "Debounce (ms)",
                         hint: "Applies to every input method that has AI prediction wired in.",
                         value: $settings.debounceMs, range: 0...2000, step: 20)

          Divider()

          SettingsSlider(title: "Search range", value: $settings.searchRange, range: 1...50, step: 1)
          SettingsSlider(title: "Context window", value: $settings.contextWindowSize, range: 1...50, step: 1)
          SettingsSlider(title: "Minimum context length", value: $settings.minContextPromptLength, range: 1...20, step: 1)
          SettingsSlider(title: "Max tokens", value: $settings.maxTokens, range: 8...512, step: 8)
          Picker("Device", selection: $settings.device) {
            Text("CPU").tag("cpu")
          }
        }
      }
      .formStyle(.grouped)
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
  var hint: String? = nil
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double

  var body: some View {
    LabeledContent {
      HStack(spacing: 8) {
        Slider(value: $value, in: range, step: step)
        Text(displayValue)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
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
    self.init(title: title,
              hint: hint,
              value: Binding(get: { Double(value.wrappedValue) },
                             set: { value.wrappedValue = Int($0.rounded()) }),
              range: Double(range.lowerBound)...Double(range.upperBound),
              step: Double(step))
  }
}
