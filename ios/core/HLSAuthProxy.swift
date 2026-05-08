//
//  HLSAuthProxy.swift
//  UnifiedPlayer
//
//  Local 127.0.0.1 HTTP/1.1 proxy used to inject an Authorization header
//  into HLS manifest + segment requests. MobileVLCKit ships with libvlc
//  3.x, whose HTTP access module does not honour `--http-header(s)`, so
//  custom auth headers passed through `media.addOption(":http-header=…")`
//  are silently dropped. We point VLC at this proxy instead, and forward
//  every request to the real origin with the bearer token attached.
//
//  One proxy instance is bound 1:1 to a HybridVideoPlayer; lifecycle is
//  driven by attachMedia / replaceSourceAsync / release.
//

import Foundation
import Network

final class HLSAuthProxy {

  private let queue = DispatchQueue(label: "unified-player.hls-auth-proxy")
  private var listener: NWListener?
  private var session: URLSession
  private var connectionsLock = NSLock()
  private var connections: Set<ObjectIdentifier> = []
  private var connectionRefs: [ObjectIdentifier: NWConnection] = [:]

  /// Cached origin parts. Re-resolved on every request to keep this struct
  /// stateless w.r.t. URL parsing.
  private let originScheme: String
  private let originHost: String
  private let originPort: Int?

  /// Bearer token (token only — we prepend "Bearer " on forward).
  private let bearerToken: String?

  /// Listening port — only valid after `start()` returns successfully.
  private(set) var port: UInt16 = 0

  init(originURL: URL, bearerToken: String?) {
    self.originScheme = originURL.scheme ?? "https"
    self.originHost = originURL.host ?? ""
    self.originPort = originURL.port
    self.bearerToken = bearerToken

    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 30
    cfg.timeoutIntervalForResource = 600
    cfg.httpShouldUsePipelining = true
    cfg.waitsForConnectivity = false
    self.session = URLSession(configuration: cfg)
  }

  deinit {
    stop()
  }

  /// Start the listener and block (briefly) until it's ready, so callers
  /// can read `port` synchronously and hand the localhost URL to VLC.
  func start(timeout: TimeInterval = 2.0) throws {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    let listener = try NWListener(using: parameters, on: .any)

    let semaphore = DispatchSemaphore(value: 0)
    var startError: Error?
    listener.stateUpdateHandler = { [weak listener] state in
      switch state {
      case .ready:
        semaphore.signal()
      case .failed(let err):
        startError = err
        semaphore.signal()
      case .cancelled:
        break
      default:
        break
      }
      _ = listener
    }
    listener.newConnectionHandler = { [weak self] conn in
      self?.handleNewConnection(conn)
    }
    listener.start(queue: queue)

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
      listener.cancel()
      throw NSError(
        domain: "HLSAuthProxy",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "listener start timed out"]
      )
    }
    if let e = startError {
      listener.cancel()
      throw e
    }
    guard let bound = listener.port?.rawValue else {
      listener.cancel()
      throw NSError(
        domain: "HLSAuthProxy",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "no bound port"]
      )
    }
    self.listener = listener
    self.port = bound
  }

  func stop() {
    listener?.cancel()
    listener = nil

    connectionsLock.lock()
    let refs = connectionRefs.values
    connectionRefs.removeAll()
    connections.removeAll()
    connectionsLock.unlock()
    for c in refs { c.cancel() }

    session.invalidateAndCancel()
  }

  // MARK: - Connection handling

  private func track(_ conn: NWConnection) {
    let id = ObjectIdentifier(conn)
    connectionsLock.lock()
    connections.insert(id)
    connectionRefs[id] = conn
    connectionsLock.unlock()
  }

  private func untrack(_ conn: NWConnection) {
    let id = ObjectIdentifier(conn)
    connectionsLock.lock()
    connections.remove(id)
    connectionRefs.removeValue(forKey: id)
    connectionsLock.unlock()
  }

  private func handleNewConnection(_ conn: NWConnection) {
    track(conn)
    conn.stateUpdateHandler = { [weak self, weak conn] state in
      guard let self, let conn else { return }
      switch state {
      case .failed, .cancelled:
        self.untrack(conn)
      default:
        break
      }
    }
    conn.start(queue: queue)
    receiveRequest(conn, accumulated: Data())
  }

  /// Read until we have a full set of HTTP request headers (terminated by
  /// CRLF CRLF). For HLS we only ever forward GET/HEAD, so we do not need
  /// to handle request bodies.
  private func receiveRequest(_ conn: NWConnection, accumulated: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { conn.cancel(); return }
      if error != nil {
        conn.cancel()
        return
      }
      var buf = accumulated
      if let data = data, !data.isEmpty { buf.append(data) }

      let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
      if let range = buf.range(of: terminator) {
        let headBytes = buf.subdata(in: 0..<range.lowerBound)
        self.processRequest(conn, headBytes: headBytes)
        return
      }

      if isComplete || buf.count > 64 * 1024 {
        self.write502(conn, message: "malformed request")
        return
      }
      self.receiveRequest(conn, accumulated: buf)
    }
  }

  private func processRequest(_ conn: NWConnection, headBytes: Data) {
    guard let headStr = String(data: headBytes, encoding: .utf8) else {
      write502(conn, message: "invalid utf8 in request line")
      return
    }
    let lines = headStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      write502(conn, message: "no request line")
      return
    }
    let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2 else {
      write502(conn, message: "bad request line")
      return
    }
    let method = String(parts[0]).uppercased()
    let pathAndQuery = String(parts[1])

    var clientHeaders: [String: String] = [:]
    for raw in lines.dropFirst() {
      if raw.isEmpty { continue }
      guard let colon = raw.firstIndex(of: ":") else { continue }
      let k = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
      let v = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      clientHeaders[k.lowercased()] = v
    }

    var components = URLComponents()
    components.scheme = originScheme
    components.host = originHost
    if let p = originPort { components.port = p }
    if let q = pathAndQuery.firstIndex(of: "?") {
      components.percentEncodedPath = String(pathAndQuery[..<q])
      components.percentEncodedQuery = String(pathAndQuery[pathAndQuery.index(after: q)...])
    } else {
      components.percentEncodedPath = pathAndQuery
    }

    guard let upstreamURL = components.url else {
      write502(conn, message: "bad upstream url")
      return
    }

    var req = URLRequest(url: upstreamURL)
    req.httpMethod = method
    if let token = bearerToken, !token.isEmpty {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    // Forward only the request headers that affect upstream caching/range.
    if let range = clientHeaders["range"] {
      req.setValue(range, forHTTPHeaderField: "Range")
    }
    if let inm = clientHeaders["if-none-match"] {
      req.setValue(inm, forHTTPHeaderField: "If-None-Match")
    }
    if let ims = clientHeaders["if-modified-since"] {
      req.setValue(ims, forHTTPHeaderField: "If-Modified-Since")
    }
    if let ua = clientHeaders["user-agent"] {
      req.setValue(ua, forHTTPHeaderField: "User-Agent")
    }
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let pump = StreamingPump(connection: conn, request: req, ownerQueue: queue) { [weak self] in
      self?.untrack(conn)
    }
    pump.start()
  }

  private func write502(_ conn: NWConnection, message: String) {
    let body = "Bad Gateway: \(message)"
    let head =
      "HTTP/1.1 502 Bad Gateway\r\n"
      + "Content-Type: text/plain; charset=utf-8\r\n"
      + "Content-Length: \(body.utf8.count)\r\n"
      + "Connection: close\r\n\r\n"
      + body
    conn.send(
      content: head.data(using: .utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        self?.untrack(conn)
        conn.cancel()
      }
    )
  }
}

// MARK: - Streaming pump

/// Owns a single upstream URLSessionDataTask and writes the response head
/// + body chunks into the local NWConnection. We give each request its
/// own ephemeral session/delegate so cancellation is straightforward and
/// there are no shared-delegate races.
private final class StreamingPump: NSObject, URLSessionDataDelegate {
  private let connection: NWConnection
  private let request: URLRequest
  private let ownerQueue: DispatchQueue
  private let onFinished: () -> Void

  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var sentHead = false
  private var finished = false

  init(
    connection: NWConnection,
    request: URLRequest,
    ownerQueue: DispatchQueue,
    onFinished: @escaping () -> Void
  ) {
    self.connection = connection
    self.request = request
    self.ownerQueue = ownerQueue
    self.onFinished = onFinished
  }

  func start() {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 30
    cfg.timeoutIntervalForResource = 600
    cfg.httpShouldUsePipelining = true
    let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    self.session = s
    let t = s.dataTask(with: request)
    self.task = t
    t.resume()
  }

  // MARK: URLSessionDataDelegate

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      writeError(status: 502, message: "non-http upstream response")
      completionHandler(.cancel)
      return
    }
    var head =
      "HTTP/1.1 \(http.statusCode) "
      + HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
      + "\r\n"
    for (rawKey, rawValue) in http.allHeaderFields {
      let k = "\(rawKey)"
      let lower = k.lowercased()
      // Strip hop-by-hop headers and content-encoding (we requested identity).
      if [
        "transfer-encoding", "connection", "keep-alive", "upgrade",
        "proxy-authenticate", "proxy-authorization", "te", "trailers",
        "content-encoding",
      ].contains(lower) {
        continue
      }
      head += "\(k): \(rawValue)\r\n"
    }
    head += "Connection: close\r\n\r\n"
    sentHead = true
    connection.send(
      content: head.data(using: .utf8),
      completion: .contentProcessed { [weak self] err in
        if err != nil { self?.cancelAll() }
      }
    )
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] err in
        if err != nil { self?.cancelAll() }
      }
    )
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let _ = error, !sentHead {
      writeError(status: 502, message: "upstream error")
      return
    }
    finalizeAndClose()
  }

  // MARK: - Helpers

  private func writeError(status: Int, message: String) {
    guard !finished else { return }
    finished = true
    if sentHead {
      // Headers already gone — best we can do is hang up.
      cancelAll()
      return
    }
    let body = message
    let head =
      "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
      + "Content-Type: text/plain; charset=utf-8\r\n"
      + "Content-Length: \(body.utf8.count)\r\n"
      + "Connection: close\r\n\r\n"
      + body
    connection.send(
      content: head.data(using: .utf8),
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        self?.cancelAll()
      }
    )
  }

  private func finalizeAndClose() {
    guard !finished else { return }
    finished = true
    connection.send(
      content: nil,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        self?.cancelAll()
      }
    )
  }

  private func cancelAll() {
    task?.cancel()
    session?.invalidateAndCancel()
    connection.cancel()
    onFinished()
  }
}
