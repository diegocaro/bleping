import Foundation

/// Where the core's log lines go. The CLI prints them with a timestamp; the app keeps them
/// for its log view. Set by `Engine`.
var logHandler: (String) -> Void = { print($0) }

func log(_ message: String) {
    logHandler(message)
}
