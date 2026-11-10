import Foundation

/// Where the core's log lines go. The CLI prints them with a timestamp; the app keeps them
/// for its log view. Set by `Engine`.
var logHandler: (String, Bool) -> Void = { message, _ in print(message) }

/// `personal`: the line holds someone's words or names (a notification's title, a device name),
/// so it must not end up readable in the system log.
func log(_ message: String, personal: Bool = false) {
    logHandler(message, personal)
}
