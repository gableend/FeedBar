import Foundation

enum OpenAIService {
    struct OpenAIError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Uses your current model name preference.
    // If the API rejects it, you can fallback in one place.
    private static let modelPrimary = "gpt-5.2"
    private static let modelFallback = "gpt-4.1-mini"

    static func classifySentimentAndSummarize(
        session: URLSession,
        apiKey: String,
        headlines: [String]
    ) async throws -> FeedManager.NewsSentiment {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIError(message: "Missing OpenAI API key.")
        }

        let prompt = buildPrompt(headlines: headlines)

        // Try primary model, then fallback if needed.
        do {
            return try await call(session: session, apiKey: apiKey, model: modelPrimary, prompt: prompt)
        } catch {
            return try await call(session: session, apiKey: apiKey, model: modelFallback, prompt: prompt)
        }
    }

    private static func buildPrompt(headlines: [String]) -> String {
        let clipped = headlines.prefix(60).map { "- \($0)" }.joined(separator: "\n")
        return """
You are classifying today's news mood for a tiny UI indicator.

Return ONLY valid JSON in this exact schema:
{
  "level": "green" | "amber" | "red",
  "threeWordSummary": "Exactly three words"
}

Rules:
- "green" = broadly positive / calm.
- "amber" = mixed / uncertain / volatile.
- "red" = broadly negative / risk-off / crisis signals.
- threeWordSummary must be exactly three words, title case, no punctuation.

Headlines:
\(clipped)
"""
    }

    private static func call(
        session: URLSession,
        apiKey: String,
        model: String,
        prompt: String
    ) async throws -> FeedManager.NewsSentiment {
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

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = bodyData
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? -1

        guard (200...299).contains(code) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError(message: "OpenAI HTTP \(code). \(snippet.prefix(300))")
        }

        // Parse: choices[0].message.content is JSON text
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
            throw OpenAIError(message: "Could not parse OpenAI response JSON.")
        }

        let level = FeedManager.NewsSentiment.Level(rawValue: levelStr.lowercased()) ?? .amber
        let cleanThree = three.trimmingCharacters(in: .whitespacesAndNewlines)

        return FeedManager.NewsSentiment(level: level, threeWordSummary: cleanThree, computedAt: Date())
    }
}
