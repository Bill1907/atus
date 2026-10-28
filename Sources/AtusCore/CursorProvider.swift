import Foundation
import SQLite3

/// Reads Cursor plan usage from `cursor.com/api/usage-summary`, authenticated with the
/// session Cursor.app keeps in its local state database. The database is opened
/// read-only and the token is never refreshed or written back.
public struct CursorProvider: UsageProvider {
    public let info = ProviderInfo(id: .cursor, displayName: "Cursor", requirement: L("Cursor app sign-in"), icon: .bundled(.cursor))

    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static var databasePath: String {
        "\(CLILocator.home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    public init() {}

    public var isDetected: Bool {
        FileManager.default.fileExists(atPath: Self.databasePath)
    }

    public func fetch() async throws -> UsageSnapshot {
        let token = try Self.readAccessToken()
        guard let claims = Self.jwtClaims(token), let subject = claims.sub else {
            throw UsageError.credentialsMissing(L("Sign in to the Cursor app"))
        }
        if let exp = claims.exp, Date(timeIntervalSince1970: exp) <= Date().addingTimeInterval(60) {
            throw UsageError.tokenExpired(L("Open the Cursor app once to renew it"))
        }
        // Cursor's web session cookie is "<user id>::<access token>".
        let userID = subject.split(separator: "|").last.map(String.init) ?? subject
        var request = URLRequest(url: Self.summaryURL, timeoutInterval: 20)
        request.setValue("WorkosCursorSessionToken=\(userID)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try Self.snapshot(from: data, fetchedAt: Date())
        case 401, 403: throw UsageError.tokenExpired(L("Open the Cursor app once to renew it"))
        default: throw UsageError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Local session

    static func readAccessToken() throws -> String {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw UsageError.credentialsMissing(L("Install the Cursor app and sign in"))
        }
        let uri = URL(fileURLWithPath: databasePath).absoluteString + "?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw UsageError.credentialsMissing(L("Can't open Cursor's state database"))
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.credentialsMissing(L("Can't read Cursor's state database"))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw UsageError.credentialsMissing(L("Sign in to the Cursor app"))
        }
        let token = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("cursor-safe-storage:") {
            throw UsageError.credentialsMissing(L("This Cursor version stores its token encrypted, which atus can't read yet"))
        }
        guard !token.isEmpty else { throw UsageError.credentialsMissing(L("Sign in to the Cursor app")) }
        return token
    }

    struct Claims: Decodable {
        let sub: String?
        let exp: Double?
    }

    static func jwtClaims(_ token: String) -> Claims? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(Claims.self, from: data)
    }

    // MARK: - Response mapping

    struct Response: Decodable {
        struct IndividualUsage: Decodable {
            struct Plan: Decodable {
                let used: Double?
                let limit: Double?
                let autoPercentUsed: Double?
                let apiPercentUsed: Double?
                let totalPercentUsed: Double?
            }

            struct OnDemand: Decodable {
                let enabled: Bool?
                let used: Double?
                let limit: Double?
            }

            let plan: Plan?
            let onDemand: OnDemand?
        }

        let billingCycleEnd: String?
        let membershipType: String?
        let individualUsage: IndividualUsage?
    }

    public static func snapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageError.invalidResponse(String(describing: error))
        }
        guard let plan = response.individualUsage?.plan, let total = plan.totalPercentUsed else {
            throw UsageError.invalidResponse("missing individualUsage.plan")
        }

        let window = UsageWindow(
            label: L("This billing cycle"),
            percent: total,
            resetsAt: response.billingCycleEnd.flatMap(ISODate.parse)
        )

        var details: [UsageDetail] = []
        if let auto = plan.autoPercentUsed {
            details.append(UsageDetail(label: "Auto", value: "\(Int(auto.rounded()))%"))
        }
        if let api = plan.apiPercentUsed {
            details.append(UsageDetail(label: "API", value: "\(Int(api.rounded()))%"))
        }
        if let used = plan.used, let limit = plan.limit {
            details.append(UsageDetail(label: L("Included usage"), value: formatMoney(minor: used) + " / " + formatMoney(minor: limit)))
        }
        if let onDemand = response.individualUsage?.onDemand {
            let value: String
            if onDemand.enabled == true {
                value = formatMoney(minor: onDemand.used ?? 0) + (onDemand.limit.map { " / " + formatMoney(minor: $0) } ?? "")
            } else {
                value = L("Off")
            }
            details.append(UsageDetail(label: L("Extra usage"), value: value))
        }

        let membership = response.membershipType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return UsageSnapshot(provider: .cursor, plan: membership, windows: [window], details: details, fetchedAt: fetchedAt)
    }
}
