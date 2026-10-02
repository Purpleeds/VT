import Foundation
import UserNotifications

/// Local practice reminders. Wording is neutral by default (SPEC section 13):
/// nothing on the lock screen says what kind of practice it is.
@MainActor
enum NotificationService {
    static let dailyReminderID = "daily-practice-reminder"

    /// Asks for permission to show notifications (once).
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Repeats every day at the time's hour and minute.
    @discardableResult
    static func scheduleDailyReminder(at time: Date, calendar: Calendar = .current) async -> Bool {
        guard await requestAuthorization() else { return false }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyReminderID])

        let wording = NotificationWording.dailyReminder(PrivacyPreferences.notificationStyle)
        let content = UNMutableNotificationContent()
        content.title = wording.title
        content.body = wording.body
        content.sound = .default

        let components = calendar.dateComponents([.hour, .minute], from: time)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: dailyReminderID, content: content, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    static func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailyReminderID])
    }

    /// Removes every scheduled and delivered notification (Delete all data).
    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
