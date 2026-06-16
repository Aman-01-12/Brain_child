//
//  InterTeamsRESTTransport.swift
//  inter
//
//  Concrete InterTeamsChatTransport backed by URLSession against the token
//  server's /teams REST API. The orchestration that consumes this
//  (InterTeamsChatService) is already unit-tested with a fake transport; this
//  type is the thin plumbing that builds authenticated requests and parses the
//  server's JSON shapes.
//
//  Auth: every request carries the account access token as a Bearer header. On a
//  401 the transport performs ONE coalesced refresh via InterTokenService (the
//  same path the REST/socket layers use — no duplicated refresh logic) and
//  retries once; a second 401 surfaces sessionExpired so the UI can prompt re-login.
//

import Foundation

public final class InterTeamsRESTTransport: InterTeamsChatTransport {

    private let serverURL: String
    private weak var tokenService: InterTokenService?
    private let session: URLSession
    private let iso: ISO8601DateFormatter
    private let messagesPageLimit: Int

    public init(serverURL: String, tokenService: InterTokenService, messagesPageLimit: Int = 50) {
        self.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        self.tokenService = tokenService
        self.messagesPageLimit = messagesPageLimit
        if InterAppConfig.isInsecureRemote(self.serverURL) {
            NSLog("[Teams][security] Bearer tokens would be sent over cleartext to a non-loopback host: %@ — use https.", self.serverURL)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        // pg TIMESTAMPTZ serializes via JSON as toISOString() — always UTC "Z"
        // with millisecond fractional seconds, so this configuration parses it
        // deterministically.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso = f
    }

    // MARK: - InterTeamsChatTransport

    public func loadMessages(teamId: String, before: String?,
                             completion: @escaping (Result<[InterTeamMessage], Error>) -> Void) {
        guard let escaped = teamId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(makeError("Invalid team id"))); return
        }
        var query = "?limit=\(messagesPageLimit)"
        if let before = before, !before.isEmpty,
           let beforeEscaped = before.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&before=\(beforeEscaped)"
        }
        send(method: "GET", path: "/teams/\(escaped)/messages\(query)", body: nil, idempotencyKey: nil) { [weak self] result in
            guard let self = self else { return }
            completion(result.flatMap { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let arr = obj["messages"] as? [[String: Any]] else {
                    return .failure(self.makeError("Malformed messages response"))
                }
                // Drop any individually-malformed row rather than failing the page;
                // the next fetch reconciles. Server returns newest-first; the store
                // re-sorts, so order here doesn't matter.
                let messages = arr.compactMap { InterTeamMessage(serverJSON: $0, iso: self.iso) }
                return .success(messages)
            })
        }
    }

    public func sendMessage(teamId: String, body: String, idempotencyKey: String,
                            completion: @escaping (Result<InterTeamMessage, Error>) -> Void) {
        guard let escaped = teamId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(makeError("Invalid team id"))); return
        }
        send(method: "POST", path: "/teams/\(escaped)/messages",
             body: ["body": body], idempotencyKey: idempotencyKey) { [weak self] result in
            guard let self = self else { return }
            completion(result.flatMap { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      // The persisted row carries our clientKey so the store can
                      // reconcile the optimistic echo with this confirmed message.
                      let message = InterTeamMessage(serverJSON: obj, iso: self.iso, clientKey: idempotencyKey) else {
                    return .failure(self.makeError("Malformed send response"))
                }
                return .success(message)
            })
        }
    }

    public func markRead(teamId: String, messageId: String,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        guard let escaped = teamId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            completion(.failure(makeError("Invalid team id"))); return
        }
        send(method: "POST", path: "/teams/\(escaped)/read",
             body: ["messageId": messageId], idempotencyKey: nil) { result in
            completion(result.map { _ in () })
        }
    }

    // MARK: - Authenticated request with 401 → refresh → retry-once

    private func send(method: String, path: String, body: [String: Any]?,
                      idempotencyKey: String?, retriedAfterAuth: Bool = false,
                      completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: serverURL + path) else {
            completion(.failure(makeError("Invalid URL"))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = tokenService?.currentAccessToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey = idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
        }
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                completion(.failure(NSError(domain: "InterTeamsRESTTransport", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "The request was cancelled."])))
                return
            }
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(self.makeError("No response from server"))); return
            }

            // 401 once → coalesced refresh → retry with the rotated token.
            if http.statusCode == 401, !retriedAfterAuth, let ts = self.tokenService {
                ts.refreshAccessToken { ok in
                    if ok {
                        self.send(method: method, path: path, body: body,
                                  idempotencyKey: idempotencyKey, retriedAfterAuth: true,
                                  completion: completion)
                    } else {
                        completion(.failure(InterNetworkErrorCode.sessionExpired.error(
                            message: "Your session has expired. Please sign in again.")))
                    }
                }
                return
            }

            if (200..<300).contains(http.statusCode) {
                completion(.success(data ?? Data()))
                return
            }

            // Surface the server's error string when present (e.g. 403 not-a-member,
            // 429 rate-limited, 413 too large) so the UI can show something useful.
            let serverMsg = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["error"] as? String
            completion(.failure(self.makeError(serverMsg ?? "Server error \(http.statusCode)", code: http.statusCode)))
        }.resume()
    }

    private func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(domain: "InterTeamsRESTTransport", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
