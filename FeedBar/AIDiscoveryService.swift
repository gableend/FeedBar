import Foundation

class AIDiscoveryService {
    static let shared = AIDiscoveryService()
    
    // Ensure this points to your valid Secrets file
    private let apiKey = Secrets.openAIKey

    func discoverFeeds(for topic: String) async throws -> [CustomFeed] {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return [] }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 1. ENHANCED PROMPT: Ask for MORE options so we can filter out the bad ones
        let prompt = """
        You are a helpful assistant.
        Task: Suggest 5 high-quality, VALID RSS feed URLs for the topic: "\(topic)".
        
        Rules:
        - Prefer known, major domains (e.g. CNN, TechCrunch, ESPN) over obscure blogs.
        - Do not guess. If you are unsure, provide a general category feed.
        - Format the output as a strictly valid JSON object.
        
        Required JSON Structure:
        {
          "feeds": [
            {"name": "Feed Name", "url": "https://...", "domain": "domain.com"}
          ]
        }
        """

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": "You output only valid JSON."],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // 2. FETCH RAW SUGGESTIONS
        let (data, _) = try await URLSession.shared.data(for: request)
        
        // Debugging
        if let debugString = String(data: data, encoding: .utf8) {
            AppLog.info("🤖 AI Raw Suggestion: \(debugString)")
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let jsonString = openAIResponse.choices.first?.message.content,
              let jsonData = jsonString.data(using: .utf8) else {
            return []
        }
        
        let decodedResponse = try JSONDecoder().decode(AIResponse.self, from: jsonData)
        let candidates = decodedResponse.feeds
        
        AppLog.info("🔎 Validating \(candidates.count) candidates...")
        
        // 3. REAL-TIME VALIDATION (The "Anti-Hallucination" Layer)
        // We verify every single URL in parallel before showing it to you.
        var validFeeds: [CustomFeed] = []
        
        await withTaskGroup(of: CustomFeed?.self) { group in
            for feed in candidates {
                group.addTask {
                    if await self.verifyURL(feed.url) {
                        AppLog.info("✅ Verified: \(feed.url)")
                        return feed
                    } else {
                        AppLog.warn("❌ Dead Link: \(feed.url)")
                        return nil
                    }
                }
            }
            
            for await result in group {
                if let valid = result {
                    validFeeds.append(valid)
                }
            }
        }
        
        return validFeeds
    }
    
    // 4. VERIFICATION HELPER
    // Sends a lightweight "HEAD" request to see if the server responds 200 OK
    private func verifyURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD" // Just check headers, don't download body
        request.timeoutInterval = 4 // Fail fast
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        } catch {
            // Fallback: Some servers block HEAD, try a quick GET
            var getRequest = URLRequest(url: url)
            getRequest.httpMethod = "GET"
            getRequest.timeoutInterval = 4
            if let (_, response) = try? await URLSession.shared.data(for: getRequest),
               let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        }
        return false
    }
}

// MARK: - Internal Wrapper Models
private struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
