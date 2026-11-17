import Foundation

/// Localizes known style tags while preserving the user's own wording.
public enum StylingText {
    public static func styles(_ raw: String) -> String {
        let labels = [
            "vivid": "鲜艳", "bright": "明亮", "colorful": "多彩", "bold": "大胆",
            "casual": "休闲", "clean": "利落", "soft": "柔和", "minimal": "简洁",
            "minimalist": "极简", "formal": "正式", "business": "商务", "professional": "干练",
            "smart casual": "日常通勤", "business casual": "商务休闲", "elegant": "优雅",
            "classic": "经典", "tailored": "挺括", "sporty": "运动", "sport": "运动",
            "athleisure": "运动休闲", "street": "街头", "streetwear": "街头",
            "vintage": "复古", "romantic": "浪漫", "relaxed": "松弛", "neutral": "中性色",
        ]
        var seen: Set<String> = []
        return raw.split { ",，、;；".contains($0) }.compactMap { part in
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let key = text.lowercased().replacingOccurrences(of: "_", with: " ")
            let label = labels[key] ?? text
            return seen.insert(label).inserted ? label : nil
        }.joined(separator: "、")
    }
}
