import Flutter
import Foundation
import CoreFoundation
import JavaScriptCore
import Security
import CryptoKit

public final class VbookRuntimePlugin: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "dev.tachibooks.vbook-runtime", qos: .userInitiated)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dev.tachibooks/vbook_runtime", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VbookRuntimePlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "health" {
      result(["engine": "vbook", "runtime": "iOS JavaScriptCore", "version": "0.1.0",
        "capabilities": ["original-plaintext-zip", "synchronous-http", "html-selectors", "local-script-load", "static-config", "localStorage", "crypto-js-4.2.0", "secure-random"],
        "limitations": ["Encrypted script containers, browser and newer native APIs are unsupported; stock CryptoJS has no AES-GCM mode.",
          "JavaScriptCore has no public per-evaluation CPU termination API; install trusted scripts only."]])
      return
    }
    guard call.method == "execute" else { result(FlutterMethodNotImplemented); return }
    guard let payload = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_REQUEST", message: "Expected an execution object.", details: nil)); return
    }
    worker.async {
      do {
        let value = try VbookScriptEngine().execute(payload)
        DispatchQueue.main.async { result(value) }
      } catch let error as VbookFailure {
        DispatchQueue.main.async { result(FlutterError(code: error.code, message: error.message, details: nil)) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "SCRIPT_FAILED", message: "Extension execution failed.", details: nil)) }
      }
    }
  }
}

public struct VbookFailure: Error {
  public let code: String
  public let message: String
}

/// Each invocation creates an isolated context on the plugin's serial worker.
/// No JIT entitlement, private JSC API, modified app binary, or companion is used.
public final class VbookScriptEngine {
  public init() {}

  public func execute(_ payload: [String: Any], hostSource: String? = nil,
                      fetchOverride: (([String: Any]) throws -> [String: Any])? = nil) throws -> [String: Any] {
    let encoded = try JSONSerialization.data(withJSONObject: payload)
    guard encoded.count <= 80 * 1024 * 1024,
      let manifest = payload["manifest"] as? [String: Any],
      let metadata = manifest["metadata"] as? [String: Any],
      let base = metadata["source"] as? String,
      let scripts = payload["scripts"] as? [String: String], scripts.count <= 512 else {
      throw VbookFailure(code: "INVALID_REQUEST", message: "Invalid or oversized execution payload.")
    }
    guard let context = JSContext() else {
      throw VbookFailure(code: "ENGINE_UNAVAILABLE", message: "JavaScriptCore is unavailable.")
    }
    var failure: VbookFailure?
    context.exceptionHandler = { _, exception in
      let reported = exception?.objectForKeyedSubscript("code")?.toString() ?? ""
      let code = reported.isEmpty || reported == "undefined" || reported == "null" ? "SCRIPT_FAILED" : reported
      failure = VbookFailure(code: code,
        message: String((exception?.toString() ?? "Extension script failed.").prefix(600)))
    }
    let html = VbookHtmlBridge()
    let fetch = VbookFetch(base: base)
    func binding(_ name: String, operation: @escaping ([String: Any]) throws -> Any) {
      let block: @convention(block) (String) -> String = { input in
        do {
          guard let bytes = input.data(using: .utf8), bytes.count <= 16 * 1024 * 1024,
            let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw VbookFailure(code: "INVALID_REQUEST", message: "Invalid host request.")
          }
          let value = try operation(request)
          return String(data: try JSONSerialization.data(withJSONObject: ["value": value], options: [.fragmentsAllowed]), encoding: .utf8)!
        } catch let error as VbookFailure {
          return Self.errorJson(error)
        } catch {
          return Self.errorJson(VbookFailure(code: "HOST_OPERATION_FAILED", message: "HTML or HTTP host operation failed."))
        }
      }
      context.setObject(block, forKeyedSubscript: name as NSString)
    }
    binding("__nativeHtml", operation: html.perform)
    binding("__nativeFetch") { request in
      if let override = fetchOverride { return try override(request) }
      return try fetch.perform(request)
    }
    binding("__nativeDecode") { request in
      guard let text = request["base64"] as? String, let bytes = Data(base64Encoded: text) else {
        throw VbookFailure(code: "INVALID_ENCODING", message: "Invalid response bytes.")
      }
      let charset = (request["charset"] as? String ?? "utf-8").lowercased()
      let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
      guard cf != kCFStringEncodingInvalidId,
        let decoded = String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) else {
        throw VbookFailure(code: "UNSUPPORTED_CAPABILITY", message: "Unsupported or invalid text charset: \(charset).")
      }
      return decoded
    }
    binding("__nativeSleep") { request in
      let seconds = min(5, max(0, (request["milliseconds"] as? Double ?? 0) / 1000))
      try fetch.checkDeadline()
      Thread.sleep(forTimeInterval: seconds)
      try fetch.checkDeadline()
      return NSNull()
    }
    binding("__nativeRandom") { request in
      guard let count = request["bytes"] as? Int, count > 0, count <= 65536 else {
        throw VbookFailure(code: "INVALID_REQUEST", message: "Số byte ngẫu nhiên không hợp lệ.")
      }
      var bytes = [UInt8](repeating: 0, count: count)
      let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
      }
      guard status == errSecSuccess else {
        throw VbookFailure(code: "CRYPTO_RANDOM_FAILED", message: "Không tạo được byte ngẫu nhiên an toàn.")
      }
      return bytes.map { Int($0) }
    }
    func resource(_ name: String) throws -> URL {
      let url = [Bundle(for: VbookRuntimePlugin.self), Bundle.main].compactMap { owner -> URL? in
        guard let bundleURL = owner.url(forResource: "VbookRuntime", withExtension: "bundle"),
          let bundle = Bundle(url: bundleURL) else { return nil }
        return bundle.url(forResource: name, withExtension: "js")
      }.first
      guard let url = url else {
        throw VbookFailure(code: "ENGINE_RESOURCE_MISSING", message: "Thiếu tài nguyên runtime vBook.")
      }
      return url
    }
    context.evaluateScript("""
      (function(global) {
        global.crypto = {getRandomValues:function(array) {
          if (!array || !array.buffer || !/^(?:Uint|Int)(?:8|16|32)(?:Clamped)?Array$/.test(array.constructor.name) || array.byteLength > 65536) throw new Error('Invalid random byte request');
          if (array.byteLength === 0) return array;
          var result = JSON.parse(__nativeRandom(JSON.stringify({bytes:array.byteLength})));
          if (result.error) throw new Error('Secure random is unavailable');
          var view = new Uint8Array(array.buffer,array.byteOffset,array.byteLength);
          view.set(result.value);
          return array;
        }};
      })(this);
      """)
    let cryptoBytes = try Data(contentsOf: resource("crypto-js"))
    let cryptoHash = SHA256.hash(data: cryptoBytes).map { String(format: "%02x", $0) }.joined()
    guard cryptoHash == "ee02257ffbaf0a9b481c7039b0f3bb20c360c9674fe4be8b38ae709b2ea59bbe",
      let cryptoSource = String(data: cryptoBytes, encoding: .utf8) else {
      throw VbookFailure(code: "ENGINE_RESOURCE_INVALID", message: "Thư viện CryptoJS không khớp mã kiểm tra.")
    }
    context.evaluateScript(cryptoSource)
    if let error = failure { throw error }
    let source: String
    if let host = hostSource { source = host }
    else {
      source = try String(contentsOf: resource("host"), encoding: .utf8)
    }
    context.evaluateScript(source)
    if let error = failure { throw error }
    context.setObject(payload, forKeyedSubscript: "__vbookPayload" as NSString)
    let result = context.evaluateScript("__runVbook(__vbookPayload)")
    if let error = failure { throw error }
    try fetch.checkDeadline()
    if fetch.requestCount > 0 && fetch.successfulRequests == 0 && fetchOverride == nil {
      throw VbookFailure(code: "UPSTREAM_UNAVAILABLE", message: fetch.lastFailure)
    }
    guard let raw = result?.toString(), let bytes = raw.data(using: .utf8), bytes.count <= 16 * 1024 * 1024,
      let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw VbookFailure(code: "INVALID_SCRIPT_RESPONSE", message: "Extension returned invalid JSON.")
    }
    return value
  }

  private static func errorJson(_ error: VbookFailure) -> String {
    let value: [String: Any] = ["error": ["code": error.code, "message": error.message]]
    return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
  }
}
