import Foundation
import SwiftSoup

/// A handle belongs to one execution. Keeping native elements behind JSON
/// avoids exposing Objective-C selectors or native object graphs to scripts.
final class VbookHtmlBridge {
  private var handles: [Int: [Element]] = [:]
  private var nextHandle = 1

  private func save(_ elements: [Element]) throws -> Int {
    guard nextHandle <= 100000, elements.count <= 100000 else {
      throw VbookFailure(code: "EXECUTION_LIMIT", message: "HTML selection limit exceeded.")
    }
    let id = nextHandle; nextHandle += 1; handles[id] = unique(elements); return id
  }

  private func unique(_ elements: [Element]) -> [Element] {
    var seen = Set<ObjectIdentifier>()
    return elements.filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  func perform(_ request: [String: Any]) throws -> Any {
    let op = request["op"] as? String ?? ""
    let args = request["args"] as? [Any] ?? []
    func text(_ index: Int = 0) -> String { index < args.count ? String(describing: args[index]) : "" }
    if op == "parse" {
      let input = text()
      guard input.utf8.count <= 12 * 1024 * 1024 else { throw VbookFailure(code: "EXECUTION_LIMIT", message: "HTML input exceeds limit.") }
      return try save([SwiftSoup.parse(input)])
    }
    if op == "clean" {
      let doc = try SwiftSoup.parse(text())
      try doc.select("script,style,iframe,object,embed").remove()
      let allowed = Set((args.count > 1 ? args[1] as? [String] ?? [] : []).map { $0.lowercased() })
      for node in try doc.select("*").array().reversed() {
        if !allowed.contains(node.tagName().lowercased()) && !["html", "head", "body"].contains(node.tagName().lowercased()) {
          try node.unwrap()
        }
      }
      return try doc.body()?.html() ?? ""
    }
    guard let id = request["handle"] as? Int, let elements = handles[id] else {
      throw VbookFailure(code: "INVALID_HTML_HANDLE", message: "HTML selection no longer exists.")
    }
    switch op {
    case "size": return elements.count
    case "get":
      let index = args.first as? Int ?? -1
      return try save(index >= 0 && index < elements.count ? [elements[index]] : [])
    case "select":
      var selected: [Element] = []
      for item in elements { selected.append(contentsOf: try item.select(text()).array()) }
      return try save(selected)
    case "children": return try save(elements.flatMap { $0.children().array() })
    case "parent": return try save(elements.compactMap { $0.parent() })
    case "next": return try save(elements.compactMap { try $0.nextElementSibling() })
    case "prev": return try save(elements.compactMap { try $0.previousElementSibling() })
    case "text":
      if args.isEmpty { return try elements.map { try $0.text() }.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
      for node in elements { try node.text(text()) }; return NSNull()
    case "ownText": return elements.first?.ownText() ?? ""
    case "html":
      if args.isEmpty { return try elements.map { try $0.html() }.joined(separator: "\n") }
      for node in elements { try node.html(text()) }; return NSNull()
    case "outerHtml": return try elements.map { try $0.outerHtml() }.joined(separator: "\n")
    case "attr":
      if args.count <= 1 { return try elements.first?.attr(text()) ?? "" }
      for node in elements { try node.attr(text(), text(1)) }; return NSNull()
    case "attributes":
      var output: [String: String] = [:]
      for attribute in elements.first?.getAttributes()?.asList() ?? [] { output[attribute.getKey()] = attribute.getValue() }
      return output
    case "remove": for node in elements { try node.remove() }; return NSNull()
    case "removeAttr": for node in elements { try node.removeAttr(text()) }; return NSNull()
    case "tagName":
      if args.isEmpty { return elements.first?.tagName() ?? "" }
      guard text().range(of: "^[a-z][a-z0-9:-]*$", options: [.regularExpression, .caseInsensitive]) != nil else {
        throw VbookFailure(code: "INVALID_HTML_TAG", message: "Invalid tag name.")
      }
      for node in elements { try node.tagName(text()) }; return NSNull()
    default: throw VbookFailure(code: "UNSUPPORTED_CAPABILITY", message: "Unsupported HTML operation: \(op).")
    }
  }
}
