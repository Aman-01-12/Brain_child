//
//  InterTeamsHTTPClient.swift
//  inter
//
//  Small authenticated HTTP helper shared by the Teams REST providers (list,
//  members, files). It builds Bearer-authenticated requests and applies the
//  same 401 → coalesced-refresh → retry-once contract the chat transport uses
//  (via InterTokenService.refreshAccessToken — no duplicated refresh logic).
//  JSON and multipart-upload requests share one auth/refresh path.
//
//  The server-provided `code` (e.g. "NO_INTER_ACCOUNT") and HTTP status are
//  carried on the returned NSError so callers can map precise UI states.
//

import Foundation

final class InterTeamsHTTPClient {

    /// userInfo key carrying the server's machine-readable error `code`.
    static let serverCodeKey = "serverCode"

    private let serverURL: String
    private weak var tokenService: InterTokenService?
    private let session: URLSession

    init(serverURL: String, tokenService: InterTokenService) {
        self.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        self.tokenService = tokenService
        if InterAppConfig.isInsecureRemote(self.serverURL) {
            NSLog("[Teams][security] Bearer tokens would be sent over cleartext to a non-loopback host: %@ — use https.", self.serverURL)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 60.0  // uploads need headroom
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - JSON

    func requestJSON(method: String, path: String, body: [String: Any]?,
                     idempotencyKey: String?,
                     completion: @escaping (Result<Data, Error>) -> Void) {
        perform(makeRequest: { [serverURL] token in
            guard let url = URL(string: serverURL + path) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = method
            if let token = token, !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let key = idempotencyKey {
                req.setValue(key, forHTTPHeaderField: "X-Idempotency-Key")
            }
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            return req
        }, completion: completion)
    }

    // MARK: - Multipart upload (field name "file")

    /// Upload raw bytes as multipart/form-data. The true MIME is re-detected by
    /// the server from magic bytes, so we send application/octet-stream and let
    /// the server's allowlist decide (never trust a client-declared type).
    func uploadFile(path: String, fileData: Data, filename: String,
                    idempotencyKey: String,
                    completion: @escaping (Result<Data, Error>) -> Void) {
        let boundary = "Boundary-\(UUID().uuidString)"
        // Strip control chars (CR/LF, etc.) AND quotes to prevent multipart header
        // injection via a crafted filename, and cap length. The server re-derives the
        // real name/type from magic bytes anyway.
        let safeName = String(
            filename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ).replacingOccurrences(of: "\"", with: "").prefix(200)
        var bodyData = Data()
        let prefix = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        bodyData.append(Data(prefix.utf8))
        bodyData.append(fileData)
        bodyData.append(Data("\r\n--\(boundary)--\r\n".utf8))

        perform(makeRequest: { [serverURL] token in
            guard let url = URL(string: serverURL + path) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            if let token = token, !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            req.setValue(idempotencyKey, forHTTPHeaderField: "X-Idempotency-Key")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
            return req
        }, completion: completion)
    }

    // MARK: - Core: send with 401 → refresh → retry-once

    private func perform(makeRequest: @escaping (_ token: String?) -> URLRequest?,
                         retriedAfterAuth: Bool = false,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        let token = tokenService?.currentAccessToken
        guard let request = makeRequest(token) else {
            completion(.failure(makeError("Invalid request"))); return
        }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                completion(.failure(NSError(domain: "InterTeamsHTTPClient", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "The request was cancelled."])))
                return
            }
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(self.makeError("No response from server"))); return
            }

            if http.statusCode == 401, !retriedAfterAuth, let ts = self.tokenService {
                ts.refreshAccessToken { ok in
                    if ok {
                        self.perform(makeRequest: makeRequest, retriedAfterAuth: true, completion: completion)
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

            // Surface the server's error string + machine code (e.g. NO_INTER_ACCOUNT).
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let serverMsg = json?["error"] as? String
            let serverCode = json?["code"] as? String
            completion(.failure(self.makeError(serverMsg ?? "Server error \(http.statusCode)",
                                               code: http.statusCode, serverCode: serverCode)))
        }.resume()
    }

    private func makeError(_ message: String, code: Int = -1, serverCode: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let serverCode = serverCode { info[InterTeamsHTTPClient.serverCodeKey] = serverCode }
        return NSError(domain: "InterTeamsHTTPClient", code: code, userInfo: info)
    }
}
