import Foundation

public enum Freshness: String, Codable, Equatable, Sendable {
    case unknown
    case current
    case stale
}

public enum RefreshStatus: String, Codable, Equatable, Sendable {
    case never
    case success
    case partial
    case failure
}

public struct Dashboard: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let lastAttemptAt: Date?
    public let dataAsOf: Date?
    public let freshness: Freshness
    public let latestRefreshStatus: RefreshStatus
    public let data: DashboardData

    public init(
        generatedAt: Date,
        lastAttemptAt: Date?,
        dataAsOf: Date?,
        freshness: Freshness,
        latestRefreshStatus: RefreshStatus,
        data: DashboardData
    ) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.lastAttemptAt = lastAttemptAt
        self.dataAsOf = dataAsOf
        self.freshness = freshness
        self.latestRefreshStatus = latestRefreshStatus
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case lastAttemptAt
        case dataAsOf
        case freshness
        case latestRefreshStatus
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        if let lastAttemptAt { try container.encode(lastAttemptAt, forKey: .lastAttemptAt) } else { try container.encodeNil(forKey: .lastAttemptAt) }
        if let dataAsOf { try container.encode(dataAsOf, forKey: .dataAsOf) } else { try container.encodeNil(forKey: .dataAsOf) }
        try container.encode(freshness, forKey: .freshness)
        try container.encode(latestRefreshStatus, forKey: .latestRefreshStatus)
        try container.encode(data, forKey: .data)
    }
}

public struct DashboardData: Codable, Equatable, Sendable {
    public let availableUpdateCount: Int
    public let informationalUpdateCount: Int
    public let recentTransitionCount: Int
    public let partialProviderCount: Int
    public let failedProviderCount: Int
    public let providerResults: [ProviderRefreshResult]

    public init(
        availableUpdateCount: Int, informationalUpdateCount: Int = 0, recentTransitionCount: Int, partialProviderCount: Int = 0, failedProviderCount: Int,
        providerResults: [ProviderRefreshResult] = []
    ) {
        self.availableUpdateCount = availableUpdateCount
        self.informationalUpdateCount = informationalUpdateCount
        self.recentTransitionCount = recentTransitionCount
        self.partialProviderCount = partialProviderCount
        self.failedProviderCount = failedProviderCount
        self.providerResults = providerResults
    }
}
