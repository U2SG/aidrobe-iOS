import AidrobeKit
import SwiftUI

/// The weather as the light falling on the page. Clothes are laid out flat, as
/// if on a table by a window, so the day outside shows up the way it does in a
/// real room: window light and the shade of its bars and a branch outside,
/// cloud shadow passing over, the flat falling-off light of a grey day, water
/// beading on the glass, snow at several distances, air thick with fog or dust,
/// a lamp at night.
///
/// Two shader passes (`WeatherLight.metal`): lighting, multiplied onto a light
/// page or added to a dark one, and whatever is in the air or on the glass,
/// drawn over. Both are driven only by `WeatherVisual`'s continuous amounts, so
/// windy and calm, light and heavy, morning and afternoon all look different
/// without a scene being written for each.
///
/// It sits over the page's content (light lands on things) and never takes touches.
struct WeatherLight: View {
    let visual: WeatherVisual
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date.now

    var body: some View {
        // Slow motion: 30 fps is smooth and easy on the battery; stop when not in front.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || scenePhase != .active)) { timeline in
            // Reduce Motion gets a still frame, so the light is there but at rest.
            let time = reduceMotion ? 40 : timeline.date.timeIntervalSince(start) + 40
            GeometryReader { proxy in
                let size = Shader.Argument.float2(proxy.size.width, proxy.size.height)
                let dark = Shader.Argument.float(colorScheme == .dark ? 1 : 0)
                ZStack {
                    Rectangle()
                        .colorEffect(ShaderLibrary.weatherLighting(
                            size, .float(time), dark,
                            .float(visual.openSky), .float(visual.cloud), .float(visual.rain), .float(visual.snow),
                            .float(visual.fog), .float(visual.dust),
                            .float(visual.wind), .float(visual.windSide), .float(visual.humidity), .float(visual.warmth),
                            .float(visual.elevation), .float(visual.sunSide), .float(visual.night),
                            .float(reduceMotion ? 0 : Self.flash(at: time) * visual.thunder)
                        ))
                        .blendMode(colorScheme == .dark ? .plusLighter : .multiply)
                    if visual.rain > 0 || visual.snow > 0 || visual.fog > 0 || visual.dust > 0 {
                        Rectangle()
                            .colorEffect(ShaderLibrary.weatherAir(
                                size, .float(time), dark,
                                .float(visual.rain), .float(visual.snow), .float(visual.fog), .float(visual.dust),
                                .float(visual.wind), .float(visual.windSide), .float(visual.humidity)
                            ))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Lightning: a quick double flicker every dozen seconds or so, kept faint.
    private static func flash(at time: Double) -> Double {
        let phase = time.truncatingRemainder(dividingBy: 13.7)
        guard phase < 0.6 else { return 0 }
        return max(exp(-phase * 16), 0.7 * exp(-abs(phase - 0.24) * 34))
    }
}

extension WeatherVisual {
    init(_ weather: Wire.WeatherContextResponse, hour: Double? = nil) {
        let now = Calendar.current.dateComponents([.hour, .minute], from: .now)
        self.init(
            condition: weather.condition,
            icon: weather.icon,
            temperatureC: weather.temperatureC,
            humidity: weather.humidity,
            windSpeed: weather.windSpeed,
            windScale: weather.windScale,
            windDirection: weather.windDir,
            hour: hour ?? Double(now.hour ?? 12) + Double(now.minute ?? 0) / 60
        )
    }
}
