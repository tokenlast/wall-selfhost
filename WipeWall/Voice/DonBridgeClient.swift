import Foundation

struct DonBridgeClient {
    struct Request: Encodable { let text: String }
    struct Response: Decodable { let text: String }

    let endpoint: URL?

    func respond(to text: String) async throws -> String {
        guard let endpoint else { throw BridgeError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(Request(text: text))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw BridgeError.badResponse
        }
        return try JSONDecoder().decode(Response.self, from: data).text
    }

    enum BridgeError: Error {
        case notConfigured
        case badResponse
    }
}

