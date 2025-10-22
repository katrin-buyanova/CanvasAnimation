//
//  PortraitSystem.swift
//  ParticlePortraitColorView
//
//  Created by Katerina Buyanova on 21/10/2025.
//

import SwiftUI
import UIKit
import CoreGraphics
import Combine

// MARK: - Pixel model

struct Dot {
    var start: CGPoint
    var end: CGPoint
    var baseSize: CGFloat
    var delay: Double
    var color: Color
    var sway: CGFloat
    var angle: CGFloat
    var speed: CGFloat
    var orbit: CGFloat
}

// MARK: - Portrait system

final class PortraitSystem: ObservableObject {
    @Published var dots: [Dot] = []
    @Published var assembling: Bool = false
    @Published var animStart: Date = .init()

    let assembleTime: CGFloat = 2.4
    let useGlow: Bool = true
    let dotSizeRange: ClosedRange<CGFloat> = 0.9...2.6

    private let sampleStep: Int = 2
    private let maxDots: Int = 14_000
    private let satBoost: CGFloat = 1.12
    private let valueGamma: CGFloat = 0.90

    private var canvas: CGSize = .zero
    fileprivate var targets: [CGPoint] = []
    fileprivate var colors: [Color] = []

    // MARK: - Build vectors based on image from Assets
    
    func build(from imageName: String, canvas: CGSize) {
        guard let cg = UIImage(named: imageName)?.cgImage,
              let data = cg.dataProvider?.data as Data? else { return }

        self.canvas = canvas

        let w = cg.width
        let h = cg.height
        let bytes = [UInt8](data)

        struct Sample {
            var x: Int; var y: Int
            var r: CGFloat; var g: CGFloat; var b: CGFloat
            var v: CGFloat
            var grad: CGFloat
        }
        var samples: [Sample] = []
        samples.reserveCapacity((w / sampleStep) * (h / sampleStep))

        @inline(__always) func luma(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            0.2126*r + 0.7152*g + 0.0722*b
        }

        @inline(__always) func sobelMag(x: Int, y: Int) -> CGFloat {
            if x <= 0 || y <= 0 || x >= w-1 || y >= h-1 { return 0 }
            func lumAt(_ xx: Int, _ yy: Int) -> CGFloat {
                let i = (yy * w + xx) * 4
                if i + 3 >= bytes.count { return 0 }
                let r = CGFloat(bytes[i])     / 255.0
                let g = CGFloat(bytes[i + 1]) / 255.0
                let b = CGFloat(bytes[i + 2]) / 255.0
                return luma(r, g, b)
            }
            let a = lumAt(x-1,y-1), b = lumAt(x,y-1), c = lumAt(x+1,y-1)
            let d = lumAt(x-1,y  ), _ = lumAt(x,y  ), f = lumAt(x+1,y  )
            let g1 = lumAt(x-1,y+1), h1 = lumAt(x,y+1), i1 = lumAt(x+1,y+1)
            let gx = (c + 2*f + i1) - (a + 2*d + g1)
            let gy = (g1 + 2*h1 + i1) - (a + 2*b + c)
            let m = abs(gx) + abs(gy)
            return min(1, max(0, m * 0.9))
        }

        for y in stride(from: 0, to: h, by: sampleStep) {
            for x in stride(from: 0, to: w, by: sampleStep) {
                let i = (y * w + x) * 4
                guard i + 3 < bytes.count else { continue }

                let a = CGFloat(bytes[i + 3]) / 255.0
                guard a > 0.5 else { continue }

                let r = CGFloat(bytes[i    ]) / 255.0
                let g = CGFloat(bytes[i + 1]) / 255.0
                let b = CGFloat(bytes[i + 2]) / 255.0

                var v = luma(r, g, b)
                v = pow(v, valueGamma)
                let grad = sobelMag(x: x, y: y)

                samples.append(.init(x: x, y: y, r: r, g: g, b: b, v: v, grad: grad))
            }
        }
        guard !samples.isEmpty else { return }

        @inline(__always) func weight(_ s: Sample) -> CGFloat { 0.45 * s.v + 0.55 * s.grad }

        var picked: [Sample]
        if samples.count > maxDots {
            picked = []
            picked.reserveCapacity(maxDots)
            var acc: CGFloat = 0
            let total = samples.reduce(0) { $0 + weight($1) } + 1e-6
            let step = total / CGFloat(maxDots)
            var target: CGFloat = step
            for s in samples {
                acc += weight(s)
                if acc >= target {
                    picked.append(s)
                    target += step
                    if picked.count == maxDots { break }
                }
            }
            if picked.count < maxDots {
                picked.append(contentsOf: samples.dropFirst(picked.count).prefix(maxDots - picked.count))
            }
        } else {
            picked = samples
        }
        
        let iw = CGFloat(w), ih = CGFloat(h)
        let scale = max(canvas.width/iw, canvas.height/ih) * 1.02
        let ox = (canvas.width  - iw * scale) / 2
        let oy = (canvas.height - ih * scale) / 2

        var pts: [CGPoint] = []; pts.reserveCapacity(picked.count)
        var cols: [Color]  = []; cols.reserveCapacity(picked.count)

        for s in picked {
            let j = jitter(x: s.x, y: s.y)
            let px = (CGFloat(s.x) + j.x) * scale + ox
            let py = (CGFloat(s.y) + j.y) * scale + oy
            pts.append(CGPoint(x: px, y: py))

            let hsv = rgb2hsv(s.r, s.g, s.b)
            let S = min(1, hsv.s * satBoost)
            let V = min(1, max(0, pow(hsv.v, valueGamma)))
            cols.append(Color(hue: hsv.h, saturation: S, brightness: V))
        }

        targets = pts
        colors  = cols
        regenerateDots(assemble: assembling)
    }

    // MARK: - Smooth swithing between modes
    
    func toggle() {
        let now = Date()
        let tNow = CGFloat(now.timeIntervalSince(animStart))
        let newAssembling = !assembling

        guard !dots.isEmpty, !targets.isEmpty else {
            assembling = newAssembling
            animStart = now
            regenerateDots(assemble: assembling)
            return
        }

        let current = dots.map { position(of: $0, time: tNow, assembling: assembling) }

        let cx = canvas.width / 2
        let cy = canvas.height / 2
        let minSide = min(canvas.width, canvas.height) / 2

        var updated: [Dot] = []
        updated.reserveCapacity(dots.count)

        for i in dots.indices {
            let d = dots[i]
            let startPoint = current[i]
            let endPoint: CGPoint

            if newAssembling {
                endPoint = targets[i]
            } else {
                
                let theta = CGFloat.random(in: 0..<(2 * .pi))
                let r = sqrt(CGFloat.random(in: 0...1)) * (minSide * 0.72)
                endPoint = CGPoint(x: cx + cos(theta) * r, y: cy + sin(theta) * r)
            }

            updated.append(
                Dot(
                    start: startPoint,
                    end: endPoint,
                    baseSize: d.baseSize,
                    delay: Double.random(in: 0...0.18),
                    color: d.color,
                    sway: d.sway,
                    angle: d.angle,
                    speed: d.speed,
                    orbit: d.orbit
                )
            )
        }

        dots = updated
        assembling = newAssembling
        animStart = now
    }

    fileprivate func position(of d: Dot, time: CGFloat, assembling: Bool) -> CGPoint {
        if assembling {
            let t = clamp01((time - CGFloat(d.delay)) / assembleTime)
            let k1 = smoothstep(t)
            let k  = smoothstep(k1)
            let drift = (1 - k) * (1 - k) * d.sway * 0.6
            let x = lerp(d.start.x, d.end.x, k) + sin(d.angle + k * 6) * drift
            let y = lerp(d.start.y, d.end.y, k) + cos(d.angle * 0.8 + k * 5) * drift * 0.6
            return CGPoint(x: x, y: y)
        } else {
            let t = time + CGFloat(d.delay)
            let ox = cos(d.angle + t * d.speed) * d.orbit
            let oy = sin(d.angle * 0.8 + t * d.speed * 1.2) * d.orbit
            return CGPoint(x: d.start.x + ox, y: d.start.y + oy)
        }
    }

    private func regenerateDots(assemble: Bool) {
        guard !targets.isEmpty else { return }

        let cx = canvas.width / 2
        let cy = canvas.height / 2
        let minSide = min(canvas.width, canvas.height) / 2

        func sizeForColor(_ color: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            let v = 0.2126*r + 0.7152*g + 0.0722*b
            let base = CGFloat.random(in: dotSizeRange)
            let k = 0.9 + (1 - v) * 0.45
            return base * k
        }

        dots = zip(targets, colors).map { target, color in
            let theta = CGFloat.random(in: 0..<(2 * .pi))
            let r = sqrt(CGFloat.random(in: 0...1)) * (minSide * 0.72)
            let chaos = CGPoint(x: cx + cos(theta) * r, y: cy + sin(theta) * r)

            let orbit = CGFloat.random(in: minSide * 0.12 ... minSide * 0.32)
            let speed = CGFloat.random(in: 0.22 ... 0.55)

            return Dot(
                start: assemble ? chaos : target,
                end:   assemble ? target : chaos,
                baseSize: sizeForColor(color),
                delay: Double.random(in: 0...1),
                color: color,
                sway: CGFloat.random(in: 3...9),
                angle: CGFloat.random(in: 0..<(2 * .pi)),
                speed: speed,
                orbit: orbit
            )
        }

        animStart = Date()
    }
}

// MARK: - Helpers

@inline(__always) private func clamp01(_ x: CGFloat) -> CGFloat { max(0, min(1, x)) }
@inline(__always) private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

// smootherstep(t) ~= smoothstep(smoothstep(t))
@inline(__always) private func smoothstep(_ t: CGFloat) -> CGFloat {
    let x = clamp01(t)
    return x * x * (3 - 2 * x)
}

@inline(__always) private func rgb2hsv(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
    let mx = max(r, g, b), mn = min(r, g, b)
    let v = mx
    let d = mx - mn
    let s = mx == 0 ? 0 : d / mx
    var h: CGFloat = 0
    if d != 0 {
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
    }
    return (h, s, v)
}

@inline(__always) private func jitter(x: Int, y: Int) -> CGPoint {
    @inline(__always) func hash01(_ v: UInt32) -> CGFloat {
        var z = v &* 0x27d4eb2d
        z ^= z >> 15
        z &*= 0x85ebca6b
        z ^= z >> 13
        z &*= 0xc2b2ae35
        z ^= z >> 16
        return CGFloat(Double(z) / Double(UInt32.max))
    }

    let xU = UInt32(truncatingIfNeeded: x)
    let yU = UInt32(truncatingIfNeeded: y)

    let u = hash01(xU &* 73856093  ^ yU &* 19349663)
    let v = hash01(xU &* 83492791  ^ yU &* 2971215073)

    return CGPoint(x: u - 0.5, y: v - 0.5) // ~[-0.5, 0.5]
}
