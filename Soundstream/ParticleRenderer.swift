import Metal
import MetalKit
import QuartzCore
import simd
import os.log

private let log = Logger(subsystem: "com.henry.soundstream", category: "Renderer")

struct Particle {
    var x: Float = 0
    var y: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var life: Float = 0
    var maxLife: Float = 0
    var size: Float = 0
    var opacity: Float = 0
    var isBurst: Bool = false
}

struct StreamHead {
    var x: Float = 0
    var y: Float = 0
    var angle: Float = 0
    var speed: Float = 1.5
    var maxSpeed: Float = 2.0
}

struct ParticleVertex {
    var position: SIMD2<Float>
    var pointSize: Float
    var color: SIMD4<Float>
}

struct Uniforms {
    var aspectRatio: Float
}

private func randf() -> Float {
    Float(arc4random_uniform(10000)) / 10000.0
}

private func hslToRGB(h: Float, s: Float, l: Float) -> (Float, Float, Float) {
    guard s != 0 else { return (l, l, l) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    var hk = h.truncatingRemainder(dividingBy: 1.0)
    if hk < 0 { hk += 1 }
    let tc: [Float] = [hk + 1.0/3, hk, hk - 1.0/3]
    var rgb = [Float](repeating: 0, count: 3)
    for i in 0..<3 {
        var t = tc[i]
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0/6 {
            rgb[i] = p + (q - p) * 6 * t
        } else if t < 0.5 {
            rgb[i] = q
        } else if t < 2.0/3 {
            rgb[i] = p + (q - p) * (2.0/3 - t) * 6
        } else {
            rgb[i] = p
        }
    }
    return (rgb[0], rgb[1], rgb[2])
}

final class ParticleRenderer {
    static let maxStreams = 1
    static let particlesPerStream = 1800
    static let totalParticles = maxStreams * particlesPerStream

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    private var particles: [Particle]
    private var heads: [StreamHead]
    private var time: Float = 0
    private var hue: Float
    private var aspect: Float = 16.0 / 9.0
    private var prevLevel: Float = 0
    private var scaleFactor: Float = 2.0

    init?(device: MTLDevice) {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            log.error("Failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        let bundle = Bundle(for: SoundstreamView.self)
        var library: MTLLibrary?

        if let libURL = bundle.url(forResource: "default", withExtension: "metallib") {
            library = try? device.makeLibrary(URL: libURL)
        }
        if library == nil {
            library = try? device.makeDefaultLibrary(bundle: bundle)
        }
        if library == nil {
            library = device.makeDefaultLibrary()
        }

        guard let lib = library else {
            log.error("Failed to load Metal library")
            return nil
        }

        guard let vertexFunc = lib.makeFunction(name: "particleVertex"),
              let fragmentFunc = lib.makeFunction(name: "particleFragment") else {
            log.error("Failed to find shader functions")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            log.error("Failed to create pipeline state")
            return nil
        }
        self.pipelineState = pipeline

        self.particles = Array(repeating: Particle(), count: Self.totalParticles)
        self.heads = (0..<Self.maxStreams).map { _ in
            StreamHead(x: 0, y: 0, angle: randf() * .pi * 2, speed: 1.5, maxSpeed: 2.0)
        }
        self.hue = randf()
        log.info("ParticleRenderer initialized successfully")
    }

    func updateAndRender(layer: CAMetalLayer, audioState: AudioState, backingScale: Float) {
        let dt: Float = 1.0 / 60.0
        time += dt
        hue = (time * 0.04).truncatingRemainder(dividingBy: 1.0)

        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        aspect = Float(drawableSize.width / drawableSize.height)
        scaleFactor = backingScale

        let audioEnergy = audioState.active ? audioState.smoothLevel : 0

        updateHeads(dt: dt, audioEnergy: audioEnergy)
        emitAndUpdateParticles(dt: dt, audioState: audioState, audioEnergy: audioEnergy)

        render(layer: layer)
    }

    private func updateHeads(dt: Float, audioEnergy: Float) {
        for s in 0..<Self.maxStreams {
            heads[s].maxSpeed = 2.0 + audioEnergy * 4.0
            updateHead(&heads[s], dt: dt)
        }
    }

    private func updateHead(_ h: inout StreamHead, dt: Float) {
        let edgeX = aspect * 0.90
        let edgeY: Float = 0.90

        let cx = cosf(h.angle)
        let cy = sinf(h.angle)

        var distToEdge: Float = 999.0
        if cx > 0.001  { distToEdge = min(distToEdge, (edgeX - h.x) / cx) }
        if cx < -0.001 { distToEdge = min(distToEdge, (-edgeX - h.x) / cx) }
        if cy > 0.001  { distToEdge = min(distToEdge, (edgeY - h.y) / cy) }
        if cy < -0.001 { distToEdge = min(distToEdge, (-edgeY - h.y) / cy) }
        if distToEdge < 0 { distToEdge = 0 }

        let timeToEdge = h.speed > 0.01 ? distToEdge / h.speed : 999.0
        let brakeTime: Float = 0.4

        if timeToEdge < brakeTime {
            let ratio = timeToEdge / brakeTime
            let target = h.maxSpeed * ratio * ratio
            h.speed += (target - h.speed) * 20.0 * dt
            if h.speed < 0.02 { h.speed = 0.02 }

            if h.speed < 0.05 || distToEdge < 0.03 {
                h.speed = 0
                let toCenterAngle = atan2f(-h.y, -h.x)
                let spread: Float = .pi * 0.4
                h.angle = toCenterAngle + (randf() - 0.5) * spread
                h.speed = h.maxSpeed * 0.15
            }
        } else {
            h.speed += (h.maxSpeed - h.speed) * 5.0 * dt
        }

        h.x += cosf(h.angle) * h.speed * dt
        h.y += sinf(h.angle) * h.speed * dt

        let cx2 = aspect * 0.95
        let cy2: Float = 0.95
        if fabsf(h.x) > cx2 || fabsf(h.y) > cy2 {
            h.x = max(-cx2, min(cx2, h.x))
            h.y = max(-cy2, min(cy2, h.y))
            let toCenterAngle = atan2f(-h.y, -h.x)
            h.angle = toCenterAngle + (randf() - 0.5) * (.pi * 0.3)
            h.speed = h.maxSpeed * 0.2
        }
    }

    private var frameCount = 0

    private func emitAndUpdateParticles(dt: Float, audioState: AudioState, audioEnergy: Float) {
        frameCount += 1
        if frameCount % 120 == 0 {
            NSLog("SOUNDSTREAM: frame=%d active=%d level=%.4f smooth=%.4f peak=%.4f spectrum0=%.4f",
                  frameCount, audioState.active ? 1 : 0, audioState.level, audioState.smoothLevel, audioState.peak, audioState.spectrum[0])
        }

        let energy = audioEnergy
        let soundSpread = energy * 8.0
        let currentLevel = audioState.level
        let jump = currentLevel - prevLevel
        prevLevel = currentLevel
        let burst = audioState.active && currentLevel > 0.15 && jump > 0.05

        let bassEnergy = audioState.active
            ? (audioState.spectrum[0] + audioState.spectrum[1] + audioState.spectrum[2]) / 3.0
            : 0
        let midEnergy = audioState.active
            ? (audioState.spectrum[4] + audioState.spectrum[5] + audioState.spectrum[6] + audioState.spectrum[7]) / 4.0
            : 0
        let highEnergy = audioState.active
            ? (audioState.spectrum[10] + audioState.spectrum[11] + audioState.spectrum[12] + audioState.spectrum[13]) / 4.0
            : 0

        for s in 0..<Self.maxStreams {
            let h = heads[s]
            let speedRatio = min(h.speed / max(h.maxSpeed, 0.1), 1.0)
            let baseEmit = 12 + Int(speedRatio * 40)
            let audioEmitBoost = audioState.active ? Int(energy * 50) : 0
            let emitCount = baseEmit + audioEmitBoost
            let tailAngle = h.angle + .pi
            let base = s * Self.particlesPerStream
            var emitted = 0

            let pulsePhase = time * 10.0
            let bassPulse = bassEnergy * sinf(pulsePhase) * 0.35
            let midPulse = midEnergy * sinf(pulsePhase * 1.5 + 1.0) * 0.20
            let highFlutter = highEnergy * sinf(pulsePhase * 3.7 + 2.5) * 0.12

            let perpAngle = h.angle + .pi * 0.5
            let rhythmOffsetX = bassPulse * cosf(perpAngle) + midPulse * cosf(h.angle) + highFlutter * cosf(time * 5.0)
            let rhythmOffsetY = bassPulse * sinf(perpAngle) + midPulse * sinf(h.angle) + highFlutter * sinf(time * 5.0)

            let rhythmSpread: Float = 1.0 + bassEnergy * 5.0 + energy * 4.0

            for j in 0..<Self.particlesPerStream where emitted < emitCount {
                let idx = base + j
                guard particles[idx].life <= 0 else { continue }

                let spread: Float = (0.04 + (1.0 - speedRatio) * 0.06 + soundSpread * 0.08) * rhythmSpread
                particles[idx].x = h.x + rhythmOffsetX + (randf() - 0.5) * spread
                particles[idx].y = h.y + rhythmOffsetY + (randf() - 0.5) * spread

                let fan = (randf() - 0.5) * (0.7 + soundSpread * 0.8 + bassEnergy * 2.5)
                let driftAngle = tailAngle + fan
                var driftSpeed = h.speed * (0.02 + randf() * 0.06) + randf() * 0.01
                driftSpeed += soundSpread * 0.08 + bassEnergy * 0.15
                particles[idx].vx = cosf(driftAngle) * driftSpeed
                particles[idx].vy = sinf(driftAngle) * driftSpeed

                particles[idx].maxLife = 1.5 + randf() * 2.5
                particles[idx].life = particles[idx].maxLife
                particles[idx].size = 1.5 + randf() * 2.5 + bassEnergy * 3.0
                particles[idx].opacity = 0.8 + speedRatio * 0.2 + energy * 0.3
                particles[idx].isBurst = false
                emitted += 1
            }

            if audioState.active && energy > 0.005 {
                let pushForce = energy * 4.0
                for j in 0..<Self.particlesPerStream {
                    let idx = base + j
                    guard particles[idx].life > 0 else { continue }
                    let dx = particles[idx].x - h.x
                    let dy = particles[idx].y - h.y
                    let dist = sqrtf(dx * dx + dy * dy) + 0.001
                    particles[idx].vx += (dx / dist) * pushForce * dt
                    particles[idx].vy += (dy / dist) * pushForce * dt
                }
            }

            if burst {
                let burstStrength: Float = 0.8 + currentLevel * 5.0
                for j in 0..<Self.particlesPerStream {
                    let idx = base + j
                    guard particles[idx].life > 0 else { continue }
                    let bAngle = randf() * .pi * 2.0
                    let bSpeed = burstStrength * (0.3 + randf() * 0.7)
                    particles[idx].vx += cosf(bAngle) * bSpeed
                    particles[idx].vy += sinf(bAngle) * bSpeed
                }
            }
        }

        for i in 0..<Self.totalParticles {
            guard particles[i].life > 0 else { continue }
            particles[i].vx *= 0.997
            particles[i].vy *= 0.997
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].life -= dt
        }
    }

    private func render(layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store

        var vertices: [ParticleVertex] = []
        vertices.reserveCapacity(Self.totalParticles * 3)

        for s in 0..<Self.maxStreams {
            let streamHue = (hue + Float(s) / Float(Self.maxStreams)).truncatingRemainder(dividingBy: 1.0)
            let base = s * Self.particlesPerStream
            let hx = heads[s].x
            let hy = heads[s].y

            for j in 0..<Self.particlesPerStream {
                let p = particles[base + j]
                guard p.life > 0 else { continue }

                let age = (p.maxLife - p.life) / p.maxLife
                let fadeIn = min((p.maxLife - p.life) * 8.0, 1.0)
                let fadeOut = min(p.life * 3.0, 1.0)

                let dx = p.x - hx
                let dy = p.y - hy
                let distToHead = sqrtf(dx * dx + dy * dy)
                let proximity = max(0, 1.0 - distToHead * 3.0)

                let headBright = 1.0 + proximity * 1.5
                let fade = p.opacity * fadeIn * fadeOut * headBright

                let sizeGrow = 1.0 + age * 3.0
                let sz = p.size * scaleFactor * sizeGrow
                let pos = SIMD2<Float>(p.x, p.y)

                let glowLightness = 0.4 + proximity * 0.15
                let (gr, gg, gb) = hslToRGB(h: streamHue, s: 0.7, l: glowLightness)
                vertices.append(ParticleVertex(
                    position: pos,
                    pointSize: max(sz * 3.0, 1.0),
                    color: SIMD4<Float>(gr, gg, gb, fade * 0.12)
                ))

                let coreLightness = 0.65 + proximity * 0.2
                let (cr, cg, cb) = hslToRGB(h: streamHue, s: 0.5 - proximity * 0.2, l: coreLightness)
                vertices.append(ParticleVertex(
                    position: pos,
                    pointSize: max(sz * 1.2, 1.0),
                    color: SIMD4<Float>(cr, cg, cb, fade * 0.5)
                ))

                let whiteBright: Float = 0.35 + proximity * 0.5
                vertices.append(ParticleVertex(
                    position: pos,
                    pointSize: max(sz * 0.35, 1.0),
                    color: SIMD4<Float>(1, 1, 1, fade * whiteBright)
                ))
            }
        }

        guard !vertices.isEmpty,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)

        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<ParticleVertex>.stride,
            options: .storageModeShared
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var uniforms = Uniforms(aspectRatio: aspect)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
