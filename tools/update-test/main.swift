import Foundation
import AppKit
final class BangkeApplicationDelegate { static let updateNotificationIdentifier = "test" }
func require(_ ok: Bool) { if !ok { fatalError("update regression failed") } }
require(BangkeUpdateChecker.isNewer("0.1.10", than: "0.1.9"))
require(!BangkeUpdateChecker.isNewer("0.1.9", than: "0.1.10"))
require(!BangkeUpdateChecker.isNewer("1.0", than: "1.0.0"))
require(BangkeUpdateChecker.versionParts("1.2evil") == nil)
let fixture: [String: Any] = ["schemaVersion": 1, "channel": "stable", "releases": ["macos": ["target": "macos", "version": "0.1.10", "downloadUrl": "https://shellim.openbankai.com/get/BangkePinyin-0.1.10.pkg", "sha256": String(repeating: "a", count: 64), "notes": "test"]]]
let good = try JSONSerialization.data(withJSONObject: fixture)
require((try BangkeUpdateChecker.parse(good)).version == "0.1.10")
let unsafe = String(data: good, encoding: .utf8)!.replacingOccurrences(of: "shellim.openbankai.com", with: "evil.example").data(using: .utf8)!
require((try? BangkeUpdateChecker.parse(unsafe)) == nil)
print("PASS macOS numeric versions, downgrade protection and trusted release links")

final class MockProtocol: URLProtocol {
  static var body = good
  static var failure = false
  static var requests = 0
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests += 1
    if Self.failure { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
let suite = "BangkeUpdateTest-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [MockProtocol.self]
var results: [BangkeUpdateChecker.CheckResult] = []
let checker = BangkeUpdateChecker(installedVersion: { "0.1.9" }, defaults: defaults,
  configuration: configuration, resultHandler: { results.append($0) })
func finish() {
  let deadline = Date().addingTimeInterval(3)
  while checker.checking && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
  require(!checker.checking)
}
defaults.set(false, forKey: BangkeUpdateChecker.automaticKey)
defaults.set(Date().timeIntervalSince1970, forKey: "BangkeUpdateLastSuccess")
defaults.set("0.1.10", forKey: "BangkeUpdateSkipped")
checker.check(manual: false)
require(MockProtocol.requests == 0)
checker.check(manual: true)
require(checker.checking)
finish()
require(MockProtocol.requests == 1 && results.count == 1)
guard case let .available(current, release) = results[0] else { fatalError("missing update") }
require(current == "0.1.9" && release.version == "0.1.10")
let alert = BangkeUpdateChecker.alert(for: results[0])
require(alert.buttons.first?.title == "下载最新安装包")
require(alert.informativeText.contains("0.1.9") && alert.informativeText.contains("0.1.10"))
var opened: URL?
checker.handleResponse(.alertFirstButtonReturn, to: results[0], openURL: { opened = $0 })
require(opened == release.safeURL)
checker.handleResponse(.alertThirdButtonReturn, to: results[0])
require(defaults.string(forKey: "BangkeUpdateSkipped") == "0.1.10")
checker.check(manual: true)
finish()
require(MockProtocol.requests == 2 && results.count == 2)
MockProtocol.body = String(data: good, encoding: .utf8)!.replacingOccurrences(of: "0.1.10", with: "0.1.8").data(using: .utf8)!
checker.check(manual: true)
finish()
guard case let .upToDate(currentVersion, latest) = results.last! else { fatalError("missing no-update result") }
require(currentVersion == "0.1.9" && latest == "0.1.8")
let latestAlert = BangkeUpdateChecker.alert(for: results.last!)
require(latestAlert.buttons.count == 1 && latestAlert.informativeText.contains("无需下载"))
MockProtocol.failure = true
checker.check(manual: true)
finish()
guard case .failed = results.last! else { fatalError("network failure reported incorrectly") }
MockProtocol.failure = false
MockProtocol.body = good
defaults.set(true, forKey: BangkeUpdateChecker.automaticKey)
defaults.removeObject(forKey: "BangkeUpdateLastSuccess")
defaults.removeObject(forKey: "BangkeUpdateLastAttempt")
let previous = results.count
checker.check(manual: false)
checker.check(manual: true)
finish()
require(results.count == previous + 1)
guard case .available = results.last! else { fatalError("manual request during automatic check lost") }
print("PASS manual checks, repeated queries, versions, download action, failure and in-flight requests")

if CommandLine.arguments.contains("--live") {
  let semaphore = DispatchSemaphore(value: 0)
  URLSession.shared.dataTask(with: URL(string: BangkeUpdateChecker.origin + "/updates/v1/stable")!) { data, response, error in
    require(error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
    require(data.flatMap { try? BangkeUpdateChecker.parse($0) } != nil)
    print("PASS macOS HTTPS update endpoint")
    semaphore.signal()
  }.resume()
  require(semaphore.wait(timeout: .now() + 25) == .success)
}
