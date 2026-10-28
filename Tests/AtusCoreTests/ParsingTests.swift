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
        #expect(try GrokProvider.billingPayload(fromRPCLine: #"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil)
        #expect(try GrokProvider.billingPayload(fromRPCLine: #"{"jsonrpc":"2.0","method":"_x.ai/announcements/update","params":{}}"#) == nil)
        let payload = try #require(try GrokProvider.billingPayload(fromRPCLine: #"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":21.0}}}"#))
        #expect(try GrokProvider.snapshot(from: payload, fetchedAt: .now).headlinePercent == 21)
        #expect(throws: UsageError.self) {
            try GrokProvider.billingPayload(fromRPCLine: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"auth"}}"#)
        }
    }
}
