//
//  SwiftChatGPT.swift
//
//
//  Created by Miguel de Icaza on 3/11/23.
//
import Foundation

public enum OpenAIError: Error {
    case serializationError
    case networkError(String)
    case responseError(Int, String)
    case apiError(String)
    
    public var description: String {
        switch self {
        case .serializationError:
            return "Internal error creating a request"
        case .networkError (let detail):
            return "Network communication error: \(detail)"
        case .responseError(let code, let detail):
            return "Error processing the error response for HTTP code \(code): \(detail)"
        case .apiError(let detail):
            return "OpenAI API error: \(detail)"
        }
    }
}

struct OpenAIErrorJson: Codable {
    
}
/// Access to ChatGPT API from OpenAI
public class ChatGPT: NSObject, URLSessionDataDelegate {
    let defaultSystemMessage = Message(role: "system", content: "You are a helpful assistant.")
    let openAiApiUrl = URL (string: "https://api.openai.com/v1/chat/completions")!
    let urlSessionConfig: URLSessionConfiguration
    var session: URLSession!
    public var key: String
    var history: [Message] = []
    let decoder = JSONDecoder()
    public var model = "gpt-3.5-turbo"
    
    /// Initializes SwiftChatGPT with an OpenAI API key
    /// - Parameter key: an OpenAI API Key
    public init (key: String) {
        self.key = key
        if key.last == "\n" {
            print ("This key ends with a newline, are you sure this is ok?")
        }
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

    func startRequest (for input: String, temperature: Float) async -> Result<URLSession.AsyncBytes,OpenAIError> {
        let requestMessages = buildMessageHistory (newPrompt: input)
        let chatRequest = Request(model: self.model, messages: requestMessages, temperature: temperature, stream: true)
        guard let data = try? JSONEncoder().encode(chatRequest) else {
            return .failure(.serializationError)
        }
        let request = makeUrlRequest (data: data)

        
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: self)
        } catch (let e){
            return .failure(.networkError (e.localizedDescription))
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.networkError("Internal error: httpResponse is not an HTTPURLResponse"))
        }
        guard httpResponse.statusCode == 200 else {
            var data = Data ()
            do {
                for try await x in bytes {
                    data.append(x)
                }
            } catch (let e){
                return .failure(.networkError (e.localizedDescription))
            }
            do {
                let short: ShortResponse = try JSONDecoder().decode(ShortResponse.self, from: data)
                return .failure (.apiError (short.error.message))
            } catch (let e) {
                return .failure(.responseError(httpResponse.statusCode, e.localizedDescription))
            }
        }
        return .success(bytes)
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
    public func streamChatResponses (_ input: String, temperature: Float = 1.0) async -> Result <AsyncThrowingStream<Response,Error>,OpenAIError> {
        switch await startRequest (for: input, temperature: temperature) {
        case .success(let bytes):
            var result = ""
            let reply = processPartialReply (bytes: bytes) { response in
                
                if let c = response.choices.first?.delta?.content {
                    result += c
                }
                return response
            } onComplete: {
                self.recordInteraction (prompt: input, reply: result)
            }
            return .success(reply)
        case .failure(let error):
            return .failure(error)
        }
    }
    
    /// Sends the input as the new chat and returns a an async stream of strings
    ///
    /// Usage:
    /// for try await response in chat.streamChatResponses ("Hello") { print (response) }
    ///
    public func streamChatText (_ input: String, temperature: Float = 1.0) async ->  Result <AsyncThrowingStream<String?,Error>, OpenAIError> {
        switch await startRequest(for: input, temperature: temperature) {
        case .success(let bytes):
            var result = ""
            let reply = processPartialReply (bytes: bytes) { response -> String? in
                if let f = response.choices.first?.delta?.content {
                    result += f
                    return f
                }
                return nil
            } onComplete: {
                self.recordInteraction (prompt: input, reply: result)
            }
            return .success (reply)
        case .failure(let error):
            return .failure (error)
        }
    }
}
