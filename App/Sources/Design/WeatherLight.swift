import AidrobeKit
import SwiftUI

/// The weather as the light falling on the page. Clothes are laid out flat, as
/// if on a table by a window, so the day outside shows up the way it does in a
/// real room:
/// - clear: warm window light across most of the page, the window's bars and a
///   branch's dappled shade (overlapping soft discs, as real leaf shadow is)
///   in cool shadow;
/// - cloudy: the same light fading and returning as cloud passes; overcast is
///   simply flat, slightly cool light — nothing is drawn that a grey day lacks;
/// - rain: beads of water on the glass, each with a dark upper rim, a bright
///   lower edge and a glint, and now and then one that runs;
/// - snow: flakes at three distances, the near ones large and out of focus;
/// - fog: contrast washed out; night: a lamp's pool.
///
/// It sits over the page's content (light lands on things) and never takes
/// touches. Lighting darkens a light page (multiply) and brightens a dark one
/// (additive); water, flakes and fog are drawn normally on top.
/// Canvas, not Metal: no extra toolchain, and soft discs are all real light is.
struct WeatherLight: View {
    let visual: WeatherVisual
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date.now

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        // Everything here moves slowly; 24 fps is smooth enough and easy on the battery.
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || scenePhase != .active)) { timeline in
            // Reduce Motion gets a still frame, so the light is there but at rest.
            let time = reduceMotion ? 40 : timeline.date.timeIntervalSince(start) + 40
            ZStack {
                Canvas { context, size in
                    let scene = Scene(visual: visual, dark: isDark, size: size, time: time)
                    scene.drawAir(&context)
                    scene.drawSunlight(&context)
                    scene.drawLamp(&context)
                }
                .blendMode(isDark ? .plusLighter : .multiply)
                Canvas { context, size in
                    let scene = Scene(visual: visual, dark: isDark, size: size, time: time)
                    scene.drawFog(&context)
                    scene.drawRainOnGlass(&context)
                    scene.drawSnow(&context)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct Scene {
    let visual: WeatherVisual
    let dark: Bool
    let size: CGSize
    let time: Double

    private var wet: Double { max(visual.rain, visual.snow * 0.6) }
    private var overcast: Double { min(visual.cloud + visual.fog * 0.3, 1) }
    private var bounds: CGRect { CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80) }

    /// How much direct sun reaches the page right now. Partly cloudy skies let
    /// it come and go over half a minute or so.
    private var sun: Double {
        let open = (1 - min(wet * 1.4, 1)) * (1 - visual.fog) * (1 - visual.night * 0.75)
        let passing = 0.5 + 0.5 * sin(time * 0.11) * sin(time * 0.043 + 1.3)
        let covered = overcast * (0.5 + 0.5 * passing)
        return max(0, open * (1 - covered * 1.1))
    }

    // MARK: Lighting

    /// Flat daylight has a colour too: a touch cooler and dimmer under cloud or rain, bluish in snow.
    func drawAir(_ context: inout GraphicsContext) {
        guard !dark else { return }
        let flat = (0.10 * overcast + 0.24 * visual.rain) * (1 - sun)
        if flat > 0.01 {
            context.fill(Path(bounds), with: .color(Color(red: 0.84, green: 0.88, blue: 0.93).opacity(flat)))
        }
        if visual.snow > 0 {
            context.fill(Path(bounds), with: .color(Color(red: 0.90, green: 0.94, blue: 1.0).opacity(0.3 * visual.snow)))
        }
    }

    /// Direct sun through a window. Most of the page is lit and faintly warm;
    /// what the window frame and a branch outside block falls into cool shade.
    func drawSunlight(_ context: inout GraphicsContext) {
        guard sun > 0.03 else { return }
        let window = windowPath()
        let bars = barsPath()
        let low = visual.night              // dusk and dawn: weaker, redder light
        var edge = context
        edge.addFilter(.blur(radius: size.width * 0.016))       // the frame is close: a tight penumbra
        var leafy = context
        leafy.addFilter(.blur(radius: size.width * 0.024))      // the branch is far: softer

        if dark {
            let warm = Color(red: 1.0, green: 0.76 - low * 0.12, blue: 0.48 - low * 0.16)
            edge.drawLayer { layer in
                layer.fill(window, with: .color(warm.opacity(0.085 * sun)))
                layer.blendMode = .destinationOut
                layer.fill(bars, with: .color(.black.opacity(0.85)))
                for leaf in leaves() {
                    layer.fill(leaf.path, with: .color(.black.opacity(leaf.density)))
                }
            }
        } else {
            // Shade is lit only by the sky, so it is cooler than the light.
            let shade = Color(red: 0.80, green: 0.84, blue: 0.91)
            let depth = 0.40 * sun
            edge.drawLayer { layer in
                layer.fill(Path(bounds), with: .color(shade.opacity(depth)))
                layer.blendMode = .destinationOut
                layer.fill(window, with: .color(.black))
                layer.blendMode = .normal
                layer.fill(bars, with: .color(shade.opacity(depth * 0.9)))
            }
            leafy.drawLayer { layer in
                for leaf in leaves() {
                    layer.fill(leaf.path, with: .color(shade.opacity(min(1, depth * 1.7 * leaf.density))))
                }
            }
            // The lit part takes the sun's warmth.
            let warm = Color(red: 1.0, green: 0.972 - low * 0.05, blue: 0.915 - low * 0.12)
            edge.fill(window, with: .color(warm.opacity(0.42 * sun)))
        }
    }

    /// The window's outline as low sun throws it across a table: a wide sheared quad.
    private var cast: CGAffineTransform {
        CGAffineTransform(a: 1, b: 0.10, c: 0.36, d: 1, tx: -size.width * 0.20 + sin(time * 0.05) * 2, ty: size.height * 0.045)
    }

    private func windowPath() -> Path {
        Path(CGRect(x: 0, y: 0, width: size.width * 1.02, height: size.height * 0.80)).applying(cast)
    }

    /// One upright and two cross bars.
    private func barsPath() -> Path {
        let thickness = size.width * 0.03
        var path = Path()
        path.addRect(CGRect(x: size.width * 0.50, y: 0, width: thickness, height: size.height * 0.80))
        for row in [0.265, 0.535] {
            path.addRect(CGRect(x: 0, y: size.height * row, width: size.width * 1.02, height: thickness))
        }
        return path.applying(cast)
    }

    /// A branch reaching in from the upper right. Real leaf shade is many
    /// overlapping soft discs of different density with coins of sun between
    /// them; each one moves a little, more when it is windy.
    private func leaves() -> [(path: Path, density: Double)] {
        let sway = 2.5 + visual.wind * 16
        return (0..<52).map { index in
            let along = unit(index, 5)
            let spread = (unit(index, 6) - 0.5) * 0.42
            let center = CGPoint(
                x: size.width * (1.04 - along * 0.78 + spread * 0.7),
                y: size.height * (0.02 + along * 0.46 + spread * 0.5)
            )
            let phase = Double(index) * 1.31
            let dx = sin(time * 0.6 + phase) * sway + sin(time * 0.23 + phase * 2) * sway * 0.5
            let dy = cos(time * 0.45 + phase) * sway * 0.5
            let radius = size.width * (0.028 + unit(index, 7) * 0.075) * (1 - along * 0.3)
            let stretch = 0.7 + unit(index, 8) * 0.6
            let disc = Path(ellipseIn: CGRect(x: -radius, y: -radius * stretch, width: radius * 2, height: radius * 2 * stretch))
            let placed = disc.applying(
                CGAffineTransform(translationX: center.x + dx, y: center.y + dy).rotated(by: unit(index, 9) * .pi)
            )
            return (placed, 0.3 + unit(index, 10) * 0.6)
        }
    }

    /// After dark the light is a lamp: a warm pool from one side, the rest of the page falling away.
    func drawLamp(_ context: inout GraphicsContext) {
        guard visual.night > 0.5 else { return }
        let center = CGPoint(x: size.width * 0.16, y: size.height * 0.10)
        let radius = size.height * 0.95
        if dark {
            let warm = Color(red: 1.0, green: 0.70, blue: 0.40)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: warm.opacity(0.10), location: 0),
                        .init(color: warm.opacity(0.03), location: 0.45),
                        .init(color: warm.opacity(0), location: 1),
                    ]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )
        } else {
            let dusk = Color(red: 0.70, green: 0.66, blue: 0.70)
            context.fill(Path(bounds), with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(red: 1.0, green: 0.95, blue: 0.86).opacity(0.5), location: 0),
                    .init(color: dusk.opacity(0.25), location: 0.45),
                    .init(color: dusk.opacity(0.6), location: 1),
                ]),
                center: center, startRadius: 0, endRadius: radius
            ))
        }
    }

    // MARK: In the air, on the glass

    /// Fog takes contrast away, most of all far off (the top of the page), and drifts.
    func drawFog(_ context: inout GraphicsContext) {
        guard visual.fog > 0 else { return }
        let veil = dark ? Color(red: 0.42, green: 0.42, blue: 0.42) : Color(red: 0.97, green: 0.97, blue: 0.96)
        let amount = (dark ? 0.16 : 0.34) * visual.fog
        context.fill(Path(bounds), with: .linearGradient(
            Gradient(colors: [veil.opacity(amount), veil.opacity(amount * 0.35)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
        ))
        var soft = context
        soft.addFilter(.blur(radius: size.width * 0.14))
        for index in 0..<3 {
            let x = sin(time * 0.04 + Double(index) * 2.1) * size.width * 0.25
            let y = size.height * (0.10 + Double(index) * 0.24)
            soft.fill(
                Path(ellipseIn: CGRect(x: x - size.width * 0.2, y: y, width: size.width * 1.4, height: size.height * 0.13)),
                with: .color(veil.opacity(amount * 0.55))
            )
        }
    }

    /// Rain seen from indoors: water beading on the glass. A bead bends the
    /// light, so its upper edge is dark, its lower edge bright, with a glint
    /// where the sky reflects. Most sit still and slowly dry; a few gather and run.
    func drawRainOnGlass(_ context: inout GraphicsContext) {
        guard visual.rain > 0 else { return }
        for index in 0..<Int(34 + visual.rain * 52) {
            let life = (unit(index, 12) + time * 0.008).truncatingRemainder(dividingBy: 1)
            let presence = min(1, sin(life * .pi) * 2.2)
            let radius = (1.3 + pow(unit(index, 9), 2) * 3.4) * (0.75 + 0.25 * presence)
            let center = CGPoint(x: unit(index, 10) * size.width, y: unit(index, 11) * size.height)
            drawBead(&context, at: center, radius: radius, presence: presence)
        }

        let travel = size.height * 1.3
        for index in 0..<Int(3 + visual.rain * 6) {
            let pace = (14 + unit(index, 13) * 30) * (0.7 + visual.rain * 0.6)
            // Runs stick and slip rather than slide evenly.
            let slip = time * pace + sin(time * 0.9 + Double(index) * 2.4) * 14
            let head = (unit(index, 14) * travel + slip).truncatingRemainder(dividingBy: travel) - size.height * 0.15
            let x0 = unit(index, 15) * size.width
            func x(at y: Double) -> Double {
                x0 + sin(y * 0.019 + Double(index)) * 6 + sin(y * 0.051 + Double(index) * 3) * 2 - y * visual.wind * 0.05
            }
            // The wet track it leaves: a thin brighter line that thins out behind.
            let length = 60 + unit(index, 16) * 120
            for segment in 0..<5 {
                let from = head - length * Double(segment + 1) / 5
                let to = head - length * Double(segment) / 5
                var track = Path()
                track.move(to: CGPoint(x: x(at: from), y: from))
                for step in 1...5 {
                    let y = from + (to - from) * Double(step) / 5
                    track.addLine(to: CGPoint(x: x(at: y), y: y))
                }
                let fade = 1 - Double(segment) / 5
                context.stroke(
                    track,
                    with: .color((dark ? Color(red: 0.80, green: 0.88, blue: 1.0) : Color.white).opacity((dark ? 0.10 : 0.34) * fade)),
                    style: StrokeStyle(lineWidth: 1.6 * fade + 0.5, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    track.offsetBy(dx: 0.9, dy: 0),
                    with: .color(Color(red: 0.24, green: 0.30, blue: 0.40).opacity((dark ? 0.0 : 0.07) * fade)),
                    style: StrokeStyle(lineWidth: 0.6, lineCap: .round, lineJoin: .round)
                )
            }
            drawBead(&context, at: CGPoint(x: x(at: head), y: head), radius: 4.2 + unit(index, 17) * 1.6, presence: 1)
        }
    }

    private func drawBead(_ context: inout GraphicsContext, at center: CGPoint, radius: Double, presence: Double) {
        guard presence > 0.02 else { return }
        let body = CGRect(x: center.x - radius, y: center.y - radius * 1.15, width: radius * 2, height: radius * 2.3)
        let rim = dark ? Color.black : Color(red: 0.22, green: 0.29, blue: 0.40)
        let lit = dark ? Color(red: 0.82, green: 0.89, blue: 1.0) : Color.white
        // The shadow it casts on the page, down and to the side.
        context.fill(
            Path(ellipseIn: body.offsetBy(dx: radius * 0.35, dy: radius * 0.6)),
            with: .color(rim.opacity((dark ? 0.25 : 0.09) * presence))
        )
        context.fill(Path(ellipseIn: body), with: .linearGradient(
            Gradient(stops: [
                .init(color: rim.opacity((dark ? 0.45 : 0.26) * presence), location: 0),
                .init(color: rim.opacity(0.03 * presence), location: 0.45),
                .init(color: lit.opacity((dark ? 0.30 : 0.75) * presence), location: 1),
            ]),
            startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)
        ))
        let glint = max(0.5, radius * 0.24)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius * 0.42, y: center.y - radius * 0.62, width: glint * 2, height: glint * 2)),
            with: .color(Color.white.opacity((dark ? 0.55 : 0.9) * presence))
        )
    }

    /// Snow at three distances: far flakes small and many, near ones large,
    /// quick and out of focus. They fall on a slant and wander.
    func drawSnow(_ context: inout GraphicsContext) {
        guard visual.snow > 0 else { return }
        let layers: [(count: Int, radius: Double, blur: Double, pace: Double, alpha: Double)] = [
            (Int(30 + visual.snow * 44), 1.9, 0.5, 7, 1.0),
            (Int(14 + visual.snow * 20), 3.4, 1.6, 12, 0.85),
            (Int(5 + visual.snow * 7), 9.0, 5.5, 20, 0.5),
        ]
        let travel = size.height * 1.2
        let span = size.width * 1.5
        for (depth, flakes) in layers.enumerated() {
            var soft = context
            soft.addFilter(.blur(radius: flakes.blur))
            for index in 0..<flakes.count {
                let id = index + depth * 97
                let pace = flakes.pace * (0.75 + unit(id, 18) * 0.5) * (0.8 + visual.snow * 0.4)
                let y = (unit(id, 19) * travel + time * pace).truncatingRemainder(dividingBy: travel) - size.height * 0.1
                let wander = sin(time * 0.45 + Double(id) * 1.9) * (8 + Double(depth) * 6)
                let x = (unit(id, 20) * span + wander - y * (0.08 + visual.wind * 0.3)).truncatingRemainder(dividingBy: span)
                let radius = flakes.radius * (0.7 + unit(id, 21) * 0.6)
                let flake = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                if dark {
                    soft.fill(flake, with: .color(Color.white.opacity(0.55 * flakes.alpha)))
                } else {
                    // White on paper only shows by the shade around it: a cool halo, a white heart.
                    soft.fill(flake, with: .color(Color(red: 0.48, green: 0.56, blue: 0.72).opacity(0.5 * flakes.alpha)))
                    soft.fill(
                        Path(ellipseIn: CGRect(x: x - radius * 0.55, y: y - radius * 0.55, width: radius * 1.1, height: radius * 1.1)),
                        with: .color(Color.white.opacity(0.85 * flakes.alpha))
                    )
                }
            }
        }
    }

    /// Stable pseudo-random number in 0…1 for item `index`, stream `salt`.
    private func unit(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return value - value.rounded(.down)
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
