import AidrobeKit
import SwiftUI

/// Display copy for the backend's garment vocabulary.
enum Garment {
    static let categories = ["top", "bottom", "outerwear", "dress", "shoes"]

    static func category(_ raw: String?) -> String {
        switch raw {
        case "top": "上装"
        case "bottom": "下装"
        case "outer", "outerwear": "外套"
        case "dress": "连衣裙"
        case "shoes": "鞋"
        default: "配饰"
        }
    }

    static let colors: [(key: String, label: String, swatch: Color)] = [
        ("white", "白色", Color(red: 0.96, green: 0.95, blue: 0.92)),
        ("black", "黑色", Color(red: 0.14, green: 0.13, blue: 0.12)),
        ("gray", "灰色", Color(red: 0.56, green: 0.55, blue: 0.53)),
        ("beige", "米色", Color(red: 0.85, green: 0.78, blue: 0.66)),
        ("khaki", "卡其色", Color(red: 0.73, green: 0.64, blue: 0.48)),
        ("camel", "驼色", Color(red: 0.73, green: 0.54, blue: 0.33)),
        ("brown", "棕色", Color(red: 0.42, green: 0.27, blue: 0.19)),
        ("navy", "藏青色", Color(red: 0.14, green: 0.18, blue: 0.27)),
        ("blue", "蓝色", Color(red: 0.33, green: 0.47, blue: 0.68)),
        ("green", "绿色", Color(red: 0.37, green: 0.40, blue: 0.27)),
        ("red", "红色", Color(red: 0.66, green: 0.22, blue: 0.19)),
        ("pink", "粉色", Color(red: 0.89, green: 0.71, blue: 0.72)),
        ("yellow", "黄色", Color(red: 0.89, green: 0.76, blue: 0.36)),
        ("purple", "紫色", Color(red: 0.45, green: 0.36, blue: 0.56)),
    ]

    static func color(_ raw: String) -> String {
        colors.first { $0.key == raw.lowercased() }?.label ?? raw
    }

    static func swatch(_ raw: String) -> Color? {
        colors.first { $0.key == raw.lowercased() }?.swatch
    }

    static func status(_ status: Wire.WardrobeItemStatus) -> String {
        switch status {
        case .wearable: "可以穿"
        case .dirty: "待洗"
        case .unavailable: "暂时穿不了"
        case .lost: "找不到了"
        case .donated: "已送出"
        }
    }

    static func fit(_ raw: String) -> String {
        switch Wire.FitStatus(rawValue: raw) {
        case .fitsWell: "合身"
        case .loose: "偏松"
        case .tight: "偏紧"
        case .oversizedOk: "宽松，照样穿"
        case .needsAlteration: "要改一改"
        case .noLongerFits: "已经不合身"
        default: "还没记录"
        }
    }

    /// "2026-11-03" → "11月3日".
    static func day(_ raw: String?) -> String? {
        // A calendar date has no time zone: parse and print it in the same one (GMT).
        guard let raw, let date = try? Date.ISO8601FormatStyle().year().month().day().parse(raw) else { return nil }
        var style = Date.FormatStyle.dateTime.month().day().locale(Locale(identifier: "zh_CN"))
        style.timeZone = .gmt
        return date.formatted(style)
    }
}

func userMessage(for error: any Error) -> String {
    switch error {
    case APIError.network: "连不上服务，稍后再试"
    case let APIError.business(_, message): message.isEmpty ? "没有成功，再试一次" : message
    case let APIError.http(status, _, message, _):
        status == 429 ? "操作太频繁了，稍等一下" : (message ?? "没有成功，再试一次")
    case APIError.unauthorized: "登录已过期"
    default: "没有成功，再试一次"
    }
}
