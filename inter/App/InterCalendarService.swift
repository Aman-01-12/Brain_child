// ============================================================================
// InterCalendarService.swift — Phase 11.1 + 11.2.3
//
// Provides EventKit integration for viewing and syncing meetings with the
// system calendar (Apple Calendar).
//
// Features:
//   - Request calendar access (macOS permission prompt)
//   - Create EKEvent from a scheduled meeting
//   - Delete EKEvent when a meeting is cancelled
//   - Fetch upcoming EKEvents to display in the calendar view
//   - Observe EKEventStoreChangedNotification for external edits
//
// Design:
//   - All calendar operations run on a background queue, callbacks on main
//   - @objc exposed for Objective-C interop
//   - Calendar entitlement required: com.apple.security.personal-information.calendars
// ============================================================================

import EventKit
import Foundation

/// Delegate for calendar authorization and sync status changes.
@objc public protocol InterCalendarServiceDelegate: AnyObject {
    @objc optional func calendarServiceDidChangeAuthorization(_ service: InterCalendarService, granted: Bool)
    @objc optional func calendarServiceDidSyncEvent(_ service: InterCalendarService, meetingId: String, calendarEventId: String)
    @objc optional func calendarServiceDidFailSync(_ service: InterCalendarService, meetingId: String, error: NSError)
    @objc optional func calendarServiceDidDetectExternalChange(_ service: InterCalendarService)
}

/// [Phase 11.1 / 11.2.3] Calendar integration via EventKit.
@objc public class InterCalendarService: NSObject {

    // MARK: - Properties

    @objc public weak var delegate: InterCalendarServiceDelegate?

    private let eventStore = EKEventStore()
    private let workQueue = DispatchQueue(label: "com.inter.calendarService", qos: .userInitiated)

    /// Maps meeting IDs to their corresponding EKEvent identifiers for removal/update.
    private var meetingEventMap: [String: String] = [:]

    /// UserDefaults key for persisted meeting↔event mapping.
    private static let mappingKey = "InterCalendarService.meetingEventMap"

    /// Whether the user has granted calendar access.
    @objc public private(set) var isAuthorized: Bool = false

    // MARK: - Lifecycle

    @objc public override init() {
        super.init()
        loadPersistedMapping()
        updateAuthorizationStatus()
        observeStoreChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Authorization

    /// Request calendar access. On macOS, this triggers the system permission dialog.
    @objc public func requestAccess(completion: @escaping (_ granted: Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                guard let self = self else { return }
                if let error = error {
                    NSLog("[Calendar] Access request error: %@", error.localizedDescription)
                }
                self.isAuthorized = granted
                DispatchQueue.main.async {
                    self.delegate?.calendarServiceDidChangeAuthorization?(self, granted: granted)
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                guard let self = self else { return }
                if let error = error {
                    NSLog("[Calendar] Access request error: %@", error.localizedDescription)
                }
                self.isAuthorized = granted
                DispatchQueue.main.async {
                    self.delegate?.calendarServiceDidChangeAuthorization?(self, granted: granted)
                    completion(granted)
                }
            }
        }
    }

    private func updateAuthorizationStatus() {
        if #available(macOS 14.0, *) {
            isAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        } else {
            isAuthorized = EKEventStore.authorizationStatus(for: .event) == .authorized
        }
    }

    // MARK: - Create Event

    /// Create an EKEvent from a scheduled meeting and save to the default calendar.
    ///
    /// - Parameters:
    ///   - meetingId: Server-side meeting UUID.
    ///   - title: Meeting title.
    ///   - notes: Optional description or join link.
    ///   - startDate: Meeting start time.
    ///   - durationMinutes: Duration in minutes.
    ///   - hostTimezone: IANA timezone identifier (e.g. "America/New_York").
    ///   - roomCode: Room code for the meeting link.
    @objc public func createEvent(
        meetingId: String,
        title: String,
        notes: String?,
        startDate: Date,
        durationMinutes: Int,
        hostTimezone: String,
        roomCode: String?
    ) {
        guard isAuthorized else {
            NSLog("[Calendar] Not authorized — skipping event creation")
            return
        }

        workQueue.async { [weak self] in
            guard let self = self else { return }

            let event = EKEvent(eventStore: self.eventStore)
            event.title = title
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
            event.calendar = self.eventStore.defaultCalendarForNewEvents

            // Set timezone from host
            if let tz = TimeZone(identifier: hostTimezone) {
                event.timeZone = tz
            }

            // Build notes with join info
            var noteLines: [String] = []
            if let notes = notes, !notes.isEmpty {
                noteLines.append(notes)
            }
            if let code = roomCode {
                noteLines.append("Room Code: \(code)")
                noteLines.append("Join in the Inter app using this room code.")
            }
            event.notes = noteLines.joined(separator: "\n")

            // Add an alert 5 minutes before
            event.addAlarm(EKAlarm(relativeOffset: -5 * 60))

            do {
                try self.eventStore.save(event, span: .thisEvent)
                self.meetingEventMap[meetingId] = event.eventIdentifier
                self.persistMapping()
                NSLog("[Calendar] Created EKEvent '%@' for meeting %@", title, meetingId)
                DispatchQueue.main.async {
                    self.delegate?.calendarServiceDidSyncEvent?(self, meetingId: meetingId, calendarEventId: event.eventIdentifier)
                }
            } catch {
                NSLog("[Calendar] Failed to save event: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.delegate?.calendarServiceDidFailSync?(self, meetingId: meetingId, error: error as NSError)
                }
            }
        }
    }

    // MARK: - Remove Event

    /// Remove a previously created EKEvent when a meeting is cancelled.
    @objc public func removeEvent(forMeetingId meetingId: String) {
        guard isAuthorized else { return }

        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard let eventId = self.meetingEventMap[meetingId] else {
                NSLog("[Calendar] No EKEvent found for meeting %@", meetingId)
                return
            }

            guard let event = self.eventStore.event(withIdentifier: eventId) else {
                NSLog("[Calendar] EKEvent %@ no longer exists", eventId)
                self.meetingEventMap.removeValue(forKey: meetingId)
                self.persistMapping()
                return
            }

            do {
                try self.eventStore.remove(event, span: .thisEvent)
                self.meetingEventMap.removeValue(forKey: meetingId)
                self.persistMapping()
                NSLog("[Calendar] Removed EKEvent for meeting %@", meetingId)
            } catch {
                NSLog("[Calendar] Failed to remove event: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Fetch Upcoming Events

    /// Fetch upcoming EKEvents from a window of the next 30 days.
    /// Returns events on the main thread via completion handler.
    @objc public func fetchUpcomingEvents(
        daysAhead: Int = 30,
        completion: @escaping (_ events: [[String: Any]]) -> Void
    ) {
        guard isAuthorized else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        workQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let startDate = Date()
            let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: startDate) ?? startDate

            let predicate = self.eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
            let events = self.eventStore.events(matching: predicate)

            let result: [[String: Any]] = events.map { event in
                var dict: [String: Any] = [
                    "title": event.title ?? "",
                    "startDate": event.startDate as Any,
                    "endDate": event.endDate as Any,
                    "isAllDay": event.isAllDay,
                    "calendarName": event.calendar?.title ?? "",
                    "eventIdentifier": event.eventIdentifier ?? "",
                ]
                if let notes = event.notes {
                    dict["notes"] = notes
                }
                if let location = event.location {
                    dict["location"] = location
                }
                return dict
            }

            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - External Change Observation

    private func observeStoreChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChanged(_:)),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    @objc private func handleStoreChanged(_ notification: Notification) {
        NSLog("[Calendar] External calendar change detected")
        updateAuthorizationStatus()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.calendarServiceDidDetectExternalChange?(self)
        }
    }

    // MARK: - Persistence

    private func persistMapping() {
        UserDefaults.standard.set(meetingEventMap, forKey: InterCalendarService.mappingKey)
    }

    private func loadPersistedMapping() {
        if let saved = UserDefaults.standard.dictionary(forKey: InterCalendarService.mappingKey) as? [String: String] {
            meetingEventMap = saved
        }
    }
}
