import Foundation
import Testing
@testable import AtusCore

@Suite struct ISODateTests {
    @Test(arguments: [
        ("2026-10-28T10:10:00.714906+00:00", "2026-10-28T10:10:00Z"),
        ("2026-10-27T03:15:18.391+00:00", "2026-10-27T03:15:18Z"),
        ("2026-11-01T00:00:00+00:00", "2026-11-01T00:00:00Z"),
        ("2026-10-28T13:03:28.8Z", "2026-10-28T13:03:28Z"),
    ])
    func parsesVendorTimestamps(input: String, expectedWholeSecond: String) throws {
        let parsed = try #require(ISODate.parse(input))
        let expected = try #require(ISODate.parse(expectedWholeSecond))
        #expect(abs(parsed.timeIntervalSince(expected)) < 1)
    }
}

@Suite struct ClaudeMappingTests {
    @Test func mapsWindowsSkipsNullsAndIgnoresUnknownKeys() throws {
        let json = """
        {
          "five_hour": {"utilization": 23.0, "resets_at": "2026-10-28T10:10:00.714906+00:00", "limit_dollars": null},
          "seven_day": {"utilization": 45.0, "resets_at": "2026-11-01T00:00:00.714925+00:00"},
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "iguana_necktie": {"utilization": 0.0, "limit_dollars": 250},
          "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 1234, "currency": "USD", "decimal_places": 2},
          "seven_day_breakdown": {"rows": [{"key": "claude_code", "display_name": "Claude Code", "percent": 100}]}
        }
        """
        let snapshot = try ClaudeProvider.snapshot(from: Data(json.utf8), plan: "Max 5x", fetchedAt: .now)

        #expect(snapshot.windows.map(\.label) == ["5시간 세션", "주간"])
        #expect(snapshot.headlinePercent == 45)
        #expect(snapshot.windows.allSatisfy { $0.resetsAt != nil })
        #expect(snapshot.details.contains(UsageDetail(label: "추가 사용량", value: "$12.34 / $100.00")))
        #expect(snapshot.details.contains(UsageDetail(label: "이번 주 · Claude Code", value: "100%")))
    }

    @Test func rejectsResponseWithoutAnyWindow() {
        #expect(throws: UsageError.self) {
            try ClaudeProvider.snapshot(from: Data(#"{"five_hour": null, "seven_day": null}"#.utf8), plan: nil, fetchedAt: .now)
        }
    }

    @Test func derivesPlanFromRateLimitTier() {
        #expect(ClaudeProvider.planName(subscriptionType: "max", tier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudeProvider.planName(subscriptionType: "pro", tier: nil) == "Pro")
    }
}

@Suite struct GrokMappingTests {
    @Test func mapsRESTBillingResponse() throws {
        let json = """
        {"config": {
          "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-27T03:15:18.391+00:00", "end": "2026-11-03T03:15:18.391+00:00"},
          "creditUsagePercent": 21.0,
          "productUsage": [{"product": "Api", "usagePercent": 16.0}, {"product": "GrokBot", "usagePercent": 5.0}],
          "prepaidBalance": {"val": 493},
          "billingPeriodEnd": "2026-11-03T03:15:18.391+00:00"
        }}
        """
        let snapshot = try GrokProvider.snapshot(from: Data(json.utf8), fetchedAt: .now)

        #expect(snapshot.headlinePercent == 21)
        #expect(snapshot.windows.first?.resetsAt == ISODate.parse("2026-11-03T03:15:18.391+00:00"))
        #expect(snapshot.details.contains(UsageDetail(label: "이번 주 · Api", value: "16%")))
        #expect(snapshot.details.contains(UsageDetail(label: "추가 크레딧 잔액", value: "$4.93")))
        #expect(snapshot.plan == nil)
    }

    @Test func treatsOmittedPercentAsZeroAndStringCents() throws {
        // Protobuf JSON drops zero fields and may encode int64 as a string.
        let json = """
        {"config": {"currentPeriod": {"end": "2026-11-03T03:15:18.391+00:00"}, "prepaidBalance": {"val": "1446"}},
         "subscription_tier": "SuperGrok"}
        """
        let snapshot = try GrokProvider.snapshot(from: Data(json.utf8), fetchedAt: .now)

        #expect(snapshot.headlinePercent == 0)
        #expect(snapshot.plan == "SuperGrok")
        #expect(snapshot.details.contains(UsageDetail(label: "추가 크레딧 잔액", value: "$14.46")))
    }

    @Test func extractsBillingResultFromAgentRPCStream() throws {
        let method = "_x.ai/billing"
        #expect(try StdioJSONRPC.result(fromLine: #"{"jsonrpc":"2.0","id":1,"result":{}}"#, id: 2, method: method) == nil)
        #expect(try StdioJSONRPC.result(fromLine: #"{"jsonrpc":"2.0","method":"_x.ai/announcements/update","params":{}}"#, id: 2, method: method) == nil)
        let payload = try #require(try StdioJSONRPC.result(fromLine: #"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":21.0}}}"#, id: 2, method: method))
        #expect(try GrokProvider.snapshot(from: payload, fetchedAt: .now).headlinePercent == 21)
        #expect(throws: UsageError.self) {
            try StdioJSONRPC.result(fromLine: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"auth"}}"#, id: 2, method: method)
        }
    }
}

@Suite struct CodexMappingTests {
    @Test func mapsPrimaryAndSecondaryWindows() throws {
        let json = """
        {"rateLimits": {
          "primary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1795766500},
          "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1796000000},
          "credits": {"hasCredits": true, "unlimited": false, "balance": "120"},
          "planType": "plus"
        }}
        """
        let snapshot = try CodexProvider.snapshot(from: Data(json.utf8), fetchedAt: .now)

        #expect(snapshot.windows.map(\.label) == ["5시간", "주간"])
        #expect(snapshot.headlinePercent == 40)
        #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1795766500))
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.details == [UsageDetail(label: "크레딧", value: "120")])
    }

    @Test func mapsFreePlanThirtyDayWindowWithoutSecondary() throws {
        let json = """
        {"rateLimits": {"primary": {"usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 1795766500},
         "secondary": null, "credits": {"hasCredits": false, "unlimited": false, "balance": null}, "planType": "free"}}
        """
        let snapshot = try CodexProvider.snapshot(from: Data(json.utf8), fetchedAt: .now)

        #expect(snapshot.windows.map(\.label) == ["30일"])
        #expect(snapshot.details.isEmpty)
    }
}

@Suite struct CursorMappingTests {
    @Test func mapsUsageSummary() throws {
        let json = """
        {"billingCycleEnd": "2026-11-01T00:00:00.000Z", "membershipType": "premium",
         "individualUsage": {
           "plan": {"enabled": true, "used": 1234, "limit": 4615, "autoPercentUsed": 10, "apiPercentUsed": 30, "totalPercentUsed": 26.7},
           "onDemand": {"enabled": false, "used": 0, "limit": null}}}
        """
        let snapshot = try CursorProvider.snapshot(from: Data(json.utf8), fetchedAt: .now)

        #expect(snapshot.headlinePercent == 26.7)
        #expect(snapshot.windows.first?.resetsAt == ISODate.parse("2026-11-01T00:00:00Z"))
        #expect(snapshot.plan == "Premium")
        #expect(snapshot.details.contains(UsageDetail(label: "포함 사용량", value: "$12.34 / $46.15")))
        #expect(snapshot.details.contains(UsageDetail(label: "추가 사용량", value: "꺼짐")))
    }

    @Test func readsSubjectAndExpiryFromJWT() throws {
        // {"sub":"google-oauth2|user_123","exp":1798248843}
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMTIzIiwiZXhwIjoxNzk4MjQ4ODQzfQ.sig"
        let claims = try #require(CursorProvider.jwtClaims(token))
        #expect(claims.sub == "google-oauth2|user_123")
        #expect(claims.exp == 1798248843)
    }
}

@Suite struct CopilotMappingTests {
    @Test func skipsUnlimitedAndNotIncludedQuotas() throws {
        let json = """
        {"access_type_sku": "free_limited_copilot", "copilot_plan": "individual",
         "quota_reset_date_utc": "2026-11-01T00:00:00.000Z",
         "quota_snapshots": {
           "chat": {"percent_remaining": 75.0, "unlimited": false, "entitlement": 200, "remaining": 150},
           "completions": {"percent_remaining": 100.0, "unlimited": true, "entitlement": 0, "remaining": 0},
           "premium_interactions": {"percent_remaining": 0.0, "unlimited": false, "entitlement": 0, "remaining": 0}}}
        """
        let snapshot = try CopilotProvider.snapshot(from: Data(json.utf8), fetchedAt: .now)

        #expect(snapshot.windows.map(\.label) == ["채팅"])
        #expect(snapshot.headlinePercent == 25)
        #expect(snapshot.windows.first?.resetsAt == ISODate.parse("2026-11-01T00:00:00Z"))
        #expect(snapshot.details == [UsageDetail(label: "채팅 남음", value: "150 / 200")])
        #expect(snapshot.plan == "Free")
    }
}
