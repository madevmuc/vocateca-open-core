import Foundation

public extension URLSessionConfiguration {
    /// A config with a HARD resource (total wall-clock) cap — the default is 7 days,
    /// which lets a stalled transfer hang forever. requestTimeout = per-request
    /// inactivity; resourceTimeout = hard total cap.
    static func vocateca(requestTimeout: TimeInterval = 60,
                         resourceTimeout: TimeInterval = 600) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest  = requestTimeout
        c.timeoutIntervalForResource = resourceTimeout
        c.waitsForConnectivity = false
        return c
    }
}
