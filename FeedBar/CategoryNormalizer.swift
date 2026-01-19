import Foundation

enum CategoryNormalizer {
    
    // ✅ DYNAMIC: Takes the list of categories currently in your DB
    // and finds the best home for a new feed.
    static func match(feedName: String, url: String, liveCategories: Set<String>) -> String {
        let combined = "\(url) \(feedName)".lowercased()
        
        // 1. Define Keyword Mappings (The "Logic")
        // We map keywords to "Concepts", then find which Live Category matches that concept.
        let mappings: [(keywords: [String], concept: String)] = [
            (["tech", "code", "apple", "software", "developer", "ai", "gpt"], "tech"),
            (["finance", "market", "business", "money", "crypto", "economy"], "business"),
            (["finance", "market", "business", "money", "crypto", "economy"], "finance"),
            (["space", "nasa", "physics", "science", "biology"], "science"),
            (["sport", "football", "soccer", "nba", "nfl", "f1"], "sport"),
            (["movie", "film", "celebrity", "music", "gaming", "entertainment"], "entertainment"),
            (["design", "art", "arch", "photo"], "design"),
            (["health", "food", "wellness"], "health"),
            (["news", "politics", "world", "bbc", "cnn"], "news")
        ]
        
        // 2. Find the "Concept" for this feed
        var detectedConcept: String?
        for mapping in mappings {
            if mapping.keywords.contains(where: { combined.contains($0) }) {
                detectedConcept = mapping.concept
                break
            }
        }
        
        // 3. Find a LIVE category that matches the concept
        if let concept = detectedConcept {
            // Look for a server category that contains this concept (case-insensitive)
            // e.g. Concept "tech" matches Server Category "Tech & Programming"
            if let match = liveCategories.first(where: { $0.lowercased().contains(concept) }) {
                return match
            }
        }
        
        // 4. Fallback: If no smart match, check if the name itself partially matches a category
        if let partialMatch = liveCategories.first(where: { combined.contains($0.lowercased()) }) {
            return partialMatch
        }
        
        return "General"
    }
}
