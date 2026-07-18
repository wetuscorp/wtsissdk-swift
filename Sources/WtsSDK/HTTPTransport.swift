import Foundation

protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
  let session: URLSession

  init(session: URLSession = .shared) { self.session = session }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw WtsSDKError.invalidResponse(fallbackURL: nil)
    }
    return (data, response)
  }
}
