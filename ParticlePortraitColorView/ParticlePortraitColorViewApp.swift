//
//  ParticlePortraitColorViewApp.swift
//  ParticlePortraitColorView
//
//  Created by Katerina Buyanova on 21/10/2025.
//

import SwiftUI
import CoreGraphics
import Combine

struct ParticlePortraitColorView: View {
    @StateObject private var vm = PortraitSystem()
    @State private var ready = false
    @State private var lastCanvas: CGSize = .zero

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, .black.opacity(0.98)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            TimelineView(.animation(minimumInterval: 1/60)) { timeline in
                GeometryReader { _ in
                    let now = timeline.date

                    Canvas(rendersAsynchronously: true) { ctx, size in
                        guard size.width > 2, size.height > 2 else { return }
                        if !ready || abs(size.width - lastCanvas.width) > 1 || abs(size.height - lastCanvas.height) > 1 {
                            DispatchQueue.main.async {
                                vm.build(from: "Steve", canvas: size)
                                lastCanvas = size
                                ready = true
                            }
                            return
                        }

                        let tNow: CGFloat = .init(now.timeIntervalSince(vm.animStart))
                        let dots = vm.dots
                        if dots.isEmpty {
                            drawFallbackNoise(ctx: ctx, size: size)
                            return
                        }

                        if vm.assembling {
                            for d in dots {
                                let t = clamp01((tNow - CGFloat(d.delay)) / vm.assembleTime)
                                let k1 = smoothstep(t)
                                let k  = smoothstep(k1)

                                let drift = (1 - k) * (1 - k) * d.sway * 0.6
                                let x = lerp(d.start.x, d.end.x, k) + sin(d.angle + k * 6) * drift
                                let y = lerp(d.start.y, d.end.y, k) + cos(d.angle * 0.8 + k * 5) * drift * 0.6

                                let pulse = 0.96 + 0.04 * (0.5 + 0.5 * sin((tNow + CGFloat(d.delay)) * 0.8))
                                let sizePx = max(1, d.baseSize * pulse)

                                drawDot(ctx: ctx, x: x, y: y, size: sizePx, color: d.color, glow: vm.useGlow)
                            }
                        } else {
                            for d in dots {
                                let tt = tNow + CGFloat(d.delay)
                                let ox = cos(d.angle + tt * d.speed) * d.orbit
                                let oy = sin(d.angle * 0.8 + tt * d.speed * 1.2) * d.orbit

                                let x = d.start.x + ox
                                let y = d.start.y + oy

                                let breath = 0.9 + 0.1 * (0.5 + 0.5 * sin(tt * (0.6 + d.speed)))
                                let sizePx = max(1, d.baseSize * breath)

                                drawDot(ctx: ctx, x: x, y: y, size: sizePx, color: d.color, glow: vm.useGlow)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.toggle() }
                }
            }

            VStack {
                HStack {
                    Text("dots: \(vm.dots.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.60))
                        .padding(8)
                    Spacer()
                }
                Spacer()
                Text(vm.assembling ? "Tap to scatter" : "Tap to assemble")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
        }
        .statusBarHidden(true)
    }

    // MARK: - Draw helpers
    
    private func drawDot(ctx: GraphicsContext,
                         x: CGFloat, y: CGFloat,
                         size: CGFloat, color: Color,
                         glow: Bool) {
        if glow {
            var g = Path()
            let gsz = size * 3.0
            g.addEllipse(in: CGRect(x: x - (gsz - size)/2, y: y - (gsz - size)/2, width: gsz, height: gsz))
            ctx.fill(g, with: .color(color.opacity(0.08)))
        }

        var dot = Path()
        dot.addEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        ctx.fill(dot, with: .color(color))
    }

    private func drawFallbackNoise(ctx: GraphicsContext, size: CGSize) {

        let n = Int((size.width * size.height) / 4500)
        for _ in 0..<n {
            let x = CGFloat.random(in: 0..<size.width)
            let y = CGFloat.random(in: 0..<size.height)
            let s = CGFloat.random(in: 0.6...1.6)
            var p = Path()
            p.addEllipse(in: CGRect(x: x, y: y, width: s, height: s))
            ctx.fill(p, with: .color(.white.opacity(0.25)))
        }
    }
}

// MARK: - Math

@inline(__always) private func clamp01(_ x: CGFloat) -> CGFloat { max(0, min(1, x)) }
@inline(__always) private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
@inline(__always) private func smoothstep(_ t: CGFloat) -> CGFloat {
    let x = clamp01(t)
    return x * x * (3 - 2 * x)
}

