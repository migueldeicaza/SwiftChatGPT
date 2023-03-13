//
//  SwiftChatGPT.swift
//
//
//  Created by Miguel de Icaza on 3/11/23.
//
import Foundation

public enum ChatError: Error {
    case responseError
}

/// Access to ChatGPT API from OpenAI
public class ChatGPT: NSObject, URLSessionDataDelegate {
    let defaultSystemMessage = Message(role: "system", content: "You are a helpful assistant.")
    let openAiApiUrl = URL (string: "https://api.openai.com/v1/chat/completions")!
    let urlSessionConfig: URLSessionConfiguration
    var session: URLSession!
    let key: String
    var history: [Message] = []
    let decoder = JSONDecoder()
    
    /// Initializes SwiftChatGPT with an OpenAI API key
    /// - Parameter key: an OpenAI API Key
    public init (key: String) {
        self.key = key
        urlSessionConfig = URLSessionConfiguration.default
        urlSessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlSessionConfig.urlCache = nil
        
        super.init()
        session = URLSession(configuration: urlSessionConfig, delegate: self, delegateQueue: .main)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        print ("Got DATA")
        if let str = String (bytes: data, encoding: .utf8) {
            print ("\(str)")
        }

    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        print ("Another")
        return .allow
    }

    /// Creates a request fro contacting the chat API
    /// - Parameter data: the JSON encoded payload to post
    func makeUrlRequest (data: Data) -> URLRequest {
        var request = URLRequest(url: openAiApiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        request.httpBody = data
        return request
    }
    
    func buildMessageHistory (newPrompt: String) -> [Message] {
        var prompt = Message(role: "user", content: newPrompt)
        var requestMessages: [Message] = [defaultSystemMessage]
        requestMessages.append(contentsOf: history)
        requestMessages.append (prompt)
        return requestMessages
    }

    func startRequest (for input: String) async -> URLSession.AsyncBytes? {
        let requestMessages = buildMessageHistory (newPrompt: input)
        let chatRequest = Request(model: "gpt-3.5-turbo", messages: requestMessages, stream: true)
        guard let data = try? JSONEncoder().encode(chatRequest) else {
            return nil
        }
        let request = makeUrlRequest (data: data)

        // Iterate using bytes
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: self) else {
            return nil
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200 else {
            return nil
        }
        return bytes
    }
    
    func processPartialReply<T> (bytes: URLSession.AsyncBytes, _ f: @escaping (Response) -> T, onComplete: @escaping () -> ()) -> AsyncThrowingStream<T,Error> {
        return AsyncThrowingStream (bufferingPolicy: .unbounded) { continuation in
            Task {
                for try await line in bytes.lines {
                    if line.starts(with: "data: {") {
                        let rest = line.index(line.startIndex, offsetBy: 6)
                        let data: Data = line [rest...].data(using: .utf8)!
                        
                        if let response = try? decoder.decode(Response.self, from: data) {
                            continuation.yield(f (response))
                        }
                    } else if line.starts(with: "data: [DONE]") {
                        break
                    }
                }
                onComplete ()
                continuation.finish()
            }
        }
    }
    
    func recordInteraction (prompt: String, reply: String) {
        history.append (Message (role: "user", content: prompt));
        history.append (Message (role: "assistant", content: reply));
    }
    
    /// Sends the input as the new chat and returns a an async stream of responses
    ///
    /// Usage:
    /// for try await response in chat.streamChatResponses ("Hello") { print (response) }
    ///
    public func streamChatResponses (_ input: String) async throws -> AsyncThrowingStream<Response,Error>? {
        guard let bytes = await startRequest (for: input) else {
            return nil
        }
        var result = ""
        return processPartialReply (bytes: bytes) { response in
            
            if let c = response.choices.first?.delta?.content {
                result += c
            }
            return response
        } onComplete: {
            self.recordInteraction (prompt: input, reply: result)
        }
    }
    
    /// Sends the input as the new chat and returns a an async stream of strings
    ///
    /// Usage:
    /// for try await response in chat.streamChatResponses ("Hello") { print (response) }
    ///
    public func streamChatText (_ input: String) async throws -> AsyncThrowingStream<String?,Error>? {
        guard let bytes = await startRequest (for: input) else {
            return nil
        }
        var result = ""
        return processPartialReply (bytes: bytes) { response in
            if let f = response.choices.first?.delta?.content {
                result += f
                return f
            }
            return nil
        } onComplete: {
            self.recordInteraction (prompt: input, reply: result)
        }
    }
}
