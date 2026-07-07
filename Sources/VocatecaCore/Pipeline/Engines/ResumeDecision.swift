import Foundation

// MARK: - Validator

/// HTTP cache validator extracted from a server response.
///
/// Used to detect whether a `.part` file is still valid for resume (same
/// resource) or stale (resource changed upstream).
public struct Validator: Codable, Equatable, Sendable {
    /// The `ETag` response header value, if provided by the server.
    public let etag: String?
    /// The `Last-Modified` response header value, if provided by the server.
    public let lastModified: String?

    public init(etag: String?, lastModified: String?) {
        self.etag = etag
        self.lastModified = lastModified
    }

    /// Two validators match when at least one shared field is non-nil and equal.
    ///
    /// - If both have an `ETag`, they must match.
    /// - If no `ETag`, fall back to `Last-Modified`.
    /// - If both are nil on both sides, we cannot confirm identity → mismatch.
    public func matches(_ other: Validator) -> Bool {
        // Prefer ETag comparison (strong identity).
        if let a = etag, let b = other.etag {
            return a == b
        }
        // Fall back to Last-Modified when no ETag on either side.
        if let a = lastModified, let b = other.lastModified {
            return a == b
        }
        // No shared field — cannot confirm identity.
        return false
    }
}

// MARK: - DownloadMeta (sidecar)

/// JSON sidecar written alongside `<slug>.mp3.part` to validate cross-launch
/// resumes.
///
/// Written when the first byte is received (so the `.part` file exists on
/// subsequent launches). Read before sending a `Range:` request to detect
/// upstream re-encoding or URL changes.
public struct DownloadMeta: Codable, Sendable {
    /// The original request URL string (sanity check on resume).
    public let url: String
    /// HTTP cache validators from the first response.
    public let validator: Validator
    /// Expected total file size in bytes, from `Content-Length` (may be nil
    /// when the server does not advertise content length).
    public let expectedLength: Int64?

    public init(url: String, validator: Validator, expectedLength: Int64?) {
        self.url = url
        self.validator = validator
        self.expectedLength = expectedLength
    }
}

// MARK: - ResumeAction

/// Decision returned by ``resumeDecision(partSize:statusCode:serverValidator:storedValidator:expectedLength:)``.
public enum ResumeAction: Equatable, Sendable {
    /// Append to the existing `.part` file starting at `offset`.
    case appendFrom(Int64)
    /// Truncate the `.part` file to 0 and restart from byte 0.
    case restart
    /// The `.part` file already contains the complete resource; rename it.
    case finalizeAlreadyComplete
}

// MARK: - resumeDecision

/// Pure, network-free decision function for HTTP range-resume.
///
/// Encodes the full truth table from the spec so it can be unit-tested
/// without any real HTTP activity.
///
/// - Parameters:
///   - partSize:        Bytes already in the `.part` file (0 when file absent).
///   - statusCode:      HTTP response status: 200, 206, or 416.
///   - serverValidator: `ETag` / `Last-Modified` extracted from the *new* response.
///   - storedValidator: Validator read from the `.meta` sidecar (nil on first download).
///   - expectedLength:  Total resource length in bytes, from `Content-Range` or
///     prior `Content-Length` (nil when unknown).
/// - Returns: A ``ResumeAction`` indicating what the downloader should do.
public func resumeDecision(
    partSize: Int64,
    statusCode: Int,
    serverValidator: Validator?,
    storedValidator: Validator?,
    expectedLength: Int64?
) -> ResumeAction {

    // Rule: part size exceeds expected length → something is wrong; restart.
    if let expected = expectedLength, partSize > expected {
        return .restart
    }

    switch statusCode {

    case 206:
        // Server honoured the Range request.
        // Validate that the resource hasn't changed upstream.
        if let stored = storedValidator, let server = serverValidator {
            if stored.matches(server) {
                return .appendFrom(partSize)
            } else {
                // Validator mismatch — resource re-encoded upstream.
                return .restart
            }
        } else if storedValidator == nil && serverValidator == nil {
            // Neither side has validators — trust the 206 (server accepted Range).
            return .appendFrom(partSize)
        } else if storedValidator == nil {
            // First attempt (no sidecar yet), but 206 received for a zero part.
            // This shouldn't normally happen (we only send Range if partSize>0),
            // but handle it gracefully — trust the 206.
            return .appendFrom(partSize)
        } else {
            // We have a stored validator but server returned none (unusual).
            // Can't confirm identity — restart to be safe.
            return .restart
        }

    case 200:
        // Server ignored the Range header (or we sent a fresh request).
        // Must restart from byte 0.
        return .restart

    case 416:
        // Range Not Satisfiable — part size ≥ resource size.
        if let expected = expectedLength, partSize >= expected {
            return .finalizeAlreadyComplete
        }
        // We don't know the expected length, or sizes don't add up.
        return .restart

    default:
        // Any other status (4xx, 5xx, etc.) is not a resume condition.
        // The caller maps these to PipelineError; return restart so the
        // caller can clean up the partial file if it decides to.
        return .restart
    }
}
