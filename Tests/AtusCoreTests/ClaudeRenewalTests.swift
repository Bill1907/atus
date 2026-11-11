import Foundation
import Testing
@testable import AtusCore

@Suite struct ClaudeRenewalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Sanitized stdout line from claude 2.1.321 answering the initialize control request,
    /// trimmed to one entry per list.
    private static let initializeResponse = #"{"type": "control_response", "response": {"subtype": "success", "request_id": "atus-1", "response": {"commands": [{"name": "deep-research", "description": "Deep research harness \u2014 fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report. (dynamic workflow)", "argumentHint": "", "builtin": true}], "agents": [{"name": "claude", "description": "Catch-all for any task that doesn't fit a more specific agent. FleetView's default when no agent name is typed."}], "output_style": "default", "available_output_styles": ["default"], "models": [{"value": "default", "resolvedModel": "claude-fable-5-2", "displayName": "Default (recommended)", "description": "Fable 5.2", "supportsEffort": true, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]}], "account": {"email": "user@example.com", "organization": "Example Org", "subscriptionType": "Claude Max", "apiProvider": "firstParty"}, "pid": 12345, "claude_code_version": "2.1.321", "session_state": "idle", "capabilities": ["ui_surface_v1"]}, "pending_permission_requests": [], "pending_user_dialog_requests": []}}"#

    @Test func tokenWithoutExpiryNeedsNoRenewal() {
        #expect(!ClaudeProvider.needsRenewal(expiresAt: nil, now: now))
    }

    @Test func expiredTokenNeedsRenewal() {
        #expect(ClaudeProvider.needsRenewal(expiresAt: now.addingTimeInterval(-3600), now: now))
        #expect(ClaudeProvider.needsRenewal(expiresAt: now, now: now))
    }

    @Test func tokenInsideTheMarginNeedsRenewal() {
        #expect(ClaudeProvider.needsRenewal(expiresAt: now.addingTimeInterval(30), now: now))
        #expect(ClaudeProvider.needsRenewal(expiresAt: now.addingTimeInterval(60), now: now))
    }

    @Test func tokenBeyondTheMarginNeedsNoRenewal() {
        #expect(!ClaudeProvider.needsRenewal(expiresAt: now.addingTimeInterval(61), now: now))
        #expect(!ClaudeProvider.needsRenewal(expiresAt: now.addingTimeInterval(8 * 3600), now: now))
    }

    @Test func matchesTheInitializeResponse() {
        #expect(ClaudeProvider.isInitializeResponse(line: Data(Self.initializeResponse.utf8)))
    }

    @Test(arguments: [
        // Another request's answer.
        #"{"type":"control_response","response":{"subtype":"success","request_id":"atus-2","response":{}}}"#,
        // Our request, refused.
        #"{"type":"control_response","response":{"subtype":"error","request_id":"atus-1","error":"refused"}}"#,
        // Other message types, including an echo of the request itself.
        #"{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000000"}"#,
        #"{"type":"control_request","request_id":"atus-1","request":{"subtype":"initialize"}}"#,
        // Not a JSON object.
        #"["control_response"]"#,
        "Welcome to Claude Code",
        "",
    ])
    func rejectsEveryOtherLine(line: String) {
        #expect(!ClaudeProvider.isInitializeResponse(line: Data(line.utf8)))
    }

    @Test func renewalIsAllowedWhenNothingHasFailed() {
        #expect(ClaudeProvider.mayAttemptRenewal(lastFailure: nil, now: now))
    }

    @Test func renewalWaitsTenMinutesAfterAFailure() {
        #expect(!ClaudeProvider.mayAttemptRenewal(lastFailure: now, now: now))
        #expect(!ClaudeProvider.mayAttemptRenewal(lastFailure: now.addingTimeInterval(-599), now: now))
        #expect(ClaudeProvider.mayAttemptRenewal(lastFailure: now.addingTimeInterval(-600), now: now))
        #expect(ClaudeProvider.mayAttemptRenewal(lastFailure: now.addingTimeInterval(-3600), now: now))
    }
}
