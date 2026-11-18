import CoreVideo
import Foundation
import Metal
import MetalKit
#if canImport(MetalFX)
import MetalFX
#endif
import simd
import Testing
import WebRTC
@testable import iGreenLight

/// The app's compiled shaders, run offscreen on small synthetic planes.
private struct GPU {
    let device: MTLDevice, library: MTLLibrary, queue: MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        library = try device.makeDefaultLibrary(bundle: .main)
        queue = try #require(device.makeCommandQueue())
    }

    func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return try #require(device.makeTexture(descriptor: d))
    }

    /// One full-screen pass of `fragment` into `target`.
    func run<P>(_ fragment: String, into target: MTLTexture, _ textures: [MTLTexture], _ params: P) throws {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = target.pixelFormat
        let state = try device.makeRenderPipelineState(descriptor: d)
        let r = MTLRenderPassDescriptor()
        r.colorAttachments[0].texture = target
        r.colorAttachments[0].loadAction = .clear
        r.colorAttachments[0].storeAction = .store
        let cmd = try #require(queue.makeCommandBuffer())
        let e = try #require(cmd.makeRenderCommandEncoder(descriptor: r))
        e.setRenderPipelineState(state)
        for (i, t) in textures.enumerated() { e.setFragmentTexture(t, index: i) }
        var p = params
        e.setFragmentBytes(&p, length: MemoryLayout<P>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.error == nil)
    }

    /// Luma and chroma planes as VideoToolbox hands them over: 8-bit, or 10-bit in the top bits of 16.
    /// `y` and `c` give the code values (0…255 or 0…1023) per luma pixel and per chroma texel.
    func planes(_ w: Int, _ h: Int, tenBit: Bool, y: (Int, Int) -> Int, c: (Int, Int) -> (Int, Int)) throws -> [MTLTexture] {
        let cw = w / 2, ch = h / 2
        let yTex = try texture(w, h, tenBit ? .r16Unorm : .r8Unorm), cTex = try texture(cw, ch, tenBit ? .rg16Unorm : .rg8Unorm)
        if tenBit {
            var yb = [UInt16](), cb = [UInt16]()
            for j in 0..<h { for i in 0..<w { yb.append(UInt16(y(i, j) << 6)) } }
            for j in 0..<ch { for i in 0..<cw { let v = c(i, j); cb.append(UInt16(v.0 << 6)); cb.append(UInt16(v.1 << 6)) } }
            yTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: yb, bytesPerRow: w * 2)
            cTex.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: cb, bytesPerRow: cw * 4)
        } else {
            var yb = [UInt8](), cb = [UInt8]()
            for j in 0..<h { for i in 0..<w { yb.append(UInt8(y(i, j))) } }
            for j in 0..<ch { for i in 0..<cw { let v = c(i, j); cb.append(UInt8(v.0)); cb.append(UInt8(v.1)) } }
            yTex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: yb, bytesPerRow: w)
            cTex.replace(region: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0, withBytes: cb, bytesPerRow: cw * 2)
        }
        return [yTex, cTex]
    }

    /// `nv12_fragment` into a float texture: what the shader computes, before any target rounds it.
    func convert(_ planes: [MTLTexture], _ params: MetalVideoRenderer.YUVParams) throws -> (Int, Int) -> SIMD3<Float> {
        let w = planes[0].width, h = planes[0].height
        let out = try texture(w, h, .rgba32Float)
        try run("nv12_fragment", into: out, planes, params)
        var px = [Float](repeating: 0, count: w * h * 4)
        out.getBytes(&px, bytesPerRow: w * 16, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return { x, y in SIMD3(px[(y * w + x) * 4], px[(y * w + x) * 4 + 1], px[(y * w + x) * 4 + 2]) }
    }
}

/// What the conversion should give for one pixel's code values, in double precision.
private func rgb(_ y: Int, _ cb: Int, _ cr: Int, tenBit: Bool, fullRange: Bool = false) -> SIMD3<Double> {
    let peak = tenBit ? 1023.0 : 255.0, black = tenBit ? 64.0 : 16.0, mid = tenBit ? 512.0 : 128.0
    let ySpan = tenBit ? 876.0 : 219.0, cSpan = tenBit ? 896.0 : 224.0
    let yy = fullRange ? Double(y) / peak : (Double(y) - black) / ySpan
    let pb = (Double(cb) - mid) / (fullRange ? peak : cSpan), pr = (Double(cr) - mid) / (fullRange ? peak : cSpan)
    let c = SIMD3(yy + 1.5748 * pr, yy - 0.1873 * pb - 0.4681 * pr, yy + 1.8556 * pb)
    return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
}

private func maxDifference(_ a: SIMD3<Float>, _ b: SIMD3<Double>) -> Double {
    simd_reduce_max(simd_abs(SIMD3<Double>(a) - b))
}

@Suite struct YUVRangeTests {
    /// What the sampler returns for a code value: 8-bit planes are code / 255, 10-bit ones have the code in the
    /// top ten of sixteen bits.
    private func sample(_ code: Int, tenBit: Bool) -> Float { tenBit ? Float(code << 6) / 65535 : Float(code) / 255 }

    @Test(arguments: [false, true]) func limitedRangeMapsBlackWhiteAndNeutralExactly(tenBit: Bool) {
        let p = MetalVideoRenderer.yuvParams(fullRange: false, matrix709: true, tenBit: tenBit)
        func y(_ code: Int) -> Float { (sample(code, tenBit: tenBit) - p.offset.x) * p.scale.x }
        func c(_ code: Int) -> Float { (sample(code, tenBit: tenBit) - p.offset.y) * p.scale.y }
        let (black, white, mid, top) = tenBit ? (64, 940, 512, 960) : (16, 235, 128, 240)
        #expect(abs(y(black)) < 1e-6)
        #expect(abs(y(white) - 1) < 1e-6)
        #expect(abs(c(mid)) < 1e-6)
        #expect(abs(c(top) - 0.5) < 1e-6)
        #expect(abs(c(2 * mid - top) + 0.5) < 1e-6)
        #expect(p.offset.y == p.offset.z && p.scale.y == p.scale.z)
    }

    @Test(arguments: [false, true]) func fullRangeMapsTheWholeCodeRange(tenBit: Bool) {
        let p = MetalVideoRenderer.yuvParams(fullRange: true, matrix709: true, tenBit: tenBit)
        let (peak, mid) = tenBit ? (1023, 512) : (255, 128)
        #expect(abs((sample(0, tenBit: tenBit) - p.offset.x) * p.scale.x) < 1e-6)
        #expect(abs((sample(peak, tenBit: tenBit) - p.offset.x) * p.scale.x - 1) < 1e-6)
        #expect(abs((sample(mid, tenBit: tenBit) - p.offset.y) * p.scale.y) < 1e-6)
        #expect(abs((sample(peak, tenBit: tenBit) - p.offset.y) * p.scale.y - Float(peak - mid) / Float(peak)) < 1e-6)
    }

    /// Ten-bit constants are those of the true 10-bit value: 64 and 876, not 16/255 and 255/219 of the sample.
    @Test func tenBitConstantsAreNotTheEightBitOnes() {
        let p = MetalVideoRenderer.yuvParams(fullRange: false, matrix709: true, tenBit: true)
        #expect(abs(Double(p.offset.x) - 64.0 * 64 / 65535) < 1e-7)
        #expect(abs(Double(p.scale.x) - 65535.0 / 64 / 876) < 1e-6)
        #expect(abs(Double(p.offset.y) - 512.0 * 64 / 65535) < 1e-7)
        #expect(abs(Double(p.scale.y) - 65535.0 / 64 / 896) < 1e-6)
    }

    /// Through the shader, against the same sums in doubles: black, white, grey and some colours, each as a
    /// whole plane of one value so that no filter mixes anything in, with and without the guided chroma path.
    @Test(arguments: [false, true]) func shaderConvertsCodesToTheExpectedRGB(tenBit: Bool) throws {
        let gpu = try GPU()
        let s = tenBit ? 4 : 1   // the 8-bit codes below, times four, are valid 10-bit ones
        for c in [(y: 16, cb: 128, cr: 128), (y: 235, cb: 128, cr: 128), (y: 126, cb: 128, cr: 128),
                  (y: 81, cb: 90, cr: 240), (y: 145, cb: 54, cr: 34), (y: 41, cb: 240, cr: 110)] {
            let planes = try gpu.planes(4, 4, tenBit: tenBit, y: { _, _ in c.y * s }, c: { _, _ in (c.cb * s, c.cr * s) })
            for guided in [false, true] {
                var p = MetalVideoRenderer.yuvParams(fullRange: false, matrix709: true, tenBit: tenBit)
                p.chroma = SIMD4(0.25 / 2, 0, guided ? 1 : 0, 1 / MetalVideoRenderer.chromaLumaSigma)
                let out = try gpu.convert(planes, p)(1, 2)
                #expect(maxDifference(out, rgb(c.y * s, c.cb * s, c.cr * s, tenBit: tenBit)) < 2e-4, "\(c) guided \(guided): \(out)")
                // Neutral chroma is grey exactly: the midpoint is code 128 of 255 (512 of 1023), not one half.
                if c.cb == 128 && c.cr == 128 { #expect(abs(out.x - out.y) < 1e-5 && abs(out.z - out.y) < 1e-5, "\(c): \(out)") }
            }
        }
    }

    /// Every one of the 877 luma codes of 10-bit video range keeps a value of its own in the intermediate
    /// texture, and black and white land on its ends: nothing is rounded to 8 bits on the way.
    @Test func tenBitLevelsSurviveTheIntermediateTexture() throws {
        let gpu = try GPU()
        let w = 878
        let planes = try gpu.planes(w, 2, tenBit: true, y: { x, _ in min(64 + x, 940) }, c: { _, _ in (512, 512) })
        let out = try gpu.texture(w, 2, MetalVideoRenderer.intermediateFormat)
        try gpu.run("nv12_fragment", into: out, planes, MetalVideoRenderer.yuvParams(fullRange: false, matrix709: true, tenBit: true))
        #expect(out.pixelFormat == .rgb10a2Unorm)   // the unpacking below is for this format
        var px = [UInt32](repeating: 0, count: w * 2)
        out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, 2), mipmapLevel: 0)
        let red = (0..<w).map { Int(px[$0] & 0x3ff) }, green = (0..<w).map { Int(px[$0] >> 10 & 0x3ff) }, blue = (0..<w).map { Int(px[$0] >> 20 & 0x3ff) }
        #expect(red[0] == 0 && red[876] == 1023)
        for x in 1...876 { #expect(red[x] > red[x - 1], "code \(64 + x) fell onto the one below") }
        #expect(red == green && red == blue)   // neutral chroma: grey to the last bit
    }

    /// 8-bit video range has 219 luma levels; in the 10-bit intermediate they stay evenly spaced (each 4 or 5
    /// codes above the last), where an 8-bit one makes steps of 1 and 2: the uneven steps that show as bands.
    @Test func eightBitLevelsStayEvenlySpacedInTheIntermediateTexture() throws {
        let gpu = try GPU()
        let w = 220
        let planes = try gpu.planes(w, 2, tenBit: false, y: { x, _ in 16 + x }, c: { _, _ in (128, 128) })
        let out = try gpu.texture(w, 2, MetalVideoRenderer.intermediateFormat)
        try gpu.run("nv12_fragment", into: out, planes, MetalVideoRenderer.yuvParams(fullRange: false, matrix709: true))
        var px = [UInt32](repeating: 0, count: w * 2)
        out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, 2), mipmapLevel: 0)
        let red = (0..<w).map { Int(px[$0] & 0x3ff) }
        #expect(red[0] == 0 && red[219] == 1023)
        for x in 1...219 { #expect([4, 5].contains(red[x] - red[x - 1]), "step \(red[x] - red[x - 1]) at code \(16 + x)") }
        for x in 0..<w { #expect(px[x] & 0x3ff == px[x] >> 10 & 0x3ff && px[x] & 0x3ff == px[x] >> 20 & 0x3ff, "code \(16 + x) is tinted") }
    }

    #if canImport(MetalFX)
    /// MetalFX takes the intermediate format for its input and its output (on this Mac; an iPhone is not tested here).
    @Test func metalFXAcceptsTheIntermediateFormat() throws {
        let gpu = try GPU()
        guard MTLFXSpatialScalerDescriptor.supportsDevice(gpu.device) else { return }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = 320; d.inputHeight = 180; d.outputWidth = 640; d.outputHeight = 360
        d.colorTextureFormat = MetalVideoRenderer.intermediateFormat
        d.outputTextureFormat = MetalVideoRenderer.intermediateFormat
        d.colorProcessingMode = .perceptual
        let scaler = try #require(d.makeSpatialScaler(device: gpu.device))
        let input = try gpu.texture(320, 180, MetalVideoRenderer.intermediateFormat), output = try gpu.texture(640, 360, MetalVideoRenderer.intermediateFormat)
        scaler.colorTexture = input
        scaler.outputTexture = output
        let cmd = try #require(gpu.queue.makeCommandBuffer())
        scaler.encode(commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        #expect(cmd.error == nil)
    }
    #endif
}

@Suite struct ChromaUpsamplingTests {
    private func params(chromaWidth: Int, guided: Bool) -> MetalVideoRenderer.YUVParams {
        var p = MetalVideoRenderer.yuvParams(fullRange: false, matrix709: true)
        p.chroma = SIMD4(0.25 / Float(chromaWidth), 0, guided ? 1 : 0, 1 / MetalVideoRenderer.chromaLumaSigma)   // Left siting, as the renderer sets it
        return p
    }

    /// Flat luma under any chroma: every neighbour counts the same, so the result is the bilinear fetch.
    @Test func equalsBilinearWhereLumaIsFlat() throws {
        let gpu = try GPU()
        let w = 32, h = 16
        // Chroma that changes from texel to texel in both directions, edges and corners of the plane included.
        let planes = try gpu.planes(w, h, tenBit: false, y: { _, _ in 120 }, c: { x, y in (40 + (x * 53 + y * 31) % 170, 40 + (x * 17 + y * 71) % 170) })
        let plain = try gpu.convert(planes, params(chromaWidth: w / 2, guided: false))
        let guided = try gpu.convert(planes, params(chromaWidth: w / 2, guided: true))
        var worst: Float = 0
        for y in 0..<h { for x in 0..<w { worst = max(worst, simd_reduce_max(simd_abs(plain(x, y) - guided(x, y)))) } }
        #expect(worst < 5e-4, "worst difference \(worst)")   // half of a 10-bit step
    }

    /// A dark red field against a bright white one, the edge on a chroma texel boundary. Bilinear chroma gives
    /// the last red column half the white field's (neutral) chroma; guided by the luma it keeps its own.
    @Test func keepsColourOnItsOwnSideOfAnEdge() throws {
        let gpu = try GPU()
        let w = 16, h = 8, edge = 8
        let red = (y: 60, cb: 100, cr: 220), white = (y: 220, cb: 128, cr: 128)
        let planes = try gpu.planes(w, h, tenBit: false, y: { x, _ in x < edge ? red.y : white.y }, c: { x, _ in x < edge / 2 ? (red.cb, red.cr) : (white.cb, white.cr) })
        let plain = try gpu.convert(planes, params(chromaWidth: w / 2, guided: false))
        let guided = try gpu.convert(planes, params(chromaWidth: w / 2, guided: true))
        let wantRed = rgb(red.y, red.cb, red.cr, tenBit: false), wantWhite = rgb(white.y, white.cb, white.cr, tenBit: false)
        // Far from the edge both are right.
        for x in [2, 13] {
            let want = x < edge ? wantRed : wantWhite
            #expect(maxDifference(plain(x, 4), want) < 1e-3 && maxDifference(guided(x, 4), want) < 1e-3)
        }
        // The last red column: bilinear has lost half its colour, guided has all of it.
        let half = rgb(red.y, (red.cb + white.cb) / 2, (red.cr + white.cr) / 2, tenBit: false)
        #expect(maxDifference(plain(edge - 1, 4), half) < 3e-3, "\(plain(edge - 1, 4)) vs \(half)")
        #expect(maxDifference(guided(edge - 1, 4), wantRed) < 3e-3, "\(guided(edge - 1, 4)) vs \(wantRed)")
        #expect(maxDifference(plain(edge - 1, 4), wantRed) > 0.05)
        // The first white column stays white in both.
        #expect(maxDifference(guided(edge, 4), wantWhite) < 3e-3 && maxDifference(plain(edge, 4), wantWhite) < 3e-3)
    }

    /// A horizontal edge likewise (chroma is halved vertically too, and centred between the rows there).
    @Test func keepsColourOnItsOwnSideOfAHorizontalEdge() throws {
        let gpu = try GPU()
        let w = 8, h = 16, edge = 8
        let blue = (y: 50, cb: 220, cr: 110), white = (y: 220, cb: 128, cr: 128)
        let planes = try gpu.planes(w, h, tenBit: false, y: { _, y in y < edge ? blue.y : white.y }, c: { _, y in y < edge / 2 ? (blue.cb, blue.cr) : (white.cb, white.cr) })
        let plain = try gpu.convert(planes, params(chromaWidth: w / 2, guided: false))
        let guided = try gpu.convert(planes, params(chromaWidth: w / 2, guided: true))
        let wantBlue = rgb(blue.y, blue.cb, blue.cr, tenBit: false), wantWhite = rgb(white.y, white.cb, white.cr, tenBit: false)
        // Rows either side of the edge are a quarter of a chroma texel into the other colour under bilinear.
        #expect(maxDifference(plain(4, edge - 1), wantBlue) > 0.05 && maxDifference(plain(4, edge), wantWhite) > 0.05)
        #expect(maxDifference(guided(4, edge - 1), wantBlue) < 3e-3, "\(guided(4, edge - 1)) vs \(wantBlue)")
        #expect(maxDifference(guided(4, edge), wantWhite) < 3e-3, "\(guided(4, edge)) vs \(wantWhite)")
    }

    /// A white line one pixel wide on blue: no chroma texel has luma like the line's, so there is nothing to
    /// prefer, and the result must be the bilinear one rather than a division of almost nothing by almost nothing.
    @Test func fallsBackToBilinearWhereNoNeighbourMatches() throws {
        let gpu = try GPU()
        let w = 16, h = 8
        let planes = try gpu.planes(w, h, tenBit: false, y: { x, _ in x == 7 ? 235 : 40 }, c: { x, _ in (150 + x * 10, 110 - x * 5) })
        let plain = try gpu.convert(planes, params(chromaWidth: w / 2, guided: false))
        let guided = try gpu.convert(planes, params(chromaWidth: w / 2, guided: true))
        #expect(simd_reduce_max(simd_abs(plain(7, 4) - guided(7, 4))) < 2e-3, "\(plain(7, 4)) vs \(guided(7, 4))")
    }
}

@Suite struct PresentTuningTests {
    @Test func sharpenScaleMultipliesTheConfiguredSharpness() {
        #expect(abs(MetalVideoRenderer.sharpenLobe(sharpness: 10, scale: 1) - 0.2) < 1e-7)
        #expect(abs(MetalVideoRenderer.sharpenLobe(sharpness: 10, scale: 0.5) - 0.1) < 1e-7)
        #expect(abs(MetalVideoRenderer.sharpenLobe(sharpness: 3, scale: 1) - 0.06) < 1e-7)
        #expect(MetalVideoRenderer.sharpenLobe(sharpness: 3, scale: 0) == 0)
        // Out of range: the scale never adds sharpening and never turns it into a blur.
        #expect(MetalVideoRenderer.sharpenLobe(sharpness: 3, scale: 4) == MetalVideoRenderer.sharpenLobe(sharpness: 3, scale: 1))
        #expect(MetalVideoRenderer.sharpenLobe(sharpness: 3, scale: -1) == 0)
        #expect(MetalVideoRenderer.sharpenLobe(sharpness: 99, scale: 1) == MetalVideoRenderer.sharpenLobe(sharpness: 10, scale: 1))
    }

    @Test func debandBoostWidensTheThresholdUpToTwice() {
        #expect(MetalVideoRenderer.debandThreshold(boost: 1) == 1.5 / 255)
        #expect(abs(MetalVideoRenderer.debandThreshold(boost: 2) - 3.0 / 255) < 1e-7)
        #expect(MetalVideoRenderer.debandThreshold(boost: 9) == MetalVideoRenderer.debandThreshold(boost: 2))
        #expect(MetalVideoRenderer.debandThreshold(boost: 0) == MetalVideoRenderer.debandThreshold(boost: 1))
    }

    private struct Present { var uv, deband, edr, ambient, sharpen: SIMD4<Float> }

    /// A soft edge through the present pass at 1:1: the pixel on its dark shoulder is pulled down by the
    /// sharpening, half as hard (or less) at half the scale, and not at all at zero.
    @Test func aScaledDownSharpeningDoesLessInTheShader() throws {
        let gpu = try GPU()
        let w = 8, h = 4, levels: [UInt8] = [77, 77, 77, 102, 153, 179, 179, 179]
        let source = try gpu.texture(w, h, .bgra8Unorm)
        var px = [UInt8]()
        for _ in 0..<h { for x in 0..<w { px += [levels[x], levels[x], levels[x], 255] } }
        source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
        func shoulder(scale: Float) throws -> Int {
            let out = try gpu.texture(w, h, .bgra8Unorm)
            try gpu.run("present_fragment", into: out, [source, source], Present(
                uv: SIMD4(1, 1, 0, 0), deband: .zero, edr: SIMD4(1, 0.5, 0, 0), ambient: .zero,
                sharpen: SIMD4(MetalVideoRenderer.sharpenLobe(sharpness: 10, scale: scale), 0, 0, 0)))
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return Int(bytes[(1 * w + 3) * 4])
        }
        let off = try shoulder(scale: 0), half = try shoulder(scale: 0.5), full = try shoulder(scale: 1)
        #expect(off == 102)
        #expect(full < half && half < off, "off \(off), half \(half), full \(full)")
        #expect(off - half <= (off - full + 1) / 2)
    }

    @Test func theUpscalerCeilingTakesTheLowerOfTheTwo() {
        #expect(Upscaler.videoToolbox.capped(by: .metalFX) == .metalFX)
        #expect(Upscaler.videoToolbox.capped(by: .off) == .off)
        #expect(Upscaler.metalFX.capped(by: .off) == .off)
        #expect(Upscaler.metalFX.capped(by: .videoToolbox) == .metalFX)
        #expect(Upscaler.off.capped(by: .videoToolbox) == .off)
        #expect(Upscaler.videoToolbox.capped(by: .videoToolbox) == .videoToolbox)
    }

    @Test func recentGPUIsTheAverageOfTheLastFullWindow() {
        let timing = FrameTiming()
        #expect(timing.recentGPU == nil)
        for i in 0..<119 { timing.add(gpu: i % 2 == 0 ? 1 : 3, total: 5, label: "test") }
        #expect(timing.recentGPU == nil)   // the window is 120 frames
        timing.add(gpu: 3, total: 5, label: "test")
        #expect(abs((timing.recentGPU ?? 0) - 2) < 1e-9)
        for _ in 0..<120 { timing.add(gpu: 4, total: 5, label: "test") }
        #expect(abs((timing.recentGPU ?? 0) - 4) < 1e-9)
    }
}

private final class Presented: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(rtp: UInt32, arrived: Double, shown: Double)] = []
    func add(_ rtp: UInt32, _ arrived: Double, _ shown: Double) { lock.withLock { list.append((rtp, arrived, shown)) } }
    var all: [(rtp: UInt32, arrived: Double, shown: Double)] { lock.withLock { list } }
}

/// The renderer itself, fed frames the way libwebrtc feeds them, drawing to an MTKView that is in no window.
@Suite(.serialized) @MainActor struct RendererDrawTests {
    private func frame(_ format: OSType, rtp: Int32, width: Int = 320, height: Int = 180) throws -> RTCVideoFrame {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &pb)
        let buffer = try #require(pb)
        // Mid grey with neutral chroma, whatever the depth: every byte 0x80 is that in 8 bits and close to it in 16.
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 0x80, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(rtp) * 1_000_000_000 / 90_000)
        f.timeStamp = rtp
        return f
    }

    private func view(_ renderer: MetalVideoRenderer) -> MTKView {
        let v = MTKView(frame: CGRect(x: 0, y: 0, width: 480, height: 300))
        renderer.configure(v)
        v.isPaused = true                 // the test ticks it by hand
        v.enableSetNeedsDisplay = false
        v.drawableSize = CGSize(width: 480, height: 300)
        return v
    }

    /// Waits (off the main thread's back) until `done` or two seconds have passed.
    private func wait(until done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func aFrameIsDrawnOnArrivalWithoutWaitingForATick() async throws {
        let renderer = try MetalVideoRenderer()
        #expect(renderer.drawOnArrival && renderer.chromaUpsampling && renderer.maxUpscaler == .videoToolbox)
        #expect(renderer.secondsSinceLastFrame == nil && renderer.recentGPUMs == nil)
        let presented = Presented()
        renderer.onFramePresented = { rtp, arrived, shown in presented.add(rtp, arrived, shown) }
        let v = view(renderer)
        v.draw()   // one tick: the renderer learns the layer
        #expect(renderer.framesRendered == 0)
        for (i, format) in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange].enumerated() {
            let f = try frame(format, rtp: Int32(3000 * (i + 1)))
            DispatchQueue.global().async { renderer.renderFrame(f) }   // the decoder's thread is not the main one
            try await wait { renderer.framesRendered == i + 1 }        // and no tick happens while we wait
            #expect(renderer.framesRendered == i + 1, "format \(i)")
        }
        #expect((renderer.secondsSinceLastFrame ?? -1) >= 0)
        // Each frame is reported once, with its own timestamp, shown no earlier than it arrived.
        try await wait { presented.all.count == 3 }
        #expect(presented.all.map(\.rtp) == [3000, 6000, 9000])
        for p in presented.all { #expect(p.shown >= p.arrived && p.shown - p.arrived < 2, "\(p)") }
        #expect(renderer.upscaleStatus.contains("320x180→480x270"), "\(renderer.upscaleStatus)")
        _ = v
    }

    @Test func settingsAndSizeChangesRedrawTheLastFrameOnTheNextTick() async throws {
        let renderer = try MetalVideoRenderer()
        let v = view(renderer)
        v.draw()
        let f = try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 3000)
        renderer.renderFrame(f)
        try await wait { renderer.framesRendered == 1 }
        #expect(renderer.framesRendered == 1)
        // The ceiling and the tuning hooks show in the status of the next frame that runs.
        renderer.maxUpscaler = .off
        renderer.sharpenScale = 0.5
        renderer.debandBoost = 2
        renderer.scaling = .stretch
        v.draw()   // a tick with a changed layout: asks the render queue for the last frame again
        renderer.renderFrame(try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 6000))
        try await wait { renderer.framesRendered == 2 }
        let status = renderer.upscaleStatus
        #expect(status.contains("bilinear 320x180→480x300") && status.contains("capped at off"), "\(status)")
        #expect(status.contains("sharpen 3 ×0.50") && status.contains("deband ×2.00"), "\(status)")
        // EDR: the tick switches the layer, the next frame is drawn into a float drawable.
        renderer.edr = try #require(EDRExpansion.allCases.first { $0 != .off })
        v.draw()
        #expect(v.colorPixelFormat == .rgba16Float)
        renderer.renderFrame(try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 9000))
        try await wait { renderer.framesRendered == 3 }
        #expect(renderer.upscaleStatus.contains("EDR"), "\(renderer.upscaleStatus)")
    }

    @Test(arguments: [false, true]) func thePolledAndPacedModesDrawOnTheTick(paced: Bool) async throws {
        let renderer = try MetalVideoRenderer()
        renderer.drawOnArrival = false
        renderer.framePacing = paced
        let v = view(renderer)
        v.draw()
        renderer.renderFrame(try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 3000))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(renderer.framesRendered == 0)   // nothing draws it until the display ticks
        v.draw()
        #expect(renderer.framesRendered == 1)
        v.draw()
        #expect(renderer.framesRendered == 1)   // and only once
    }

    @Test func switchingModesMidStreamLosesNoFrame() async throws {
        let renderer = try MetalVideoRenderer()
        let v = view(renderer)
        v.draw()
        renderer.renderFrame(try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 3000))
        try await wait { renderer.framesRendered == 1 }
        renderer.drawOnArrival = false
        renderer.renderFrame(try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 6000))
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(renderer.framesRendered == 1)
        v.draw()
        #expect(renderer.framesRendered == 2)
        renderer.drawOnArrival = true
        renderer.renderFrame(try frame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, rtp: 9000))
        try await wait { renderer.framesRendered == 3 }
        #expect(renderer.framesRendered == 3)
    }
}
