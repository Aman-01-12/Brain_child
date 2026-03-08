// interTests/InterTokenServiceTests.swift
// Tests for InterTokenService [1.3.9]
// Validates: happy path, 401, 404, 410, 500, timeout, malformed JSON.

import XCTest
import Foundation
@testable import inter

// MARK: - Mock URL Protocol

private class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeJWT(exp: TimeInterval) -> String {
    let header = Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    let payloadJSON = "{\"sub\":\"test\",\"exp\":\(Int(exp))}"
    let payload = Data(payloadJSON.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
    let signature = "fakesig"
    return "\(header).\(payload).\(signature)"
}

private func makeCreateRoomJSON(roomCode: String = "ABC123", token: String? = nil) -> Data {
    let jwt = token ?? makeJWT(exp: Date().timeIntervalSince1970 + 3600)
    let dict: [String: Any] = [
        "roomCode": roomCode,
        "roomName": "inter-\(roomCode)",
        "token": jwt,
        "serverURL": "ws://localhost:7880"
    ]
    return try! JSONSerialization.data(withJSONObject: dict)
}

private func makeJoinRoomJSON(token: String? = nil) -> Data {
    let jwt = token ?? makeJWT(exp: Date().timeIntervalSince1970 + 3600)
    let dict: [String: Any] = [
        "roomName": "inter-ABC123",
        "token": jwt,
        "serverURL": "ws://localhost:7880"
    ]
    return try! JSONSerialization.data(withJSONObject: dict)
}

private func makeRefreshJSON(token: String? = nil) -> Data {
    let jwt = token ?? makeJWT(exp: Date().timeIntervalSince1970 + 3600)
    let dict: [String: Any] = ["token": jwt]
    return try! JSONSerialization.data(withJSONObject: dict)
}

private func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
    return HTTPURLResponse(
        url: URL(string: url)!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

// MARK: - Tests

final class InterTokenServiceTests: XCTestCase {

    var service: InterTokenService!
    var mockSession: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        service = InterTokenService(session: mockSession)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        service = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Happy Path

    func testCreateRoom_happyPath() {
        let exp = expectation(description: "createRoom")

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/room/create"))
            XCTAssertEqual(request.httpMethod, "POST")
            return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                    makeCreateRoomJSON())
        }

        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "host-alice",
            displayName: "Alice"
        ) { response, error in
            XCTAssertNil(error)
            XCTAssertNotNil(response)
            XCTAssertEqual(response?.roomCode, "ABC123")
            XCTAssertEqual(response?.roomName, "inter-ABC123")
            XCTAssertEqual(response?.serverURL, "ws://localhost:7880")
            XCTAssertFalse(response?.token.isEmpty ?? true)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testJoinRoom_happyPath() {
        let exp = expectation(description: "joinRoom")

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/room/join"))
            return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                    makeJoinRoomJSON())
        }

        service.joinRoom(
            serverURL: "http://localhost:3000",
            roomCode: "ABC123",
            identity: "joiner-bob",
            displayName: "Bob"
        ) { response, error in
            XCTAssertNil(error)
            XCTAssertNotNil(response)
            XCTAssertEqual(response?.roomName, "inter-ABC123")
            XCTAssertEqual(response?.serverURL, "ws://localhost:7880")
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testRefreshToken_happyPath() {
        let exp = expectation(description: "refreshToken")

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/token/refresh"))
            return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                    makeRefreshJSON())
        }

        service.refreshToken(
            serverURL: "http://localhost:3000",
            roomCode: "ABC123",
            identity: "host-alice"
        ) { token, error in
            XCTAssertNil(error)
            XCTAssertNotNil(token)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - Error Codes

    func testJoinRoom_404_roomCodeInvalid() {
        let exp = expectation(description: "404")

        MockURLProtocol.requestHandler = { request in
            return (httpResponse(url: request.url!.absoluteString, statusCode: 404),
                    Data("Not Found".utf8))
        }

        service.joinRoom(
            serverURL: "http://localhost:3000",
            roomCode: "BADCODE",
            identity: "bob",
            displayName: "Bob"
        ) { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.roomCodeInvalid.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testJoinRoom_410_roomCodeExpired() {
        let exp = expectation(description: "410")

        MockURLProtocol.requestHandler = { request in
            return (httpResponse(url: request.url!.absoluteString, statusCode: 410),
                    Data("Gone".utf8))
        }

        service.joinRoom(
            serverURL: "http://localhost:3000",
            roomCode: "OLDCODE",
            identity: "bob",
            displayName: "Bob"
        ) { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.roomCodeExpired.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testCreateRoom_401_clientError() {
        let exp = expectation(description: "401")

        MockURLProtocol.requestHandler = { request in
            return (httpResponse(url: request.url!.absoluteString, statusCode: 401),
                    Data("Unauthorized".utf8))
        }

        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "alice",
            displayName: "Alice"
        ) { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.tokenFetchFailed.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testCreateRoom_500_serverError() {
        let exp = expectation(description: "500")
        var requestCount = 0

        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (httpResponse(url: request.url!.absoluteString, statusCode: 500),
                    Data("Internal Server Error".utf8))
        }

        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "alice",
            displayName: "Alice"
        ) { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            // Should have retried once (2 total requests)
            XCTAssertEqual(requestCount, 2, "Should retry once on 500")
            exp.fulfill()
        }

        waitForExpectations(timeout: 10)
    }

    func testCreateRoom_timeout() {
        let exp = expectation(description: "timeout")

        MockURLProtocol.requestHandler = { request in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        }

        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "alice",
            displayName: "Alice"
        ) { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.domain, InterNetworkErrorDomain)
            exp.fulfill()
        }

        waitForExpectations(timeout: 10)
    }

    func testCreateRoom_malformedJSON() {
        let exp = expectation(description: "malformed")

        MockURLProtocol.requestHandler = { request in
            let badJSON = Data("{\"foo\": \"bar\"}".utf8)
            return (httpResponse(url: request.url!.absoluteString, statusCode: 200), badJSON)
        }

        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "alice",
            displayName: "Alice"
        ) { response, error in
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            XCTAssertEqual(error?.code, InterNetworkErrorCode.tokenFetchFailed.rawValue)
            exp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - Cache Tests

    func testRefreshToken_returnsCachedToken() {
        let createExp = expectation(description: "create")
        let refreshExp = expectation(description: "refresh")

        let jwt = makeJWT(exp: Date().timeIntervalSince1970 + 3600)
        var requestCount = 0

        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.url!.absoluteString.hasSuffix("/room/create") {
                return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                        makeCreateRoomJSON(roomCode: "CACHE1", token: jwt))
            } else {
                return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                        makeRefreshJSON(token: jwt))
            }
        }

        // First: create room to populate cache
        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "host-alice",
            displayName: "Alice"
        ) { _, _ in
            createExp.fulfill()
        }

        wait(for: [createExp], timeout: 5)

        let countAfterCreate = requestCount

        // Second: refresh should use cache (no network request)
        service.refreshToken(
            serverURL: "http://localhost:3000",
            roomCode: "CACHE1",
            identity: "host-alice"
        ) { token, error in
            XCTAssertNil(error)
            XCTAssertNotNil(token)
            XCTAssertEqual(token, jwt, "Should return cached JWT")
            // No new network request should have been made
            XCTAssertEqual(requestCount, countAfterCreate, "Should use cache, not network")
            refreshExp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testInvalidateCache() {
        let createExp = expectation(description: "create")
        let refreshExp = expectation(description: "refresh")

        let jwt = makeJWT(exp: Date().timeIntervalSince1970 + 3600)
        var requestCount = 0

        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if request.url!.absoluteString.hasSuffix("/room/create") {
                return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                        makeCreateRoomJSON(roomCode: "INV1", token: jwt))
            } else {
                return (httpResponse(url: request.url!.absoluteString, statusCode: 200),
                        makeRefreshJSON(token: jwt))
            }
        }

        service.createRoom(
            serverURL: "http://localhost:3000",
            identity: "alice",
            displayName: "Alice"
        ) { _, _ in
            createExp.fulfill()
        }

        wait(for: [createExp], timeout: 5)

        // Invalidate cache
        service.invalidateCache()

        let countAfterInvalidate = requestCount

        // Refresh should now hit network
        service.refreshToken(
            serverURL: "http://localhost:3000",
            roomCode: "INV1",
            identity: "alice"
        ) { token, error in
            XCTAssertNil(error)
            XCTAssertNotNil(token)
            XCTAssertGreaterThan(requestCount, countAfterInvalidate,
                                 "After invalidation, refresh should hit network")
            refreshExp.fulfill()
        }

        waitForExpectations(timeout: 5)
    }
}
