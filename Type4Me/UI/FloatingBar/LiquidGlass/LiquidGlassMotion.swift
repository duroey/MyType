//
//  LiquidGlassMotion.swift
//  Type4Me
//

import Foundation

struct LiquidGlassMotion: Equatable, Sendable {
    let time: TimeInterval
    let energy: Float
    let isAnimated: Bool

    static let staticFallback = LiquidGlassMotion(time: 0, energy: 0, isAnimated: false)

    static func active(
        time: TimeInterval,
        rawEnergy: Float,
        isAnimated: Bool,
        reduceMotion: Bool
    ) -> LiquidGlassMotion {
        guard isAnimated, !reduceMotion else {
            return staticFallback
        }
        let clamped = max(0.0, min(1.0, rawEnergy))
        return LiquidGlassMotion(time: time, energy: clamped, isAnimated: true)
    }
}
