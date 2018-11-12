import Foundation
import CommonCrypto

extension URLSessionTask: Cancellable {}

/// A transport-level, HTTP-specific error.
public struct GraphQLHTTPResponseError: Error, LocalizedError {
  public enum ErrorKind {
    case errorResponse
    case invalidResponse

    var description: String {
      switch self {
      case .errorResponse:
        return "Received error response"
      case .invalidResponse:
        return "Received invalid response"
      }
    }
  }

  /// The body of the response.
  public let body: Data?
  /// Information about the response as provided by the server.
  public let response: HTTPURLResponse
  public let kind: ErrorKind

  public var bodyDescription: String {
    if let body = body {
      if let description = String(data: body, encoding: response.textEncoding ?? .utf8) {
        return description
      } else {
        return "Unreadable response body"
      }
    } else {
      return "Empty response body"
    }
  }

  public var errorDescription: String? {
    return "\(kind.description) (\(response.statusCode) \(response.statusCodeDescription)): \(bodyDescription)"
  }
}

internal class URLSessionDataTaskWrapper: Cancellable {
  var task: URLSessionDataTask? = nil

  func cancel() {
    task?.cancel()
  }
}

/// A network transport that uses HTTP POST requests to send GraphQL operations to a server, and that uses `URLSession` as the networking implementation.
public class HTTPNetworkTransport: NetworkTransport {
  let url: URL
  let apq: Bool
  let session: URLSession
  let serializationFormat = JSONSerializationFormat.self

  private var apqSupported = true

  /// Creates a network transport with the specified server URL and session configuration.
  ///
  /// - Parameters:
  ///   - url: The URL of a GraphQL server to connect to.
  ///   - configuration: A session configuration used to configure the session. Defaults to `URLSessionConfiguration.default`.
  ///   - apq: Whether to use automatic persisted queries.
  ///   - sendOperationIdentifiers: Whether to send operation identifiers rather than full operation text, for use with servers that support query persistence. Defaults to false.
  public init(url: URL, configuration: URLSessionConfiguration = URLSessionConfiguration.default, apq: Bool = false, sendOperationIdentifiers: Bool = false) {
    self.url = url
    self.session = URLSession(configuration: configuration)
    self.apq = apq
    self.sendOperationIdentifiers = sendOperationIdentifiers
  }

  /// Send a GraphQL operation to a server and return a response.
  ///
  /// - Parameters:
  ///   - operation: The operation to send.
  ///   - optimistic: A boolean that indicates whether the request should optimistically use automatic persisted querying (when relevant). This only works if apq is also turned on on the client itself.
  ///   - completionHandler: A closure to call when a request completes.
  ///   - response: The response received from the server, or `nil` if an error occurred.
  ///   - error: An error that indicates why a request failed, or `nil` if the request was succesful.
  /// - Returns: An object that can be used to cancel an in progress request.
  public func send<Operation>(operation: Operation, optimistic: Bool, completionHandler: @escaping (_ response: GraphQLResponse<Operation>?, _ error: Error?) -> Void) -> Cancellable {
    func buildRequest() -> URLRequest {
      var apqRequest: URLRequest? = nil
      let apqPotential = apq && apqSupported && operation.operationType == .query
      if apqPotential && optimistic {
        let body = requestBody(for: operation, withQuery: false, withAPQ: true)

        var components = URLComponents()
        components.queryItems = body.map { tuple in
          guard let value = tuple.value,
            let serializedData = (try? serializationFormat.serialize(value: value)),
            let serialized = String(data: serializedData, encoding: String.Encoding.utf8) else {
              return URLQueryItem(name: tuple.key, value: "")
          }
          return URLQueryItem(name: tuple.key, value: serialized)
        }

        if let url_ = components.url(relativeTo: url) {
          apqRequest = URLRequest(url: url_)
          apqRequest?.httpMethod = "GET"
        }
      }

      var request: URLRequest
      if let apqRequest = apqRequest {
        request = apqRequest
      }
      else {
        request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = requestBody(for: operation, withQuery: true, withAPQ: apqPotential)

        request.httpBody = try! serializationFormat.serialize(value: body)
      }
      return request
    }

    let request = buildRequest()

    let taskWrapper = URLSessionDataTaskWrapper()
    let task = session.dataTask(with: request) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
      if error != nil {
        completionHandler(nil, error)
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        fatalError("Response should be an HTTPURLResponse")
      }

      if (!httpResponse.isSuccessful) {
        completionHandler(nil, GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .errorResponse))
        return
      }

      guard let data = data else {
        completionHandler(nil, GraphQLHTTPResponseError(body: nil, response: httpResponse, kind: .invalidResponse))
        return
      }

      do {
        guard let body =  try self?.serializationFormat.deserialize(data: data) as? JSONObject else {
          throw GraphQLHTTPResponseError(body: data, response: httpResponse, kind: .invalidResponse)
        }

        if let errors_ = body["errors"], let errors = errors_ as? [Any] {
          for error_ in errors {
            if let error = error_ as? [String: Any], let message = error["message"] as? String {
              switch message {
              case "PersistedQueryNotSupported":
                self?.apqSupported = false
                fallthrough
              case "PersistedQueryNotFound":
                if let newTaskWrapper = self?.send(operation: operation, optimistic: false, completionHandler: completionHandler) as? URLSessionDataTaskWrapper {
                  taskWrapper.task = newTaskWrapper.task
                }
                else {
                  completionHandler(nil, GraphQLError(message))
                }
                return
              default:
                break
              }
            }
          }
        }

        let response = GraphQLResponse(operation: operation, body: body)
        completionHandler(response, nil)
      } catch {
        completionHandler(nil, error)
      }
    }

    taskWrapper.task = task

    task.resume()

    return taskWrapper
  }

  private let sendOperationIdentifiers: Bool

  private func requestBody<Operation: GraphQLOperation>(for operation: Operation, withQuery: Bool, withAPQ: Bool) -> GraphQLMap {

    func sha256DigestAsHex(str: String) -> String {
      let data = str.data(using: .utf8)!
      var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))

      _ = digest.withUnsafeMutableBytes { (digestBytes) in
        data.withUnsafeBytes { (stringBytes) in
          CC_SHA256(stringBytes, CC_LONG(data.count), digestBytes)
        }
      }
      return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    if sendOperationIdentifiers {
      guard let operationIdentifier = operation.operationIdentifier else {
        preconditionFailure("To send operation identifiers, Apollo types must be generated with operationIdentifiers")
      }
      return ["id": operationIdentifier, "variables": operation.variables]
    }

    var body: GraphQLMap = [:]

    if !withAPQ {
        body["variables"] = operation.variables
    }
    else if let variables = operation.variables, variables.count > 0 {
        body["variables"] = variables
    }

    if withQuery {
      body["query"] = operation.queryDocument
    }

    if withAPQ {
      body["extensions"] = ["persistedQuery": ["version": 1, "sha256Hash": sha256DigestAsHex(str: operation.queryDocument)]]
    }

    return body
  }
}
