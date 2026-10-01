import Foundation

enum WallConfiguration {
    static var serverURL: URL { configuredURL(key: "WallServerURL", fallback: "https://wall.example.invalid") }
    static var siftURL: URL { configuredURL(key: "WallSiftServerURL", fallback: "https://sift.example.invalid/cloud/") }

    static func configuredURL(key: String, fallback: String, info: [String: Any]? = Bundle.main.infoDictionary) -> URL {
        guard let raw = info?[key] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return URL(string: fallback)! }
        return url
    }
}
