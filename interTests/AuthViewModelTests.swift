//
//  AuthViewModelTests.swift
//  interTests
//
//  Locks the ported password-strength algorithm to the legacy AppKit behavior
//  (InterLoginPanel.scoreForPassword:) and the catalogue's getStrength(), and verifies
//  the submit() validation mirrors the old panel exactly.
//

import XCTest
@testable import inter

final class AuthViewModelTests: XCTestCase {

    // MARK: Strength parity

    func testStrengthBoundaryCases() {
        XCTAssertEqual(PasswordStrength.score(for: ""), 0)            // empty
        XCTAssertEqual(PasswordStrength.score(for: "abc"), 1)          // < 8 → weak
        XCTAssertEqual(PasswordStrength.score(for: "abcdefg"), 1)      // 7 chars → weak
        XCTAssertEqual(PasswordStrength.score(for: "abcdefgh"), 1)     // 8 lower-only, variety 1 → weak
        XCTAssertEqual(PasswordStrength.score(for: "abcdefgh1"), 2)    // 9, variety 2 → fair
        XCTAssertEqual(PasswordStrength.score(for: "Abcdefgh1"), 2)    // 9, variety 3 but <10 → fair
        XCTAssertEqual(PasswordStrength.score(for: "Abcdefgh12"), 3)   // 10, variety 3 → strong
        XCTAssertEqual(PasswordStrength.score(for: "Abcdefgh123"), 3)  // 11, variety 3 → strong
        XCTAssertEqual(PasswordStrength.score(for: "Abcdefgh1234"), 4) // 12, variety 3 → very strong
        XCTAssertEqual(PasswordStrength.score(for: "Abcdefgh123!"), 4) // 12, variety 4 → very strong
        XCTAssertEqual(PasswordStrength.score(for: "Abc1!"), 1)        // 5 chars → weak regardless of variety
    }

    func testStrengthLabels() {
        XCTAssertEqual(PasswordStrength.label(for: 0), "")
        XCTAssertEqual(PasswordStrength.label(for: 1), "Weak")
        XCTAssertEqual(PasswordStrength.label(for: 2), "Fair")
        XCTAssertEqual(PasswordStrength.label(for: 3), "Strong")
        XCTAssertEqual(PasswordStrength.label(for: 4), "Very strong")
    }

    // MARK: Validation parity

    func testLoginRequiresEmail() {
        let vm = AuthViewModel()
        var fired = false
        vm.onLogin = { _, _ in fired = true }
        vm.email = "   "
        vm.password = "longenough"
        vm.submit()
        XCTAssertEqual(vm.emailError, "Email is required.")
        XCTAssertNil(vm.passwordError)
        XCTAssertFalse(fired)
    }

    func testLoginRequiresMinPasswordLength() {
        let vm = AuthViewModel()
        var fired = false
        vm.onLogin = { _, _ in fired = true }
        vm.email = "a@b.com"
        vm.password = "short"
        vm.submit()
        XCTAssertEqual(vm.passwordError, "Password must be at least 8 characters.")
        XCTAssertNil(vm.emailError)
        XCTAssertFalse(fired)
    }

    func testValidationFlagsAllBadFieldsAtOnce() {
        let vm = AuthViewModel()
        var fired = false
        vm.onRegister = { _, _, _ in fired = true }
        vm.mode = .signUp
        vm.email = ""
        vm.password = "short"
        vm.displayName = ""
        vm.submit()
        XCTAssertEqual(vm.emailError, "Email is required.")
        XCTAssertEqual(vm.passwordError, "Password must be at least 8 characters.")
        XCTAssertEqual(vm.displayNameError, "Display name is required.")
        XCTAssertFalse(fired)
    }

    func testValidLoginFiresCallbackWithTrimmedEmail() {
        let vm = AuthViewModel()
        var captured: (String, String)?
        vm.onLogin = { e, p in captured = (e, p) }
        vm.email = "  user@example.com "
        vm.password = "password1"
        vm.submit()
        XCTAssertNil(vm.emailError)
        XCTAssertNil(vm.passwordError)
        XCTAssertEqual(captured?.0, "user@example.com")
        XCTAssertEqual(captured?.1, "password1")
    }

    func testRegisterRequiresDisplayName() {
        let vm = AuthViewModel()
        var fired = false
        vm.onRegister = { _, _, _ in fired = true }
        vm.mode = .signUp
        vm.email = "a@b.com"
        vm.password = "password1"
        vm.displayName = "  "
        vm.submit()
        XCTAssertEqual(vm.displayNameError, "Display name is required.")
        XCTAssertFalse(fired)
    }

    func testValidRegisterFiresCallback() {
        let vm = AuthViewModel()
        var captured: (String, String, String)?
        vm.onRegister = { e, p, n in captured = (e, p, n) }
        vm.mode = .signUp
        vm.email = "a@b.com"
        vm.password = "password1"
        vm.displayName = "  Ada  "
        vm.submit()
        XCTAssertNil(vm.displayNameError)
        XCTAssertEqual(captured?.2, "Ada")
    }

    // MARK: Server-error routing

    func testServerErrorMentioningEmailRoutesToEmailField() {
        let vm = AuthViewModel()
        vm.applyServerError("Invalid email address")
        XCTAssertEqual(vm.emailError, "Invalid email address")
        XCTAssertNil(vm.passwordError)
        XCTAssertNil(vm.formError)
    }

    func testServerErrorMentioningPasswordRoutesToPasswordField() {
        let vm = AuthViewModel()
        vm.applyServerError("This password has appeared in a data breach. Please choose another.")
        XCTAssertEqual(vm.passwordError, "This password has appeared in a data breach. Please choose another.")
        XCTAssertNil(vm.emailError)
        XCTAssertNil(vm.formError)
    }

    func testAmbiguousCredentialsErrorStaysFormLevel() {
        let vm = AuthViewModel()
        vm.applyServerError("Invalid email or password. Please try again.")
        XCTAssertEqual(vm.formError, "Invalid email or password. Please try again.")
        XCTAssertNil(vm.emailError)   // must NOT reveal which field
        XCTAssertNil(vm.passwordError)
    }

    func testNonFieldErrorRoutesToFormLevel() {
        let vm = AuthViewModel()
        vm.applyServerError("Server unreachable. Check your connection.")
        XCTAssertEqual(vm.formError, "Server unreachable. Check your connection.")
        XCTAssertNil(vm.emailError)
        XCTAssertNil(vm.passwordError)
    }

    // MARK: Forgot password

    func testForgotPasswordRequiresEmail() {
        let vm = AuthViewModel()
        var fired = false
        vm.onForgotPassword = { _ in fired = true }
        vm.email = "   "
        vm.tapForgotPassword()
        XCTAssertNotNil(vm.emailError)
        XCTAssertFalse(fired, "Should not request a reset without an email")
    }

    func testForgotPasswordFiresWithTrimmedEmail() {
        let vm = AuthViewModel()
        var captured: String?
        vm.onForgotPassword = { captured = $0 }
        vm.email = "  user@example.com  "
        vm.tapForgotPassword()
        XCTAssertNil(vm.emailError)
        XCTAssertEqual(captured, "user@example.com")
    }

    func testShowInfoClearsErrorsAndSetsMessage() {
        let vm = AuthViewModel()
        vm.emailError = "bad"
        vm.formError = "boom"
        vm.showInfo("If that email is registered, you'll receive a reset link shortly.")
        XCTAssertNil(vm.emailError)
        XCTAssertNil(vm.formError)
        XCTAssertEqual(vm.infoMessage, "If that email is registered, you'll receive a reset link shortly.")
    }

    func testServerErrorClearsInfoMessage() {
        let vm = AuthViewModel()
        vm.infoMessage = "reset link sent"
        vm.applyServerError("Server unreachable.")
        XCTAssertNil(vm.infoMessage)
        XCTAssertEqual(vm.formError, "Server unreachable.")
    }

    // MARK: Mode toggle

    func testToggleModeClearsPasswordAndErrors() {
        let vm = AuthViewModel()
        vm.password = "secret123"
        vm.emailError = "oops"
        vm.formError = "bad"
        vm.toggleMode()
        XCTAssertEqual(vm.mode, .signUp)
        XCTAssertEqual(vm.password, "")
        XCTAssertNil(vm.emailError)
        XCTAssertNil(vm.formError)
    }

    func testStrengthOnlyShownInRegisterWithInput() {
        let vm = AuthViewModel()
        vm.password = "password1"
        XCTAssertFalse(vm.showsStrength)         // sign-in → hidden
        vm.mode = .signUp
        XCTAssertTrue(vm.showsStrength)          // sign-up + input → shown
        vm.password = ""
        XCTAssertFalse(vm.showsStrength)         // sign-up + empty → hidden
    }
}
