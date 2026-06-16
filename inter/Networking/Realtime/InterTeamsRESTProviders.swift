//
//  InterTeamsRESTProviders.swift
//  inter
//
//  Concrete URLSession-backed implementations of the Teams data seams the
//  SwiftUI screen depends on, wired to the token server's /teams REST API via
//  InterTeamsHTTPClient (shared Bearer auth + 401-refresh). The view models that
//  consume these are unit-tested against fakes; these types are thin plumbing
//  that build requests and decode the documented JSON shapes.
//
//    • InterTeamsListRESTProvider    GET /teams · POST /teams
//    • InterTeamMembersRESTProvider  GET /teams/:id · POST/DELETE /teams/:id/members
//    • InterTeamFilesRESTProvider    POST /teams/:id/files · GET …/files/:id/url
//

import Foundation

private let teamsJSONDecoder = JSONDecoder()

private func encodePathComponent(_ s: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")   // never let an id segment inject a path separator
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

private func teamsError(_ message: String) -> NSError {
    NSError(domain: "InterTeamsRESTProvider", code: -1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - Teams list (sidebar)

final class InterTeamsListRESTProvider: InterTeamsListProviding {
    private let http: InterTeamsHTTPClient

    init(serverURL: String, tokenService: InterTokenService) {
        self.http = InterTeamsHTTPClient(serverURL: serverURL, tokenService: tokenService)
    }

    private struct TeamsEnvelope: Decodable { let teams: [InterTeamSummary] }

    func loadTeams(completion: @escaping (Result<[InterTeamSummary], Error>) -> Void) {
        http.requestJSON(method: "GET", path: "/teams", body: nil, idempotencyKey: nil) { result in
            completion(result.flatMap { data in
                guard let env = try? teamsJSONDecoder.decode(TeamsEnvelope.self, from: data) else {
                    return .failure(teamsError("Malformed teams response"))
                }
                return .success(env.teams)
            })
        }
    }

    func createTeam(name: String, description: String?,
                    completion: @escaping (Result<InterTeamSummary, Error>) -> Void) {
        var body: [String: Any] = ["name": name]
        if let description = description, !description.isEmpty { body["description"] = description }
        http.requestJSON(method: "POST", path: "/teams", body: body,
                         idempotencyKey: UUID().uuidString) { result in
            completion(result.flatMap { data in
                guard let team = try? teamsJSONDecoder.decode(InterTeamSummary.self, from: data) else {
                    return .failure(teamsError("Malformed create-team response"))
                }
                return .success(team)
            })
        }
    }
}

// MARK: - Members (manage sheet)

final class InterTeamMembersRESTProvider: InterTeamMembersProviding {
    private let http: InterTeamsHTTPClient

    init(serverURL: String, tokenService: InterTokenService) {
        self.http = InterTeamsHTTPClient(serverURL: serverURL, tokenService: tokenService)
    }

    private struct MembersEnvelope: Decodable {
        let members: [InterTeamMember]
        let callerRole: String?
    }
    private struct MemberEnvelope: Decodable { let member: InterTeamMember }

    func loadMembers(teamId: String,
                     completion: @escaping (Result<(members: [InterTeamMember], callerRole: String), Error>) -> Void) {
        http.requestJSON(method: "GET", path: "/teams/\(encodePathComponent(teamId))",
                         body: nil, idempotencyKey: nil) { result in
            completion(result.flatMap { data in
                guard let env = try? teamsJSONDecoder.decode(MembersEnvelope.self, from: data) else {
                    return .failure(teamsError("Malformed team response"))
                }
                return .success((members: env.members, callerRole: env.callerRole ?? "member"))
            })
        }
    }

    func addMember(teamId: String, email: String,
                   completion: @escaping (Result<InterTeamMember, InterAddMemberError>) -> Void) {
        http.requestJSON(method: "POST", path: "/teams/\(encodePathComponent(teamId))/members",
                         body: ["email": email], idempotencyKey: UUID().uuidString) { result in
            switch result {
            case .success(let data):
                guard let env = try? teamsJSONDecoder.decode(MemberEnvelope.self, from: data) else {
                    completion(.failure(.other("Malformed add-member response"))); return
                }
                completion(.success(env.member))
            case .failure(let error):
                completion(.failure(Self.mapAddError(error)))
            }
        }
    }

    func removeMember(teamId: String, memberId: String,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        http.requestJSON(method: "DELETE",
                         path: "/teams/\(encodePathComponent(teamId))/members/\(encodePathComponent(memberId))",
                         body: nil, idempotencyKey: nil) { result in
            completion(result.map { _ in () })
        }
    }

    private static func mapAddError(_ error: Error) -> InterAddMemberError {
        let ns = error as NSError
        let serverCode = ns.userInfo[InterTeamsHTTPClient.serverCodeKey] as? String
        switch ns.code {
        case 404 where serverCode == "NO_INTER_ACCOUNT": return .noInterAccount
        case 404:                                          return .noInterAccount
        case 403:                                          return .notAuthorized
        case 400:                                          return .invalidEmail
        case 429:                                          return .rateLimited
        default:                                           return .other(ns.localizedDescription)
        }
    }
}

// MARK: - Files (attach / download)

final class InterTeamFilesRESTProvider {
    private let http: InterTeamsHTTPClient

    init(serverURL: String, tokenService: InterTokenService) {
        self.http = InterTeamsHTTPClient(serverURL: serverURL, tokenService: tokenService)
    }

    private struct PresignEnvelope: Decodable {
        let url: String
        let originalName: String?
    }

    /// Server hard cap (multer `TEAM_FILE_MAX_BYTES` in teams.js). Keep in sync.
    private static let maxFileBytes = 25 * 1024 * 1024  // 25 MB

    /// Upload a file to the team. On success the server persists a file message
    /// and fans it out, so the open room renders it via realtime — we only need
    /// to know the upload succeeded (or surface the server's error string).
    func uploadFile(teamId: String, fileURL: URL,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        // Reject oversize files BEFORE reading bytes into memory (matches the server's
        // 25 MB cap) so a too-large file fails fast — no memory spike, no doomed upload.
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.maxFileBytes {
            completion(.failure(teamsError("That file is too large (max 25 MB)."))); return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            completion(.failure(teamsError("Couldn't read the selected file."))); return
        }
        http.uploadFile(path: "/teams/\(encodePathComponent(teamId))/files",
                        fileData: data, filename: fileURL.lastPathComponent,
                        idempotencyKey: UUID().uuidString) { result in
            completion(result.map { _ in () })
        }
    }

    /// Fetch a short-lived presigned download URL for a team file.
    func presignedURL(teamId: String, fileId: String,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        http.requestJSON(method: "GET",
                         path: "/teams/\(encodePathComponent(teamId))/files/\(encodePathComponent(fileId))/url",
                         body: nil, idempotencyKey: nil) { result in
            completion(result.flatMap { data in
                guard let env = try? teamsJSONDecoder.decode(PresignEnvelope.self, from: data),
                      let url = URL(string: env.url) else {
                    return .failure(teamsError("Malformed download-URL response"))
                }
                return .success(url)
            })
        }
    }
}
