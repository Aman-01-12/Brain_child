//
//  InterRealtimeLiveSpikeTests.swift
//  interTests
//
//  Decision-council day-3 LIVE round-trip gate for transport B1: the real
//  SocketIORealtimeClient must (1) complete a JWT handshake against the running
//  /teams namespace, (2) join a team room, and (3) receive a `team:message`
//  fanned out by the server after a REST write — proving the end-to-end Swift
//  path, not just compilation.
//
//  This is an INTEGRATION spike, not a unit test: it needs the token server
//  running plus a seeded team + JWT, injected via environment variables. When
//  those are absent the test SKIPS, so it never breaks the normal `xcodebuild
//  test` suite. Drive it with (see token-server/test/spikeSeed.js):
//      TEST_RUNNER_INTER_SPIKE_BASE_URL, TEST_RUNNER_INTER_SPIKE_JWT,
//      TEST_RUNNER_INTER_SPIKE_TEAM_ID
//  (xcodebuild strips the TEST_RUNNER_ prefix when forwarding into the runner.)
//

import XCTest
@testable import inter

final class InterRealtimeLiveSpikeTests: XCTestCase {

    private func env(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty == false) ? v : nil
    }

    func testLiveTeamMessageRoundTrip() throws {
        guard let baseURLString = env("INTER_SPIKE_BASE_URL"),
              let jwt = env("INTER_SPIKE_JWT"),
              let teamId = env("INTER_SPIKE_TEAM_ID"),
              let baseURL = URL(string: baseURLString) else {
            throw XCTSkip("Live spike env not set (INTER_SPIKE_BASE_URL / _JWT / _TEAM_ID) — skipping.")
        }

        let client = SocketIORealtimeClient(serverURL: baseURL, enableLogging: true)
        addTeardownBlock { client.disconnect() }
        let stateObserver = SpikeStateObserver()
        client.stateDelegate = stateObserver

        let unique = "spike-\(UUID().uuidString)"
        let received = expectation(description: "team:message fan-out received")

        // Register BEFORE connect so the listener is attached when frames arrive.
        client.on("team:message") { data in
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = obj["body"] as? String else { return }
            if body == unique { received.fulfill() }
        }

        // Connect with a fresh-token provider (here: the seeded JWT).
        client.connect(tokenProvider: { jwt })

        // Join the room, then POST a message via REST so the server fans it out.
        // Small delay lets the handshake + join settle before the write.
        client.join(room: teamId)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.postMessage(baseURL: baseURL, teamId: teamId, jwt: jwt, body: unique)
        }

        wait(for: [received], timeout: 15)
    }
    private func postMessage(baseURL: URL, teamId: String, jwt: String, body: String) {
        let encodedTeamId = teamId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? teamId
        var req = URLRequest(url: baseURL.appendingPathComponent("teams/\(encodedTeamId)/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Idempotency-Key")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])
        } catch {
            NSLog("[spike] JSON serialization failed: \(error)")
            return
        }
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("[spike] REST post returned \(http.statusCode)")
            }
        }.resume()
    }
}

/// Records connection-state transitions so the spike can log whether the socket
/// ever reached `.connected` (isolates connect failure from delivery failure).
private final class SpikeStateObserver: InterRealtimeClientStateDelegate {
    func realtimeClient(_ client: InterRealtimeClient, didChange state: InterRealtimeConnectionState) {
        NSLog("[spike] realtime state -> \(state.rawValue)")
    }
}
