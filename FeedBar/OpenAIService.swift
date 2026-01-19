import Foundation

enum OpenAIService {
    struct OpenAIError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Model Preferences
    private static let modelPrimary = "gpt-4o"
    private static let modelFallback = "gpt-4o-mini" // Cheaper, faster fallback

    // MARK: - Sentiment Analysis
    static func classifySentimentAndSummarize(
        session: URLSession,
        apiKey: String,
        headlines: [String]
    ) async throws -> NewsSentiment { // ✅ FIXED: Removed FeedManager.
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError(message: "Missing OpenAI API key.")
        }

        let prompt = buildSentimentPrompt(headlines: headlines)

        do {
            return try await callSentiment(session: session, apiKey: apiKey, model: modelPrimary, prompt: prompt)
        } catch {
            return try await callSentiment(session: session, apiKey: apiKey, model: modelFallback, prompt: prompt)
        }
    }

    // MARK: - 3-Word Summary (For Future/Trends)
    static func generateThreeWordSummary(
        session: URLSession,
        apiKey: String,
        headlines: [String],
        context: String
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError(message: "Missing OpenAI API key.")
        }
        
        let textChunk = headlines.prefix(25).map { "- \($0)" }.joined(separator: "\n")
        
        let prompt = """
        Analyze these headlines regarding "\(context)".
        Identify the single most specific, dominant trend or event.
        Output EXACTLY three words that summarize it.
        
        CRITICAL RULES:
        1. NO generic pairings like "TECHNOLOGY AND SOCIETY" or "DATA AND AI".
        2. NO conjunctions ("AND", "&").
        3. Use CONCRETE NOUNS and ACTIVE VERBS.
        4. Be provocative and specific.
        
        Format: UPPERCASE. No punctuation.
        
        Headlines:
        \(textChunk)
        """
        
        return try await callSummary(session: session, apiKey: apiKey, model: modelFallback, prompt: prompt)
    }

    // MARK: - API Calls
    private static func callSentiment(
        session: URLSession,
        apiKey: String,
        model: String,
        prompt: String
    ) async throws -> NewsSentiment { // ✅ FIXED: Removed FeedManager.
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenAIError(message: "Bad OpenAI endpoint URL.")
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": "You output strict JSON only."],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"]
        ]

        let data = try await performRequest(session: session, url: url, apiKey: apiKey, body: body)
        
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String,
            let contentData = content.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
            let levelStr = payload["level"] as? String,
            let three = payload["threeWordSummary"] as? String
        else {
            throw OpenAIError(message: "Could not parse OpenAI sentiment response.")
        }

        // ✅ FIXED: Removed FeedManager prefix from Level and Init
        let level = NewsSentiment.Level(rawValue: levelStr.lowercased()) ?? .amber
        let cleanThree = three.trimmingCharacters(in: .whitespacesAndNewlines)

        return NewsSentiment(level: level, threeWordSummary: cleanThree, computedAt: Date())
    }
    
    private static func callSummary(
        session: URLSession,
        apiKey: String,
        model: String,
        prompt: String
    ) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenAIError(message: "Bad OpenAI endpoint URL.")
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.5,
            "messages": [
                ["role": "system", "content": "You are a concise trend analyst."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 20
        ]

        let data = try await performRequest(session: session, url: url, apiKey: apiKey, body: body)
        
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenAIError(message: "Could not parse OpenAI summary response.")
        }
        
        return content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ".", with: "")
            .uppercased()
    }
    
    private static func performRequest(session: URLSession, url: URL, apiKey: String, body: [String: Any]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpBody = bodyData
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        
        guard (200...299).contains(code) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError(message: "OpenAI HTTP \(code). \(snippet.prefix(200))")
        }
        
        return data
    }
    
    // Helper to build the prompt for sentiment analysis
    private static func buildSentimentPrompt(headlines: [String]) -> String {
        let clipped = headlines.prefix(50).map { "- \($0)" }.joined(separator: "\n")
        return """
        Analyze these headlines for market/social sentiment.
        Return JSON with level (green/amber/red) and threeWordSummary.
        Headlines:
        \(clipped)
        """
    }
}
