import Foundation

public enum ServerFeature: String, Sendable, CaseIterable, Codable {
    case health
    case managementAPI
    case routingSettings
    case clientKeyUsageReport
    case clientModels
    case fleetLimits
}

public struct ProbeReport: Sendable, Equatable {
    public var version: ServerVersion?
    public var features: [ServerFeature: Bool]
    public var accountCount: Int?
    public var modelCount: Int?
    public var failure: APIError?

    public init(version: ServerVersion? = nil, features: [ServerFeature: Bool] = [:], accountCount: Int? = nil, modelCount: Int? = nil, failure: APIError? = nil) {
        self.version = version
        self.features = features
        self.accountCount = accountCount
        self.modelCount = modelCount
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil }

    public var checkedFeatures: [(feature: ServerFeature, available: Bool)] {
        ServerFeature.allCases.compactMap { feature in features[feature].map { (feature, $0) } }
    }
}

public enum ServerProbe {
    public static func run(baseURL: URL, authMode: AuthMode, secret: String, transport: any HTTPTransport) async -> ProbeReport {
        switch authMode {
        case .management:
            await probeManagement(ManagementClient(baseURL: baseURL, managementKey: secret, transport: transport))
        case .clientKey:
            await probeClientKey(ClientKeyClient(baseURL: baseURL, clientKey: secret, transport: transport), health: ManagementClient(baseURL: baseURL, managementKey: secret, transport: transport))
        }
    }

    private static func probeManagement(_ client: ManagementClient) async -> ProbeReport {
        var report = ProbeReport()
        report.features[.health] = await isHealthy(client)
        do {
            let credentials = try await client.credentials()
            report.version = credentials.version
            report.accountCount = credentials.value.files.count
            report.features[.managementAPI] = true
        } catch {
            report.features[.managementAPI] = false
            report.failure = APIError.wrapping(error)
            return report
        }
        report.features[.routingSettings] = ((try? await client.routingStrategy()) ?? nil) != nil
        let oneHourAgo = Date().addingTimeInterval(-3600)
        report.features[.clientKeyUsageReport] = ((try? await client.clientKeyUsage(since: oneHourAgo)) ?? nil) != nil
        return report
    }

    private static func probeClientKey(_ client: ClientKeyClient, health: ManagementClient) async -> ProbeReport {
        var report = ProbeReport()
        report.features[.health] = await isHealthy(health)
        do {
            report.modelCount = try await client.models().count
            report.features[.clientModels] = true
        } catch {
            report.features[.clientModels] = false
            report.failure = APIError.wrapping(error)
            return report
        }
        do {
            let limits = try await client.fleetLimits()
            report.features[.fleetLimits] = limits != nil
            if let version = limits?.proxyVersion {
                report.version = ServerVersion(version: version)
            }
        } catch {
            report.features[.fleetLimits] = false
            report.failure = APIError.wrapping(error)
        }
        return report
    }

    private static func isHealthy(_ client: ManagementClient) async -> Bool {
        (try? await client.health()) ?? false
    }
}
