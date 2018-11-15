import Apollo

public class SplitNetworkTransport: NetworkTransport {
  private let httpNetworkTransport: NetworkTransport
  private let webSocketNetworkTransport: NetworkTransport
  
  public init(httpNetworkTransport: NetworkTransport, webSocketNetworkTransport: NetworkTransport) {
    self.httpNetworkTransport = httpNetworkTransport
    self.webSocketNetworkTransport = webSocketNetworkTransport
  }
  
    public func send<Operation>(operation: Operation, optimistic: Bool, completionHandler: @escaping (GraphQLResponse<Operation>?, Error?) -> Void) -> Cancellable where Operation : GraphQLOperation {
    if operation.operationType == .subscription {
        return webSocketNetworkTransport.send(operation: operation, optimistic: false, completionHandler: completionHandler)
    } else {
        return httpNetworkTransport.send(operation: operation, optimistic: true, completionHandler: completionHandler)
    }
  }
}
