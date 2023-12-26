//
//  Pinger.swift
//  
//
//  Created by Afonso Lucas on 01/12/23.
//

import Foundation
import Darwin


enum SockErrors: Error {
    case SIGPIPE_ERROR, TTL_ERROR
}

public class SocketInfo {
    public weak var pinger: Pinger?
    public let identifier: UInt16
    
    public init(pinger: Pinger, identifier: UInt16) {
        self.pinger = pinger
        self.identifier = identifier
    }
}

public class Pinger {
    // MARK: - Socket properties
    private let _serial: DispatchQueue
    
    private var ttl: Int
    
    private var socket: CFSocket?
    private var unmanagedSocketInfo: Unmanaged<SocketInfo>?
    private var socketSource: CFRunLoopSource?
    
    // MARK: - Pinger
    
    /// A random identifier which is a part of the ping request.
    private let identifier = UInt16.random(in: 0..<UInt16.max)
    /// A random UUID fingerprint sent as the payload.
    private let fingerprint = UUID()
    
    private var isPinging: Bool
    private var sequenceIndex: UInt16 = 0
    private let timeoutInterval: TimeInterval = 1
    
    init() {
        self._serial = DispatchQueue(label: "socket.icmp.response.queue")
        self.ttl = 64
        
        self.isPinging = false
        
        try! createSocket()
    }
    
    /// Socket callback
    private func callback(socket: CFSocket, didReadData data: Data?) {
        guard let data = data else { return }
        print("Recive data: \(data as NSData)")
    }
    
    private func createSocket() throws {
        try _serial.sync {
            let info = SocketInfo(pinger: self, identifier: identifier)
            unmanagedSocketInfo = Unmanaged.passRetained(info)
            var context = CFSocketContext(version: 0,
                                          info: unmanagedSocketInfo!.toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
            
            // Creating socket
            socket = CFSocketCreate(kCFAllocatorDefault,
                                    AF_INET,
                                    SOCK_DGRAM,
                                    IPPROTO_ICMP,
                                    CFSocketCallBackType.dataCallBack.rawValue, { socket, type, address, data, info in
                guard let socket = socket, let info = info, let data = data else { return }
                
                /// `Unmanaged` -> estrutura que fornece uma maneira de gerenciar a retenção e liberação de objetos de referência quando estamos interagindo com APIs que trabalham com ponteiros opacos.
                let socketInfo = Unmanaged<SocketInfo>
                    /// Cria de maneira insegura um socketInfo a partir de um ponteiro opaco `UnsafeMutableRawPointer`
                    .fromOpaque(info)
                    /// Obtendo a referênca sem aumentar a contagem do ARC
                    .takeUnretainedValue()
                
                let pinger = socketInfo.pinger
                
                if (type as CFSocketCallBackType) == CFSocketCallBackType.dataCallBack {
                    pinger?.callback(socket: socket,
                                     didReadData: Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data)
                }
                
            }, &context)
            
            /// Configurando a opção SO_NOSIGPIPE no soquete para evitar que o envio de dados para uma conexão fechada resulte em um sinal SIGPIPE.
            let handle = CFSocketGetNative(socket)
            
            var value: Int32 = 1
            let sigpipe_err = setsockopt(
                // O descritor de arquivo nativo do soquete.
                handle,
                // O nível da opção (opçao geral).
                SOL_SOCKET,
                // Opçao especificada.
                SO_NOSIGPIPE,
                // Um ponteiro para o valor que será configurado.
                &value,
                // Tamanho do valor, convertido para socklen_t.
                socklen_t(MemoryLayout.size(ofValue: value)))
            
            guard sigpipe_err == 0 else {
                throw SockErrors.SIGPIPE_ERROR
            }
            
            /// Configurando TTL
            let ttl_err = setsockopt(
                handle,
                IPPROTO_IP,
                IP_TTL,
                &ttl,
                socklen_t(MemoryLayout.size(ofValue: ttl)))
            
            guard ttl_err == 0 else {
                throw SockErrors.TTL_ERROR
            }
            
            // Passando tudo para o main run loop
            socketSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), socketSource, .commonModes)
        }
    }
    
    func sendPing(destination address: Data) {
        guard let ICMPPacket = try? self.createICMPPackage(identifier: UInt16(self.identifier),
                                                           sequenceNumber: UInt16(self.sequenceIndex))
        else {
            print("Error while creating ICMP packet")
            return
        }
        _serial.async {
            guard let socket = self.socket else { return }
            let socketError = CFSocketSendData(socket,
                                               address as CFData,
                                               ICMPPacket as CFData,
                                               self.timeoutInterval)
            
            if socketError == .error {
                print("Um erro ocorreu ao enviar o pacote: \(socketError)")
            } else if socketError == .success {
                print("ICMP enviado")
            } else {
                print("Timeout")
            }
        }
    }
}

extension Pinger {
    /// Creates an ICMP package.
    private func createICMPPackage(identifier: UInt16, sequenceNumber: UInt16) throws -> Data {
        var header = ICMPHeader(type: ICMPType.EchoRequest.rawValue,
                                code: 0,
                                checksum: 0,
                                identifier: CFSwapInt16HostToBig(identifier),
                                sequenceNumber: CFSwapInt16HostToBig(sequenceNumber),
                                payload: fingerprint.uuid)
        
        // Assumindo que o tamanho do payload não difere do MemoryLayout<uuid_t>.size
        let additional = [UInt8]()
        
        let checksum = try computeChecksum(header: header, additionalPayload: additional)
        header.checksum = checksum
        
        return Data(bytes: &header, count: MemoryLayout<ICMPHeader>.size) + Data(additional)
    }
    
    // MARK: - Utility
    private func computeChecksum(header: ICMPHeader, additionalPayload: [UInt8]) throws -> UInt16 {
        let typecode = Data([header.type, header.code]).withUnsafeBytes { $0.load(as: UInt16.self) }
        var sum = UInt64(typecode) + UInt64(header.identifier) + UInt64(header.sequenceNumber)
        let payload = convert(payload: header.payload) + additionalPayload
        
        guard payload.count % 2 == 0
        else { throw ICMPErrors.PAYLOAD_LENGTH_ERROR }
        
        var i = 0
        while i < payload.count {
            guard payload.indices.contains(i + 1)
            else { throw ICMPErrors.PAYLOAD_LENGTH_ERROR }
            // Convert two 8 byte ints to one 16 byte int
            sum += Data([payload[i], payload[i + 1]]).withUnsafeBytes { UInt64($0.load(as: UInt16.self)) }
            i += 2
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }

        guard sum < UInt16.max
        else { throw ICMPErrors.CHECKSUM_OUT_OF_BOUND_ERROR }
        
        return ~UInt16(sum)
    }
    
    private func convert(payload: uuid_t) -> [UInt8] {
        let p = payload
        return [p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9, p.10, p.11, p.12, p.13, p.14, p.15].map { UInt8($0) }
    }
}
