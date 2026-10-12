import Foundation

/// Connection details for one herdr gateway, as encoded in the pairing QR:
/// `herdr-ios://pair?url=<wss url>&token=<token>`.
public struct GatewayEndpoint: Sendable, Hashable, Codable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notAPairingLink
        case missingURL
        case invalidURL(String)
        case missingToken

        public var errorDescription: String? {
            switch self {
            case .notAPairingLink: "That isn't a herdr pairing link."
            case .missingURL: "The pairing link has no gateway URL."
            case .invalidURL(let s): "Gateway URL must be ws:// or wss:// (got \(s))."
            case .missingToken: "The pairing link has no token."
            }
        }
    }

    public static let scheme = "herdr-ios"

    public init(pairingLink: String) throws {
        let trimmed = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), comps.scheme == Self.scheme, comps.host == "pair" else {
            throw ParseError.notAPairingLink
        }
        let items = comps.queryItems ?? []
        guard let rawURL = items.first(where: { $0.name == "url" })?.value, !rawURL.isEmpty else {
            throw ParseError.missingURL
        }
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw ParseError.missingToken
        }
        try self.init(urlString: rawURL, token: token)
    }

    public init(urlString: String, token: String) throws {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              url.host != nil
        else { throw ParseError.invalidURL(s) }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ParseError.missingToken }
        self.init(url: url, token: t)
    }

    /// Display form without the scheme and the default /ws path.
    public var displayHost: String {
        var s = url.host ?? url.absoluteString
        if let port = url.port { s += ":\(port)" }
        return s
    }
}
