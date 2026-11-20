import AppKit
import SwiftUI

private extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

private struct MacOSSquircleShell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.clear
            let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
            content()
                .frame(width: 824, height: 824)
                .clipShape(shape)
                .overlay(
                    shape
                        .strokeBorder(
                            AngularGradient(
                                stops: [
                                    .init(color: Color(hex: 0x38BDF8, opacity: 0.42), location: 0.05),
                                    .init(color: Color(hex: 0x272932, opacity: 0.55), location: 0.25),
                                    .init(color: Color(hex: 0xFBBF24, opacity: 0.55), location: 0.58),
                                    .init(color: Color(hex: 0x525766, opacity: 0.65), location: 0.72),
                                    .init(color: Color(hex: 0x1F2128, opacity: 0.50), location: 0.88),
                                    .init(color: Color(hex: 0x38BDF8, opacity: 0.42), location: 1.00),
                                ],
                                center: .center
                            ),
                            lineWidth: 3.0
                        )
                )
                .overlay(
                    shape
                        .inset(by: 3.0)
                        .strokeBorder(Color.black.opacity(0.65), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.36), radius: 24, x: 0, y: 12)
                .shadow(color: .black.opacity(0.20), radius: 6, x: 0, y: 3)
        }
        .frame(width: 1024, height: 1024)
    }
}

private struct GlassSequenceCard: View {
    var width: CGFloat
    var height: CGFloat
    var fillTop: Color
    var fillBottom: Color
    var rimPrimary: Color
    var rimSecondary: Color
    var glowColor: Color
    var showPickSpark: Bool = false

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        ZStack(alignment: .topTrailing) {
            cardShape
                .fill(
                    LinearGradient(
                        colors: [fillTop, fillBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .inset(by: 16)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1.2)
                )
                .overlay(
                    cardShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [rimPrimary, rimSecondary, rimPrimary.opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3.2
                        )
                )
                .shadow(color: glowColor.opacity(0.38), radius: 24, x: 0, y: 6)
                .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 10)

            if showPickSpark {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0xFEF3C7), Color(hex: 0xF59E0B), Color(hex: 0xF59E0B, opacity: 0)],
                            center: .center,
                            startRadius: 1,
                            endRadius: 14
                        )
                    )
                    .frame(width: 28, height: 28)
                    .padding(22)
            }
        }
        .frame(width: width, height: height)
    }
}

private struct ApertureIrisView: View {
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerR = size.width / 2
            let pupilR = outerR * 0.48
            let bladeCount = 7

            for i in 0..<bladeCount {
                let baseAngle = Double(i) * (2.0 * .pi / Double(bladeCount)) - 0.22
                let nextAngle = baseAngle + (2.0 * .pi / Double(bladeCount)) * 1.18
                let midAngle = (baseAngle + nextAngle) * 0.5

                let p1 = CGPoint(
                    x: center.x + CGFloat(cos(baseAngle)) * outerR * 1.04,
                    y: center.y + CGFloat(sin(baseAngle)) * outerR * 1.04
                )
                let p2 = CGPoint(
                    x: center.x + CGFloat(cos(nextAngle)) * outerR * 1.04,
                    y: center.y + CGFloat(sin(nextAngle)) * outerR * 1.04
                )
                let inner1 = CGPoint(
                    x: center.x + CGFloat(cos(baseAngle + 0.42)) * pupilR,
                    y: center.y + CGFloat(sin(baseAngle + 0.42)) * pupilR
                )
                let inner2 = CGPoint(
                    x: center.x + CGFloat(cos(nextAngle + 0.28)) * pupilR,
                    y: center.y + CGFloat(sin(nextAngle + 0.28)) * pupilR
                )
                let ctrlInner = CGPoint(
                    x: center.x + CGFloat(cos(midAngle + 0.35)) * (pupilR * 0.90),
                    y: center.y + CGFloat(sin(midAngle + 0.35)) * (pupilR * 0.90)
                )

                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                path.addLine(to: inner2)
                path.addQuadCurve(to: inner1, control: ctrlInner)
                path.closeSubpath()

                let shade = 0.10 + 0.045 * sin(baseAngle + 0.9)
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: shade + 0.05, green: shade + 0.055, blue: shade + 0.075),
                            Color(red: shade * 0.55, green: shade * 0.58, blue: shade * 0.68),
                        ]),
                        startPoint: p1,
                        endPoint: inner2
                    )
                )

                var edge = Path()
                edge.move(to: inner2)
                edge.addQuadCurve(to: inner1, control: ctrlInner)
                let warmWeight = max(0, -cos(midAngle - .pi * 0.25))
                let edgeColor = warmWeight > 0.2
                    ? Color(hex: 0xFBBF24, opacity: 0.32 * warmWeight + 0.14)
                    : Color(hex: 0x38BDF8, opacity: 0.28)
                context.stroke(edge, with: .color(edgeColor), lineWidth: 1.8)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

private struct JingXuAppIconView: View {
    var body: some View {
        MacOSSquircleShell {
            ZStack {
                RadialGradient(
                    colors: [
                        Color(hex: 0x242730),
                        Color(hex: 0x15161B),
                        Color(hex: 0x0B0C0F),
                    ],
                    center: UnitPoint(x: 0.35, y: 0.24),
                    startRadius: 20,
                    endRadius: 680
                )

                Circle()
                    .fill(Color(hex: 0x38BDF8, opacity: 0.12))
                    .frame(width: 420, height: 420)
                    .blur(radius: 70)
                    .offset(x: -175, y: -120)

                Circle()
                    .fill(Color(hex: 0xF59E0B, opacity: 0.14))
                    .frame(width: 420, height: 420)
                    .blur(radius: 70)
                    .offset(x: 175, y: -110)

                ZStack {
                    GlassSequenceCard(
                        width: 248,
                        height: 336,
                        fillTop: Color(hex: 0x1E293B, opacity: 0.72),
                        fillBottom: Color(hex: 0x0F172A, opacity: 0.45),
                        rimPrimary: Color(hex: 0x38BDF8),
                        rimSecondary: Color(hex: 0x0284C7, opacity: 0.65),
                        glowColor: Color(hex: 0x38BDF8)
                    )
                    .rotationEffect(.degrees(-16), anchor: .bottom)
                    .offset(x: -128, y: -118)

                    GlassSequenceCard(
                        width: 248,
                        height: 336,
                        fillTop: Color(hex: 0x292018, opacity: 0.76),
                        fillBottom: Color(hex: 0x18130E, opacity: 0.48),
                        rimPrimary: Color(hex: 0xFBBF24),
                        rimSecondary: Color(hex: 0xEA580C, opacity: 0.72),
                        glowColor: Color(hex: 0xF59E0B),
                        showPickSpark: true
                    )
                    .rotationEffect(.degrees(16), anchor: .bottom)
                    .offset(x: 128, y: -118)

                    GlassSequenceCard(
                        width: 262,
                        height: 356,
                        fillTop: Color(hex: 0x323540, opacity: 0.82),
                        fillBottom: Color(hex: 0x1A1C23, opacity: 0.62),
                        rimPrimary: Color(hex: 0xF4F4F5, opacity: 0.85),
                        rimSecondary: Color(hex: 0x71717A, opacity: 0.45),
                        glowColor: Color.white.opacity(0.35)
                    )
                    .offset(x: 0, y: -146)
                }

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0x343742), Color(hex: 0x16181E), Color(hex: 0x0D0E12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 492, height: 492)
                        .shadow(color: .black.opacity(0.78), radius: 34, x: 0, y: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color(hex: 0xFDE68A, opacity: 0.42),
                                            Color(hex: 0x525766, opacity: 0.55),
                                            Color(hex: 0x38BDF8, opacity: 0.42),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2.5
                                )
                        )

                    Canvas { context, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        let rOuter: CGFloat = 232
                        let rInner: CGFloat = 208
                        for i in 0..<120 {
                            let angle = Double(i) * (2.0 * .pi / 120.0) - .pi / 2.0
                            let p1 = CGPoint(x: c.x + CGFloat(cos(angle)) * rInner, y: c.y + CGFloat(sin(angle)) * rInner)
                            let p2 = CGPoint(x: c.x + CGFloat(cos(angle)) * rOuter, y: c.y + CGFloat(sin(angle)) * rOuter)
                            var tick = Path()
                            tick.move(to: p1)
                            tick.addLine(to: p2)
                            if i == 0 {
                                context.stroke(tick, with: .color(Color(hex: 0xF59E0B)), style: StrokeStyle(lineWidth: 4.0, lineCap: .round))
                            } else {
                                let spec = 0.14 + 0.16 * max(0, cos(angle + .pi * 0.75))
                                context.stroke(tick, with: .color(Color.white.opacity(spec)), lineWidth: 1.6)
                            }
                        }
                    }
                    .frame(width: 492, height: 492)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0x0B0C10), Color(hex: 0x1F222B)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 404, height: 404)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5)
                        )

                    Circle()
                        .fill(Color(hex: 0x050608))
                        .frame(width: 356, height: 356)

                    ApertureIrisView(diameter: 346)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(hex: 0x0E1320),
                                    Color(hex: 0x05070B),
                                    Color(hex: 0x020305),
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: 92
                            )
                        )
                        .frame(width: 170, height: 170)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color(hex: 0xFBBF24, opacity: 0.45), Color(hex: 0x38BDF8, opacity: 0.45)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )

                    ZStack {
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(hex: 0xFDE68A, opacity: 0.56),
                                        Color(hex: 0xF59E0B, opacity: 0.28),
                                        Color.clear,
                                    ],
                                    center: .center,
                                    startRadius: 6,
                                    endRadius: 135
                                )
                            )
                            .frame(width: 260, height: 150)
                            .rotationEffect(.degrees(-38))
                            .offset(x: -66, y: -68)

                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color(hex: 0xBAE6FD, opacity: 0.52),
                                        Color(hex: 0x0EA5E9, opacity: 0.28),
                                        Color.clear,
                                    ],
                                    center: .center,
                                    startRadius: 6,
                                    endRadius: 135
                                )
                            )
                            .frame(width: 260, height: 150)
                            .rotationEffect(.degrees(-38))
                            .offset(x: 68, y: 70)

                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.92), Color(hex: 0xFDE68A, opacity: 0.45), Color.clear],
                                    center: .center,
                                    startRadius: 1,
                                    endRadius: 18
                                )
                            )
                            .frame(width: 36, height: 36)
                            .offset(x: -36, y: -38)

                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color(hex: 0xE0F2FE, opacity: 0.85), Color(hex: 0x38BDF8, opacity: 0.40), Color.clear],
                                    center: .center,
                                    startRadius: 1,
                                    endRadius: 10
                                )
                            )
                            .frame(width: 20, height: 20)
                            .offset(x: 28, y: 30)
                    }
                    .frame(width: 346, height: 346)
                    .clipShape(Circle())
                    .blendMode(.screen)

                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Color.white.opacity(0.04),
                                    Color(hex: 0x38BDF8, opacity: 0.26),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.0
                        )
                        .frame(width: 352, height: 352)
                }
                .offset(y: 66)
            }
        }
    }
}

@MainActor
private func renderAppIcon(to outputPath: String) throws {
    let renderer = ImageRenderer(content: JingXuAppIconView())
    renderer.scale = 1.0
    renderer.isOpaque = false
    guard let cgImage = renderer.cgImage else {
        throw NSError(domain: "JingXuIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render icon CGImage"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: 1024, height: 1024)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "JingXuIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}

let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/AppIcon.png"
try MainActor.assumeIsolated {
    try renderAppIcon(to: destination)
}
