import Foundation

/// What the network is like right now, as far as downloading is concerned.
public struct NetworkStatus: Sendable, Equatable {
    /// Whether there is a usable connection at all.
    public var isConnected: Bool
    /// Cellular or a Personal Hotspot: the data may be metered.
    public var isExpensive: Bool
    /// Low Data Mode is on for this network: the user asked apps to use as little of it as they can.
    public var isConstrained: Bool

    public init(isConnected: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static let online = NetworkStatus(isConnected: true)
    public static let offline = NetworkStatus(isConnected: false)
}

/// Why downloads are not starting.
public enum NetworkBlock: Sendable, Equatable {
    /// There is no connection. Nothing can be done about it; downloads continue when it is back.
    case offline
    /// The connection is a Personal Hotspot or cellular, and the user asked to keep downloads off those.
    case expensive
    /// Low Data Mode is on for this network, and the user asked to respect it.
    case constrained
}

/// Which kinds of connection downloads may use.
public struct NetworkPolicy: Sendable, Equatable {
    /// Keep downloads off a Personal Hotspot or cellular connection.
    public var pauseOnExpensive: Bool
    /// Keep downloads off a network that is in Low Data Mode.
    public var pauseOnConstrained: Bool

    public init(pauseOnExpensive: Bool = false, pauseOnConstrained: Bool = true) {
        self.pauseOnExpensive = pauseOnExpensive
        self.pauseOnConstrained = pauseOnConstrained
    }

    /// Why a download may not use `status` under this policy, or `nil` when it may. Being offline always blocks.
    public func block(for status: NetworkStatus) -> NetworkBlock? {
        guard status.isConnected else { return .offline }
        if pauseOnExpensive, status.isExpensive { return .expensive }
        if pauseOnConstrained, status.isConstrained { return .constrained }
        return nil
    }
}

/// What the engine tells the app about the network: the connection, and whether it is holding downloads back.
public struct NetworkState: Sendable, Equatable {
    public var status: NetworkStatus
    /// Why queued downloads are not starting, or `nil` when they may.
    public var block: NetworkBlock?
    /// The user chose to download anyway on an expensive or constrained connection. It lasts until the connection
    /// changes.
    public var isOverridden: Bool

    public init(status: NetworkStatus = .online, block: NetworkBlock? = nil, isOverridden: Bool = false) {
        self.status = status
        self.block = block
        self.isOverridden = isOverridden
    }

    public static let unrestricted = NetworkState()
}

/// A source of network status. The engine is handed one, so tests (and a UI test hook) can stand in for the system.
public protocol NetworkMonitoring: Sendable {
    /// The status now. Waits for the first reading if the system has not given one yet.
    func currentStatus() async -> NetworkStatus
    /// The latest status first, then each change.
    func changes() -> AsyncStream<NetworkStatus>
}
