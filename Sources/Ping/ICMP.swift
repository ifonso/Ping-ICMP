//
//  ICMP.swift
//  
//
//  Created by Afonso Lucas on 01/12/23.
//

import Foundation

// MARK: - ICMP Header
public struct ICMPHeader {
    var type: UInt8
    var code: UInt8
    var checksum: UInt16
    
    /// Identifier
    var identifier: UInt16
    /// Sequence number
    var sequenceNumber: UInt16
    
    /// UUID payload
    var payload: uuid_t
}

public enum ICMPType: UInt8 {
    case EchoReply = 0
    case EchoRequest = 8
}

public enum ICMPErrors: Error {
    case CHECKSUM_ERROR, PAYLOAD_LENGTH_ERROR, CHECKSUM_OUT_OF_BOUND_ERROR
}
