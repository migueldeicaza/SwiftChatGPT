//
//  Model.swift
//  
//
//  Created by Miguel de Icaza on 3/11/23.
//

import Foundation

// MARK: - Welcome
public struct Request: Codable {
    public var model: String
    public var messages: [Message]
    public var temperature: Int? = nil
    public var top_p: Int? = nil
    public var n: Int? = nil
    public var stream: Bool? = nil
    public var stop: Stop? = nil
    public var max_tokens: Int? = nil
    public var presence_penalty: Int? = nil
    public var frequency_penalty: Int? = nil
    public var user: String? = nil
}

// MARK: - Message
public struct Message: Codable {
    public let role: String?
    public let content: String
}

public enum Stop: Codable {
    case string(String)
    case stringArray([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode([String].self) {
            self = .stringArray(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        throw DecodingError.typeMismatch(Stop.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for Stop"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x):
            try container.encode(x)
        case .stringArray(let x):
            try container.encode(x)
        }
    }
}

public struct Response: Codable {
    public var id: String
    public var object: String
    public var created: Int
    public var error: ResponseError?
    public var choices: [Choice]
}

public struct ResponseError: Codable {
    public var message: String
    public var type: String
}

public struct Choice: Codable {
    public var index: Int
    public var message: Message?
    public var delta: Message?
    public var finish_reason: String?
}
