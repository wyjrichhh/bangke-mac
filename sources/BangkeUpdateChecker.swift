import AppKit
import Combine
import Foundation
import UserNotifications

/// Version notifications only: installation remains an explicit system-installer action.
final class BangkeUpdateChecker: NSObject, ObservableObject, URLSessionTaskDelegate {
  static let automaticKey = "BangkeAutomaticUpdateChecks"
  static let origin = "https://shellim.openbankai.com"
  private var timer: Timer?
  @Published private(set) var checking = false
  private var manualRequested = false
  private let installedVersion: () -> String?
  private let defaults: UserDefaults
  private let configuration: URLSessionConfiguration?
  private let resultHandler: ((CheckResult) -> Void)?
  private lazy var session: URLSession = {
    let config = configuration ?? URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 20
    config.httpCookieStorage = nil
    config.urlCache = nil
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  enum CheckResult {
    case available(current: String, release: Release)
    case upToDate(current: String, latest: String)
    case failed(String)
  }

  init(installedVersion: @escaping () -> String? = {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }, defaults: UserDefaults = .standard, configuration: URLSessionConfiguration? = nil,
       resultHandler: ((CheckResult) -> Void)? = nil) {
    self.installedVersion = installedVersion
    self.defaults = defaults
    self.configuration = configuration
    self.resultHandler = resultHandler
    super.init()
  }

  struct Feed: Decodable {
    let schemaVersion: Int
    let channel: String
    let releases: [String: Release]
  }
  struct Release: Decodable {
    let target: String
    let version: String
    let downloadUrl: String
    let sha256: String
    let notes: String
    var safeURL: URL? {
      guard target == "macos", let url = URL(string: downloadUrl),
            url.scheme == "https", url.host == "shellim.openbankai.com",
            url.port == nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil,
            url.path.range(of: "^/get/(?:BangkePinyin|Squirrel)-[0-9][A-Za-z0-9._-]*\\.pkg$", options: .regularExpression) != nil,
            !url.path.dropFirst(5).contains("/"), !url.path.contains("\\"),
            sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
            BangkeUpdateChecker.versionParts(version) != nil else { return nil }
      return url
    }
  }
  static func versionParts(_ value: String) -> [UInt64]? {
    guard value.count <= 100,
          value.range(of: "^[0-9]+(?:\\.[0-9]+)*(?:-[0-9]+)?$", options: .regularExpression) != nil else { return nil }
    let parts = value.replacingOccurrences(of: "-", with: ".").split(separator: ".")
    let numbers = parts.compactMap { UInt64($0) }
    return numbers.count == parts.count ? numbers : nil
  }
  static func isNewer(_ incoming: String, than current: String) -> Bool {
    guard let a = versionParts(incoming), let b = versionParts(current) else { return false }
    for index in 0..<max(a.count, b.count) {
      let av = index < a.count ? a[index] : 0
      let bv = index < b.count ? b[index] : 0
      if av != bv { return av > bv }
    }
    return false
  }
  static func parse(_ data: Data) throws -> Release {
    guard data.count <= 256 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
    let feed = try JSONDecoder().decode(Feed.self, from: data)
    guard feed.schemaVersion == 1, feed.channel == "stable",
          let release = feed.releases["macos"], release.safeURL != nil else {
      throw URLError(.cannotParseResponse)
    }
    return release
  }
  func start() {
    defaults.register(defaults: [Self.automaticKey: true])
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self else { return }
      self.check(manual: false)
      self.timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
        self?.check(manual: false)
      }
    }
  }
  func check(manual: Bool) {
    if checking {
      // A manual click during an automatic request must still receive its result.
      manualRequested = manualRequested || manual
      return
    }
    let now = Date().timeIntervalSince1970
    if !manual && (!defaults.bool(forKey: Self.automaticKey) ||
       now - defaults.double(forKey: "BangkeUpdateLastSuccess") < 3600 ||
       now - defaults.double(forKey: "BangkeUpdateLastAttempt") < 900) { return }
    guard let current = installedVersion(),
          Self.versionParts(current) != nil else {
      if manual { present(.failed("无法识别当前安装的版本，本次未完成更新检查。")) }
      return
    }
    defaults.set(now, forKey: "BangkeUpdateLastAttempt")
    checking = true
    manualRequested = manual
    let bucket = Int(now / 300)
    var request = URLRequest(url: URL(string: Self.origin + "/updates/v1/stable?t=\(bucket)")!)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("BangkeUpdate/1", forHTTPHeaderField: "User-Agent")
    session.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.checking = false
        let manual = self.manualRequested
        self.manualRequested = false
        guard error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
              let data, let release = try? Self.parse(data) else {
          if manual { self.present(.failed("暂时无法检查更新，请稍后重试。")) }
          return
        }
        self.defaults.set(now, forKey: "BangkeUpdateLastSuccess")
        guard Self.isNewer(release.version, than: current) else {
          if manual { self.present(.upToDate(current: current, latest: release.version)) }
          return
        }
        if !manual && self.defaults.string(forKey: "BangkeUpdateSkipped") == release.version { return }
        if manual {
          self.present(.available(current: current, release: release))
        } else {
          let content = UNMutableNotificationContent()
          content.title = "蚌壳拼音有新版本"
          content.body = "版本 \(release.version) 已发布。点击查看，或到设置 → 关于 → 检查更新。"
          let center = UNUserNotificationCenter.current()
          center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: BangkeApplicationDelegate.updateNotificationIdentifier,
                                             content: content, trigger: nil))
          }
        }
      }
    }.resume()
  }
  static func alert(for result: CheckResult) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "软件更新"
    switch result {
    case let .available(current, release):
      alert.messageText = "蚌壳拼音有新版本"
      alert.informativeText = "当前版本：\(current)\n最新版本：\(release.version)\n\n" +
        String(release.notes.prefix(4000)) + "\n\n下载后使用系统安装器更新，用户配置会保留。"
      alert.addButton(withTitle: "下载最新安装包")
      alert.addButton(withTitle: "稍后提醒")
      alert.addButton(withTitle: "跳过此版本")
    case let .upToDate(current, latest):
      alert.informativeText = "当前已是最新版本，无需下载。\n\n当前版本：\(current)\n官网最新版本：\(latest)"
      alert.addButton(withTitle: "好")
    case let .failed(message):
      alert.informativeText = message
      alert.addButton(withTitle: "好")
    }
    return alert
  }
  func handleResponse(_ response: NSApplication.ModalResponse, to result: CheckResult,
                      openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    guard case let .available(_, release) = result else { return }
    switch response {
    case .alertFirstButtonReturn: if let url = release.safeURL { openURL(url) }
    case .alertThirdButtonReturn: defaults.set(release.version, forKey: "BangkeUpdateSkipped")
    default: break
    }
  }
  private func present(_ result: CheckResult) {
    if let resultHandler { resultHandler(result); return }
    NSApp.activate(ignoringOtherApps: true)
    handleResponse(Self.alert(for: result).runModal(), to: result)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
