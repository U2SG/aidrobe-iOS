import AidrobeKit
import SwiftUI

/// The weather as light behind a page: the paper colour, tinted near the top
/// by what the sky is doing right now and fading to plain paper below. It is
/// meant to be noticed the way a window is — without being looked at.
///
/// Drawn with Canvas rather than a Metal shader so the app needs no extra
/// toolchain; a few blurred shapes and thin strokes are all it takes.
struct WeatherBackground: View {
    let visual: WeatherVisual
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date.now

    private var isDark: Bool { colorScheme == .dark }
    private var palette: SkyPalette { SkyPalette(visual, dark: isDark) }

    var body: some View {
        ZStack {
            Color.background
            // The sky's colour, strongest at the top edge, gone by two thirds of the way down.
            LinearGradient(
                stops: [
                    .init(color: palette.sky.opacity(palette.strength), location: 0),
                    .init(color: palette.sky.opacity(palette.strength * 0.45), location: 0.33),
                    .init(color: palette.sky.opacity(0), location: 0.66),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // 30 fps is plenty for drifting cloud; stop entirely when the app is not in front.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
                Canvas { context, size in
                    drawLamp(&context, size: size, time: time)
                    drawCloud(&context, size: size, time: time)
                    drawFog(&context, size: size, time: time)
                    drawRain(&context, size: size, time: time)
                    drawSnow(&context, size: size, time: time)
                }
            }
            .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.78)))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.9), value: visual)
    }

    // MARK: Layers

    /// Sun, or the moon at night: a soft glow in the upper right that cloud and rain put out.
    private func drawLamp(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let open = (1 - palette.overcast * 0.9) * (1 - palette.wet * 0.8) * (1 - visual.fog * 0.6)
        guard open > 0.02 else { return }
        let center = CGPoint(x: size.width * 0.82, y: size.width * 0.14)
        let radius = size.width * 0.85 * (1 + sin(time * 0.25) * 0.02)
        let peak = (isDark ? 0.22 : 0.34) * open * (1 - visual.night * 0.4)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: palette.lamp.opacity(peak), location: 0),
                    .init(color: palette.lamp.opacity(peak * 0.35), location: 0.4),
                    .init(color: palette.lamp.opacity(0), location: 1),
                ]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
    }

    /// A few wide, very soft shapes crossing slowly; faster when it is windy.
    private func drawCloud(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        guard palette.overcast > 0.1 else { return }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: size.width * 0.09))
            let speed = 0.004 + visual.wind * 0.012
            for index in 0..<6 {
                let seed = Self.unit(index, 1)
                let span = 1.6
                let x = ((seed * span + time * speed * (0.6 + Self.unit(index, 2) * 0.8)).truncatingRemainder(dividingBy: span) - 0.3) * size.width
                let y = (0.02 + Self.unit(index, 3) * 0.34) * size.height
                let width = (0.45 + Self.unit(index, 4) * 0.45) * size.width
                let height = width * (0.26 + Self.unit(index, 5) * 0.14)
                layer.fill(
                    Path(ellipseIn: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)),
                    with: .color(palette.cloud.opacity((0.25 + Self.unit(index, 6) * 0.35) * palette.overcast))
                )
            }
        }
    }

    /// Pale bands that slide sideways.
    private func drawFog(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        guard visual.fog > 0 else { return }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: size.width * 0.12))
            for index in 0..<3 {
                let x = sin(time * 0.05 + Double(index) * 2.1) * size.width * 0.12
                let y = (0.08 + Double(index) * 0.16) * size.height
                layer.fill(
                    Path(roundedRect: CGRect(x: x - size.width * 0.2, y: y, width: size.width * 1.4, height: size.height * 0.07), cornerRadius: 30),
                    with: .color(palette.fog.opacity(0.5 * visual.fog))
                )
            }
        }
    }

    /// Fine slanted streaks at two depths.
    private func drawRain(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        guard visual.rain > 0 else { return }
        let count = Int(50 + visual.rain * 70)
        let slant = 0.08 + visual.wind * 0.3
        let fall = size.height * 0.8
        for index in 0..<count {
            let depth = 0.5 + Self.unit(index, 7) * 0.5           // far streaks are shorter, slower, fainter
            let progress = (Self.unit(index, 8) + time * (0.55 + visual.rain * 0.5) * depth).truncatingRemainder(dividingBy: 1)
            let length = (12 + 16 * depth) * (0.8 + visual.rain * 0.5)
            let y = progress * fall
            let x = Self.unit(index, 9) * size.width * 1.2 - y * slant
            var streak = Path()
            streak.move(to: CGPoint(x: x, y: y))
            streak.addLine(to: CGPoint(x: x - length * slant, y: y + length))
            context.stroke(
                streak,
                with: .color(palette.streak.opacity((0.10 + 0.16 * depth) * (0.6 + visual.rain * 0.4))),
                style: StrokeStyle(lineWidth: 0.6 + depth * 0.5, lineCap: .round)
            )
        }
    }

    /// Slow flakes with a little sway.
    private func drawSnow(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        guard visual.snow > 0 else { return }
        let count = Int(30 + visual.snow * 50)
        let fall = size.height * 0.8
        for index in 0..<count {
            let depth = 0.4 + Self.unit(index, 10) * 0.6
            let progress = (Self.unit(index, 11) + time * (0.035 + visual.snow * 0.03) * depth).truncatingRemainder(dividingBy: 1)
            let sway = sin(time * 0.6 * depth + Double(index)) * 10
            let x = Self.unit(index, 12) * size.width + sway + time * visual.wind * 6 * depth
            let radius = 1.0 + depth * 1.8
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x.truncatingRemainder(dividingBy: size.width) - radius, y: progress * fall - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(palette.flake.opacity(0.25 + 0.45 * depth))
            )
        }
    }

    /// Stable pseudo-random number in 0…1 for item `index`, stream `salt`.
    private static func unit(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
}

/// Colours for one sky, on a light page or a dark one.
private struct SkyPalette {
    let sky: Color
    let strength: Double
    let lamp: Color
    let cloud: Color
    let fog: Color
    let streak: Color
    let flake: Color
    let overcast: Double
    let wet: Double

    init(_ visual: WeatherVisual, dark: Bool) {
        wet = max(visual.rain, visual.snow * 0.6)
        overcast = min(visual.cloud + visual.fog * 0.3, 1)

        typealias RGB = SIMD3<Double>
        func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * min(max(t, 0), 1) }
        func color(_ rgb: RGB) -> Color { Color(red: rgb.x, green: rgb.y, blue: rgb.z) }

        var tone: RGB
        if dark {
            let clear = mix(RGB(0.17, 0.22, 0.32), RGB(0.30, 0.22, 0.14), visual.warmth * 0.5)
            let grey = mix(RGB(0.21, 0.22, 0.24), RGB(0.16, 0.20, 0.26), wet)
            tone = mix(clear, grey, overcast)
            tone = mix(tone, RGB(0.24, 0.24, 0.24), visual.fog * 0.6)
            tone = mix(tone, RGB(0.09, 0.12, 0.22), visual.night * 0.7)
        } else {
            let clear = mix(RGB(0.74, 0.85, 0.97), RGB(0.99, 0.87, 0.70), visual.warmth * 0.55)
            let grey = mix(RGB(0.70, 0.75, 0.80), RGB(0.55, 0.62, 0.71), wet)
            tone = mix(clear, grey, overcast)
            tone = mix(tone, RGB(0.86, 0.87, 0.86), visual.fog * 0.6)
            tone = mix(tone, RGB(0.36, 0.42, 0.58), visual.night * 0.6)
        }
        sky = color(tone)
        strength = min((dark ? 0.9 : 0.62) * (0.6 + overcast * 0.2 + wet * 0.2 + visual.night * 0.15), 1)

        let sun = mix(RGB(1.0, 0.78, 0.45), RGB(1.0, 0.64, 0.30), visual.warmth)
        lamp = color(mix(sun, RGB(0.74, 0.82, 1.0), visual.night))
        cloud = dark ? color(RGB(0.40, 0.42, 0.46)) : color(mix(RGB(0.55, 0.58, 0.62), RGB(0.40, 0.45, 0.52), wet))
        fog = dark ? color(RGB(0.36, 0.36, 0.36)) : color(RGB(0.97, 0.97, 0.96))
        streak = dark ? color(RGB(0.72, 0.78, 0.88)) : color(RGB(0.30, 0.36, 0.46))
        flake = dark ? color(RGB(0.92, 0.93, 0.95)) : color(RGB(0.99, 0.99, 1.0))
    }
}

extension WeatherVisual {
    init(_ weather: Wire.WeatherContextResponse, at date: Date = .now) {
        self.init(
            condition: weather.condition,
            icon: weather.icon,
            temperatureC: weather.temperatureC,
            windSpeed: weather.windSpeed,
            hour: Calendar.current.component(.hour, from: date)
        )
    }
}
