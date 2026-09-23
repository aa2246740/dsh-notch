import Foundation

struct RuntimeFile: Decodable {
  var origin: String
  var token: String
}

struct NotchOption: Decodable, Identifiable {
  var label: String
  var description: String?
  var id: String { label }
}

struct NotchQuestion: Decodable, Identifiable {
  var id: String
  var question: String
  var detail: String?
  var header: String?
  var options: [NotchOption]?
  var multiSelect: Bool?
}

struct NotchApproval: Decodable {
  var id: String
  var toolName: String
  var reason: String?
}

struct NotchAsk: Decodable {
  var id: String
  var questions: [NotchQuestion]
}

struct NotchLastTurn: Decodable {
  var at: Double
  var kind: String
  var failed: Bool
}

struct NotchAttentionKey: Hashable {
  enum Kind: Hashable {
    case approval(String), question(String), completed(Double?), failed(Double?)
  }
  let sessionID: String
  let kind: Kind
}

struct NotchRow: Decodable, Identifiable {
  var id: String
  var title: String
  var child: Bool
  var busy: Bool
  var unread: Bool
  var lastTurn: NotchLastTurn?
  var approval: NotchApproval?
  var ask: NotchAsk?

  var needsAction: Bool { approval != nil || ask != nil }
  /// A red lamp is a finished unsuccessful turn, never a session that is still running.
  var isFailedResult: Bool { lastTurn?.failed == true && !busy && !needsAction }

  var attentionKey: NotchAttentionKey? {
    if let approval { return NotchAttentionKey(sessionID:id,kind:.approval(approval.id)) }
    if let ask { return NotchAttentionKey(sessionID:id,kind:.question(ask.id)) }
    if isFailedResult { return NotchAttentionKey(sessionID:id,kind:.failed(lastTurn?.at)) }
    if unread && !busy { return NotchAttentionKey(sessionID:id,kind:.completed(lastTurn?.at)) }
    return nil
  }
}

struct NotchSnapshot: Decodable {
  var ok: Bool
  var generatedAt: Double
  var origin: String
  var rows: [NotchRow]
}

enum NotchClientError: Error {
  case noRuntime
  case http(Int)
}

final class NotchClient: @unchecked Sendable {
  private var origin = ""
  private var token = ""

  func reloadRuntime() throws {
    let url = ProcessInfo.processInfo.environment["DSH_NOTCH_RUNTIME_FILE"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/dsh-notch/runtime.json")
    let data = try Data(contentsOf: url)
    let file = try JSONDecoder().decode(RuntimeFile.self, from: data)
    origin = file.origin
    token = file.token
  }

  func status() async throws -> NotchSnapshot {
    try reloadRuntime()
    return try await get("/dsh-notch/status")
  }

  func approve(id: String, outcome: String) async throws {
    try await post("/dsh-notch/approve", body: ["id": id, "outcome": outcome])
  }

  @MainActor
  func answer(id: String, answers: [[String: Any]]) async throws {
    try await postJSON("/dsh-notch/answer", payload: ["id": id, "answers": answers])
  }

  func seen(sessionId: String) async throws {
    try await post("/dsh-notch/seen", body: ["sessionId": sessionId])
  }

  func seenAll() async throws {
    try await postJSON("/dsh-notch/seen", payload: ["all": true])
  }

  func focus(sessionId: String) async throws {
    try await post("/dsh-notch/focus", body: ["sessionId": sessionId])
  }

  private func get(_ path: String) async throws -> NotchSnapshot {
    var request = try makeRequest(path)
    request.httpMethod = "GET"
    let (data, response) = try await URLSession.shared.data(for: request)
    try throwIfBad(response)
    return try JSONDecoder().decode(NotchSnapshot.self, from: data)
  }

  private func post(_ path: String, body: [String: String]) async throws {
    try await postJSON(path, payload: body)
  }

  private func postJSON(_ path: String, payload: [String: Any]) async throws {
    var request = try makeRequest(path)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (_, response) = try await URLSession.shared.data(for: request)
    try throwIfBad(response)
  }

  private func makeRequest(_ path: String) throws -> URLRequest {
    if origin.isEmpty { try reloadRuntime() }
    guard let url = URL(string: origin + path) else { throw NotchClientError.noRuntime }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func throwIfBad(_ response: URLResponse) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status < 200 || status >= 300 { throw NotchClientError.http(status) }
  }
}
