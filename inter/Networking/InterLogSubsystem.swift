// ============================================================================
// InterLogSubsystem.swift
// inter
//
// Phase 1.2 [G9] — Structured logging for the networking layer.
//
// Uses os_log (Apple Unified Logging). Zero runtime cost when not observed.
// All log messages follow privacy rules:
//   - Non-PII (state names, error codes, durations): %{public}@
//   - PII (identities, room codes, IPs):             %{private}@
//   - Tokens/secrets:                                 NEVER logged
// ============================================================================

import Foundation
import os.log

// MARK: - Subsystem

/// The unified logging subsystem identifier for all networking code.
/// Matches the bundle identifier pattern for Console.app filtering.
@usableFromInline
let interNetworkSubsystem = "com.secure.inter.network"

// MARK: - Log Categories

/// Pre-configured os_log loggers for the networking layer.
/// Usage: `InterLog.networking.info("Connected to server")`
@objc public class InterLog: NSObject {

    /// Signaling, WebSocket, ICE, token operations.
    @objc public static let networking = OSLog(subsystem: interNetworkSubsystem, category: "networking")

    /// Media track publishing, subscribing, muting, encoding.
    @objc public static let media = OSLog(subsystem: interNetworkSubsystem, category: "media")

    /// Room lifecycle, participant events, presence state.
    @objc public static let room = OSLog(subsystem: interNetworkSubsystem, category: "room")

    /// WebRTC stats collection and diagnostics.
    @objc public static let stats = OSLog(subsystem: interNetworkSubsystem, category: "stats")

    private override init() {
        super.init()
    }
}

// MARK: - Convenience Logging Functions

/// Log at info level. Use for normal lifecycle events.
/// - Parameters:
///   - log: The OSLog category (e.g. `InterLog.networking`).
///   - message: A StaticString format. Use `%{public}@` for non-PII, `%{private}@` for PII.
@usableFromInline
func interLogInfo(_ log: OSLog, _ message: StaticString, _ args: CVarArg...) {
    // os_log is variadic-unfriendly; use withVaList for up to 4 args.
    switch args.count {
    case 0: os_log(message, log: log, type: .info)
    case 1: os_log(message, log: log, type: .info, args[0])
    case 2: os_log(message, log: log, type: .info, args[0], args[1])
    case 3: os_log(message, log: log, type: .info, args[0], args[1], args[2])
    default: os_log(message, log: log, type: .info, args[0], args[1], args[2], args[3])
    }
}

/// Log at error level. Use for failures that affect functionality.
@usableFromInline
func interLogError(_ log: OSLog, _ message: StaticString, _ args: CVarArg...) {
    switch args.count {
    case 0: os_log(message, log: log, type: .error)
    case 1: os_log(message, log: log, type: .error, args[0])
    case 2: os_log(message, log: log, type: .error, args[0], args[1])
    case 3: os_log(message, log: log, type: .error, args[0], args[1], args[2])
    default: os_log(message, log: log, type: .error, args[0], args[1], args[2], args[3])
    }
}

/// Log at debug level. Use for verbose diagnostics (stripped in release unless observed).
@usableFromInline
func interLogDebug(_ log: OSLog, _ message: StaticString, _ args: CVarArg...) {
    switch args.count {
    case 0: os_log(message, log: log, type: .debug)
    case 1: os_log(message, log: log, type: .debug, args[0])
    case 2: os_log(message, log: log, type: .debug, args[0], args[1])
    case 3: os_log(message, log: log, type: .debug, args[0], args[1], args[2])
    default: os_log(message, log: log, type: .debug, args[0], args[1], args[2], args[3])
    }
}

/// Log at warning level (maps to os_log .default — between info and error).
/// Use for recoverable issues that deserve attention (e.g. low disk space).
@usableFromInline
func interLogWarning(_ log: OSLog, _ message: StaticString, _ args: CVarArg...) {
    switch args.count {
    case 0: os_log(message, log: log, type: .default)
    case 1: os_log(message, log: log, type: .default, args[0])
    case 2: os_log(message, log: log, type: .default, args[0], args[1])
    case 3: os_log(message, log: log, type: .default, args[0], args[1], args[2])
    default: os_log(message, log: log, type: .default, args[0], args[1], args[2], args[3])
    }
}

/// Log at fault level. Use for conditions that should never happen (programming errors).
@usableFromInline
func interLogFault(_ log: OSLog, _ message: StaticString, _ args: CVarArg...) {
    switch args.count {
    case 0: os_log(message, log: log, type: .fault)
    case 1: os_log(message, log: log, type: .fault, args[0])
    case 2: os_log(message, log: log, type: .fault, args[0], args[1])
    case 3: os_log(message, log: log, type: .fault, args[0], args[1], args[2])
    default: os_log(message, log: log, type: .fault, args[0], args[1], args[2], args[3])
    }
}
