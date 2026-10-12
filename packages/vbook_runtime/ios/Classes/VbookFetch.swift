import Foundation

final class VbookFetch {
  private let base: URL?
  private let deadline = Date().addingTimeInterval(20)
  private var downloadedBytes = 0
  private(set) var requestCount = 0
  private(set) var successfulRequests = 0
  private(set) var lastFailure = "All extension HTTP requests failed."

  init(base: String) { self.base = URL(string: base) }

  func checkDeadline() throws {
    if Date() >= deadline { throw VbookFailure(code: "SCRIPT_TIMEOUT", message: "Extension exceeded its execution deadline.") }
  }

  static func httpURL(_ value: String, base: URL? = nil) throws -> URL {
    guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
      throw VbookFailure(code: "INVALID_URL", message: "Expected an HTTP(S) URL without credentials.")
    }
    return url
  }

  func perform(_ input: [String: Any]) throws -> [String: Any] {
    try checkDeadline()
    requestCount += 1
    guard requestCount <= 50 else { throw VbookFailure(code: "EXECUTION_LIMIT", message: "Too many HTTP requests.") }
    let options = input["options"] as? [String: Any] ?? [:]
    let url = try Self.httpURL(input["url"] as? String ?? "", base: base)
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
      throw VbookFailure(code: "INVALID_URL", message: "Cannot parse request URL.")
    }
    if let queries = options["queries"] as? [String: Any] {
      var items = components.queryItems ?? []
      for (name, value) in queries {
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: String(describing: value)))
      }
      components.queryItems = items
    }
    guard let target = components.url else { throw VbookFailure(code: "INVALID_URL", message: "Invalid query URL.") }
    let milliseconds = options["timeout"] as? Double ?? 10000
    let timeout = min(min(10, max(0.001, milliseconds / 1000)), max(0.001, deadline.timeIntervalSinceNow))
    var request = URLRequest(url: target, timeoutInterval: timeout)
    request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let headers = options["headers"] as? [String: Any] {
      for (name, value) in headers { request.setValue(String(describing: value), forHTTPHeaderField: name) }
    }
    if !["GET", "HEAD"].contains(request.httpMethod ?? "GET"), let body = options["body"], !(body is NSNull) {
      if let binary = body as? [String: Any], binary["_isBlob"] as? Bool == true {
        guard let data = Data(base64Encoded: binary["_base64"] as? String ?? "") else {
          throw VbookFailure(code: "INVALID_HTTP_BODY", message: "Invalid binary body.")
        }
        request.httpBody = data
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
          request.setValue(binary["type"] as? String ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
      } else if let form = body as? [String: Any] {
        var pairs: [String] = []
        for (name, value) in form {
          if value is [Any] || value is [String: Any] { throw VbookFailure(code: "INVALID_HTTP_BODY", message: "Form body must contain flat values.") }
          let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*-._"))
          let key = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
          let text = String(describing: value).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
          pairs.append("\(key)=\(text)")
        }
        request.httpBody = pairs.joined(separator: "&").data(using: .utf8)
        if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
      } else { request.httpBody = String(describing: body).data(using: .utf8) }
      if (request.httpBody?.count ?? 0) > 12 * 1024 * 1024 {
        throw VbookFailure(code: "EXECUTION_LIMIT", message: "Request body exceeds limit.")
      }
    }
    let operation = VbookHTTPTransfer(request: request, timeout: timeout)
    operation.start()
    let (response, bytes, failure) = operation.wait()
    try checkDeadline()
    downloadedBytes += bytes.count
    guard downloadedBytes <= 32 * 1024 * 1024 else { throw VbookFailure(code: "EXECUTION_LIMIT", message: "Execution HTTP bytes exceed limit.") }
    if let error = failure as? VbookFailure { throw error }
    let status = failure == nil ? response?.statusCode ?? 504 : 504
    if (200..<300).contains(status) { successfulRequests += 1 }
    else { lastFailure = "HTTP \(status) from \(target.host ?? "source")." }
    var headers: [String: String] = [:]
    for (name, value) in response?.allHeaderFields ?? [:] { headers[String(describing: name).lowercased()] = String(describing: value) }
    return ["status": status, "statusText": HTTPURLResponse.localizedString(forStatusCode: status),
      "ok": (200..<300).contains(status), "url": response?.url?.absoluteString ?? target.absoluteString,
      "headers": headers, "charset": response?.textEncodingName ?? "utf-8", "base64Data": failure == nil ? bytes.base64EncodedString() : "",
      "request": ["url": target.absoluteString, "headers": request.allHTTPHeaderFields ?? [:]]]
  }
}

/// URLSession callbacks run on their own serial delegate queue; the JSC worker
/// blocks only on this semaphore. Data is rejected before a giant response can
/// accumulate in memory, and every redirect is validated again.
private final class VbookHTTPTransfer: NSObject, URLSessionDataDelegate {
  private let request: URLRequest
  private let timeout: TimeInterval
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var bytes = Data()
  private var response: HTTPURLResponse?
  private var failure: Error?
  private var redirects = 0
  private var finished = false
  private var session: URLSession?
  private var task: URLSessionDataTask?

  init(request: URLRequest, timeout: TimeInterval) { self.request = request; self.timeout = timeout; super.init() }

  func start() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    self.session = session
    let task = session.dataTask(with: request); self.task = task; task.resume()
  }

  func wait() -> (HTTPURLResponse?, Data, Error?) {
    if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
      task?.cancel()
      complete(URLError(.timedOut))
    }
    lock.lock(); let result = (response, bytes, failure); lock.unlock()
    session?.invalidateAndCancel()
    return result
  }

  private func complete(_ error: Error?) {
    lock.lock()
    if finished { lock.unlock(); return }
    finished = true
    if failure == nil { failure = error }
    lock.unlock(); semaphore.signal()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    lock.lock(); self.response = response as? HTTPURLResponse; lock.unlock()
    if response.expectedContentLength > 12 * 1024 * 1024 {
      complete(VbookFailure(code: "EXECUTION_LIMIT", message: "HTTP response exceeds limit.")); completionHandler(.cancel)
    } else { completionHandler(.allow) }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    if finished { lock.unlock(); return }
    if bytes.count + data.count > 12 * 1024 * 1024 {
      lock.unlock(); dataTask.cancel(); complete(VbookFailure(code: "EXECUTION_LIMIT", message: "HTTP response exceeds limit.")); return
    }
    bytes.append(data); lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { complete(error) }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    redirects += 1
    do {
      guard redirects <= 10 else { throw VbookFailure(code: "EXECUTION_LIMIT", message: "Too many HTTP redirects.") }
      _ = try VbookFetch.httpURL(request.url?.absoluteString ?? "")
      completionHandler(request)
    } catch { complete(error); completionHandler(nil) }
  }
}
