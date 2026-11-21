import Foundation

/// Optional online name lookup for a barcode, from Open Food Facts. Only ever runs when someone taps
/// "Look Up Name Online"; scanning and naming work fully offline.
///
/// - Sends only the barcode. No account, no personal details, no contact email.
/// - Read endpoint and found/not-found shape per https://openfoodfacts.github.io/openfoodfacts-server/api/
///   (`status` 1 = found, 0 = not found). Reads need no authentication, only an app User-Agent.
/// - Data is ODbL; the app shows "Name from Open Food Facts" with a link to the product page wherever it's used.
enum ProductLookup {
    enum Failure: LocalizedError {
        case badCode, notFound, offline, unavailable
        var errorDescription: String? {
            switch self {
            case .badCode: "That doesn’t look like a product barcode."
            case .notFound: "Open Food Facts doesn’t know this barcode. Type the name in instead."
            case .offline: "No internet connection. Type the name in; it’s remembered for next time."
            case .unavailable: "Open Food Facts didn’t answer. Try again later, or type the name in."
            }
        }
    }

    struct Product: Equatable {
        let name: String
        let code: String
        var pageURL: URL? { URL(string: "https://world.openfoodfacts.org/product/\(code)") }
    }

    /// A generic app identifier with the real version, for Open Food Facts and every other download. No personal email.
    nonisolated static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "OfflineKit/\(version) (personal offline preparedness app)"
    }

    /// Digits only; product barcodes are 8 to 14 digits.
    static func normalize(_ code: String) -> String? {
        let digits = code.filter(\.isNumber)
        return (8...14).contains(digits.count) ? digits : nil
    }

    static func lookUp(_ code: String) async throws -> Product {
        guard let digits = normalize(code),
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=product_name,brands")
        else { throw Failure.badCode }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                           .dataNotAllowed, .timedOut].contains(error.code) {
            throw Failure.offline
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
        struct Reply: Decodable {
            struct Item: Decodable { let product_name: String?; let brands: String? }
            let status: Int?
            let product: Item?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.unavailable }
        guard reply.status == 1, let name = reply.product?.product_name?.trimmingCharacters(in: .whitespaces), !name.isEmpty
        else { throw Failure.notFound }
        let brand = reply.product?.brands?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let full = brand.isEmpty || name.localizedCaseInsensitiveContains(brand) ? name : "\(name) (\(brand))"
        return Product(name: full, code: digits)
    }
}
