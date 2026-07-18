import Foundation

struct TelegramUpdate: Sendable {
    let updateID: Int
    let chatID: Int64?
    let text: String?
    let callbackID: String?
    let callbackData: String?
    let messageID: Int?
}

struct TelegramInlineButton: Sendable {
    let text: String
    let callbackData: String
}

actor TelegramBotClient {
    private var offset = 0

    func poll(token: String, handler: @escaping @Sendable (TelegramUpdate) async -> Void) async {
        while !Task.isCancelled {
            do {
                let updates = try await getUpdates(token: token)
                for update in updates {
                    offset = max(offset, update.updateID + 1)
                    await handler(update)
                }
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func sendMessage(
        token: String,
        chatID: Int64,
        text: String,
        parseMode: String? = nil,
        keyboard: [[TelegramInlineButton]]? = nil,
        replyKeyboard: [[String]]? = nil,
        silent: Bool = false
    ) async throws -> Int {
        let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["chat_id": chatID, "text": text]
        if let parseMode { payload["parse_mode"] = parseMode }
        if silent { payload["disable_notification"] = true }
        if let keyboard {
            payload["reply_markup"] = [
                "inline_keyboard": keyboard.map { row in
                    row.map { ["text": $0.text, "callback_data": $0.callbackData] }
                }
            ]
        } else if let replyKeyboard {
            payload["reply_markup"] = [
                "keyboard": replyKeyboard.map { row in row.map { ["text": $0] } },
                "is_persistent": true,
                "resize_keyboard": true,
                "input_field_placeholder": "选择一项操作"
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(request)
        let response = try JSONDecoder().decode(TelegramSentMessageResponse.self, from: data)
        guard response.ok else { throw TelegramError.api(response.description ?? "Telegram API error") }
        return response.result.messageID
    }

    func deleteMessage(token: String, chatID: Int64, messageID: Int) async throws {
        try await call(token: token, method: "deleteMessage", payload: [
            "chat_id": chatID,
            "message_id": messageID
        ])
    }

    func editMessage(
        token: String,
        chatID: Int64,
        messageID: Int,
        text: String,
        parseMode: String? = nil,
        keyboard: [[TelegramInlineButton]]? = nil
    ) async throws {
        var payload: [String: Any] = ["chat_id": chatID, "message_id": messageID, "text": text]
        if let parseMode { payload["parse_mode"] = parseMode }
        if let keyboard {
            payload["reply_markup"] = [
                "inline_keyboard": keyboard.map { row in
                    row.map { ["text": $0.text, "callback_data": $0.callbackData] }
                }
            ]
        }
        try await call(token: token, method: "editMessageText", payload: payload)
    }

    /// Validates the bot token via Telegram `getMe`.
    func getMe(token: String) async throws -> TelegramBotIdentity {
        let url = URL(string: "https://api.telegram.org/bot\(token)/getMe")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data = try await perform(request)
        let response = try JSONDecoder().decode(TelegramGetMeResponse.self, from: data)
        guard response.ok else { throw TelegramError.api(response.description ?? "Telegram getMe failed") }
        return TelegramBotIdentity(
            id: response.result.id,
            username: response.result.username,
            firstName: response.result.firstName
        )
    }

    func configureCommands(token: String) async throws {
        try await call(token: token, method: "deleteMyCommands", payload: [:])
        let url = URL(string: "https://api.telegram.org/bot\(token)/setMyCommands")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "commands": [
                ["command": "quota", "description": "查看额度"]
            ]
        ])
        try await perform(request)
        try await call(token: token, method: "setChatMenuButton", payload: [
            "menu_button": ["type": "commands"]
        ])
    }

    private func call(token: String, method: String, payload: [String: Any]) async throws {
        let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await perform(request)
    }

    func answerCallback(token: String, callbackID: String, text: String? = nil) async throws {
        let url = URL(string: "https://api.telegram.org/bot\(token)/answerCallbackQuery")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["callback_query_id": callbackID]
        if let text { payload["text"] = text }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try await perform(request)
    }

    private func getUpdates(token: String) async throws -> [TelegramUpdate] {
        var components = URLComponents(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "timeout", value: "25"), URLQueryItem(name: "allowed_updates", value: "[\"message\",\"callback_query\"]")]
        let (data, urlResponse) = try await URLSession.shared.data(from: components.url!)
        guard let http = urlResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw TelegramError.http }
        let apiResponse = try JSONDecoder().decode(TelegramResponse.self, from: data)
        guard apiResponse.ok else { throw TelegramError.api(apiResponse.description ?? "Telegram API error") }
        return apiResponse.result.map {
            TelegramUpdate(
                updateID: $0.updateID,
                chatID: $0.message?.chat.id ?? $0.callbackQuery?.message?.chat.id,
                text: $0.message?.text,
                callbackID: $0.callbackQuery?.id,
                callbackData: $0.callbackQuery?.data,
                messageID: $0.callbackQuery?.message?.messageID ?? $0.message?.messageID
            )
        }
    }

    @discardableResult
    private func perform(_ request: URLRequest) async throws -> Data {
        var lastError: Error = TelegramError.http
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw TelegramError.http }
                let result = try? JSONDecoder().decode(TelegramBasicResponse.self, from: data)
                if http.statusCode == 429 {
                    let wait = result?.parameters?.retryAfter ?? (attempt + 1) * 2
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
                guard (200..<300).contains(http.statusCode) else { throw TelegramError.http }
                guard result?.ok == true else { throw TelegramError.api(result?.description ?? "Telegram API error") }
                return data
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .seconds((attempt + 1) * 2)) }
            }
        }
        throw lastError
    }
}

struct TelegramBotIdentity: Sendable {
    let id: Int64
    let username: String?
    let firstName: String
}

private struct TelegramGetMeResponse: Decodable {
    let ok: Bool
    let result: TelegramBotUser
    let description: String?
}

private struct TelegramBotUser: Decodable {
    let id: Int64
    let username: String?
    let firstName: String

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case firstName = "first_name"
    }
}

private struct TelegramSentMessageResponse: Decodable {
    let ok: Bool
    let result: TelegramSentMessage
    let description: String?
}

private struct TelegramSentMessage: Decodable {
    let messageID: Int
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
}

private enum TelegramError: LocalizedError {
    case http
    case api(String)

    var errorDescription: String? {
        switch self {
        case .http: "无法连接 Telegram API"
        case .api(let message): message
        }
    }
}

private struct TelegramBasicResponse: Decodable {
    let ok: Bool
    let description: String?
    let parameters: TelegramResponseParameters?
}

private struct TelegramResponseParameters: Decodable {
    let retryAfter: Int?
    enum CodingKeys: String, CodingKey { case retryAfter = "retry_after" }
}

private struct TelegramResponse: Decodable {
    let ok: Bool
    let result: [TelegramRawUpdate]
    let description: String?
}

private struct TelegramRawUpdate: Decodable {
    let updateID: Int
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?
    enum CodingKeys: String, CodingKey { case updateID = "update_id"; case message; case callbackQuery = "callback_query" }
}

private struct TelegramCallbackQuery: Decodable {
    let id: String
    let data: String?
    let message: TelegramMessage?
}

private struct TelegramMessage: Decodable {
    let messageID: Int
    let text: String?
    let chat: TelegramChat
    enum CodingKeys: String, CodingKey { case messageID = "message_id"; case text; case chat }
}

private struct TelegramChat: Decodable { let id: Int64 }
