import Foundation

/// Shipped, read-only AI/dev terms that bias recognition without polluting the
/// user's personal list. Spec section 4 "Dictionary lifecycle". Deliberately small.
public enum BaseVocabulary {
    public static let terms: [String] = [
        "Claude", "Claude Code", "Codex", "Anthropic", "OpenAI", "Whisper",
        "Deepgram", "Nova-3",
        "MCP", "LLM", "RAG", "agent", "token", "repo", "PR", "Supabase",
        "Next.js", "Vercel", "Stripe", "Bedrock", "Tailwind", "TypeScript",
        "Karko AI", "Useful Voice", "SwiftUI", "Xcode", "GitHub", "API", "JSON",
        "endpoint", "deployment", "Azure", "prompt", "embeddings", "fine-tune",
        "webhook", "Postgres", "Redis", "Docker", "Kubernetes",
    ]
}
