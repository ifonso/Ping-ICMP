import Foundation
import Darwin

public struct Ping {

    public init() {}
    
    func buildAddress(address: String) -> Data {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = UInt8(AF_INET)
        socketAddress.sin_port = 0
        socketAddress.sin_addr.s_addr = inet_addr(address.cString(using: .utf8))
        return Data(bytes: &socketAddress, count: MemoryLayout<sockaddr_in>.size)
    }
    
    func ping(address: String) {
        let ping = Pinger()
        ping.sendPing(destination: buildAddress(address: "10.49.49.83"))
    }
}
