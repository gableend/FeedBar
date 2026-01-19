import Foundation

// ✅ Removed @MainActor - this service is stateless and can run on any thread
final class AIDiscoveryService: Sendable {
    static let shared = AIDiscoveryService()
    
    private let apiKey = Secrets.openAIKey

    func discoverFeeds(for topic: String) async throws -> [CustomFeed] {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return [] }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        Suggest 5 high-quality, VALID RSS feed URLs for the topic: "\(topic)".
        Rules:
        - Prefer known, major domains.
        - Do not guess.
        - Format the output as strictly valid JSON.
        
        {
          "feeds": [
            {"name": "Feed Name", "url": "https://...", "category": "Topic"}
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
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let jsonString = openAIResponse.choices.first?.message.content,
              let jsonData = jsonString.data(using: .utf8) else {
            return []
        }
        
        let decodedResponse = try JSONDecoder().decode(AIResponse.self, from: jsonData)
        let candidates = decodedResponse.feeds
        
        var validFeeds: [CustomFeed] = []
        
        // Use TaskGroup to verify URLs in parallel
        await withTaskGroup(of: CustomFeed?.self) { group in
            for feedItem in candidates {
                group.addTask {
                    if await self.verifyURL(feedItem.url) {
                        // ✅ FIXED: No await needed because init and normalizedDomain are now nonisolated
                        let domain = BrandIconProvider.normalizedDomain(feedItem.url)
                        return CustomFeed(
                            name: feedItem.name,
                            url: feedItem.url,
                            category: feedItem.category,
                            domain: domain
                        )
                    }
                    return nil
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
    
    private func verifyURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        } catch {
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

private struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
