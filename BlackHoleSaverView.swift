import ScreenSaver
import ScreenCaptureKit
import MetalKit
import simd

// MARK: - Disk look & presets

/// The accretion disk's whole look in one bundle. Mirrors the tunables of
/// the blackhole_ghostty shader; values land in the fragment uniforms.
struct DiskLook {
    var temp: Float       // hottest annulus temperature, Kelvin
    var incl: Float       // inclination, rad: 0 face-on, ~1.57 edge-on
    var roll: Float       // rotation of the system in the screen plane
    var inner: Float      // inner edge, in Schwarzschild radii
    var outer: Float      // outer edge
    var opacity: Float    // how much the near disk hides what's behind it
    var doppler: Float    // 0 = no relativistic asymmetry, 1 = full
    var beam: Float       // beaming exponent: intensity scales as g^N
    var gain: Float       // disk emission brightness
    var contrast: Float   // streak contrast
    var wind: Float       // spiral winding tightness
    var speed: Float      // streak pattern speed
    var exposure: Float   // tonemap exposure
    var star: Float       // lensed starfield brightness
}

struct Preset {
    let name: String
    let look: DiskLook
}

/// Presets in the spirit of the Bruneton demo's scene settings (same values
/// as the blackhole_ghostty tuner).
enum Presets {
    static let all: [Preset] = [
        Preset(name: "Inferno", look: DiskLook(
            temp: 5500, incl: 1.50, roll: 0.35, inner: 1.8, outer: 8,
            opacity: 0.90, doppler: 0.60, beam: 2.5, gain: 2.2,
            contrast: 1.6, wind: 7, speed: 5, exposure: 1.40, star: 0)),
        Preset(name: "Gargantua", look: DiskLook(
            temp: 4500, incl: 1.52, roll: 0.10, inner: 2.2, outer: 7,
            opacity: 0.85, doppler: 0.35, beam: 2.0, gain: 1.4,
            contrast: 0.5, wind: 7, speed: 5, exposure: 1.20, star: 0)),
        Preset(name: "M87* Donut", look: DiskLook(
            temp: 3800, incl: 0.55, roll: -0.30, inner: 2.2, outer: 6,
            opacity: 0.45, doppler: 0.90, beam: 3.5, gain: 1.6,
            contrast: 0.4, wind: 3, speed: 2.5, exposure: 1.10, star: 0)),
        Preset(name: "Face-on Ember", look: DiskLook(
            temp: 6500, incl: 0.30, roll: 0.0, inner: 3.0, outer: 10,
            opacity: 0.50, doppler: 0.80, beam: 2.5, gain: 1.0,
            contrast: 1.1, wind: 7, speed: 5, exposure: 1.00, star: 0)),
        Preset(name: "Quasar", look: DiskLook(
            temp: 15000, incl: 1.30, roll: 0.35, inner: 3.0, outer: 14,
            opacity: 0.35, doppler: 1.00, beam: 4.0, gain: 1.2,
            contrast: 1.3, wind: 8, speed: 5, exposure: 0.80, star: 0)),
        Preset(name: "Blazar", look: DiskLook(
            temp: 18000, incl: 1.05, roll: 0.55, inner: 3.0, outer: 16,
            opacity: 0.30, doppler: 1.00, beam: 5.0, gain: 1.0,
            contrast: 1.5, wind: 9, speed: 6, exposure: 0.75, star: 0)),
        Preset(name: "Pure Lens", look: DiskLook(
            temp: 5500, incl: 1.50, roll: 0.35, inner: 1.8, outer: 8,
            opacity: 0.0, doppler: 1.00, beam: 2.5, gain: 0.0,
            contrast: 1.6, wind: 7, speed: 5, exposure: 1.00, star: 0.6)),
        Preset(name: "Zen", look: DiskLook(
            temp: 7000, incl: 1.45, roll: 0.15, inner: 3.5, outer: 7,
            opacity: 0.40, doppler: 0.50, beam: 2.0, gain: 0.5,
            contrast: 0.3, wind: 3, speed: 1.5, exposure: 0.70, star: 0)),
    ]
}

// MARK: - Settings

struct Settings {
    // Shadow radius in screen-height units. The visible footprint (shadow +
    // bright disk) reaches ~3x the shadow radius, so this range spans ~1.5%
    // of the screen area at the minimum to ~12% at the maximum.
    static let holeSizeRange = 0.03...0.09
    // How far the desktop visibly warps around the hole, in hole radii.
    // The top of the range reaches essentially the whole screen.
    static let warpReachRange = 5.0...25.0

    var presetIndex = 0      // index into Presets.all
    var holeSize    = 0.05   // shadow radius, screen-height units
    var driftSpeed  = 1.0    // 0 = static centered hole
    var warpReach   = 12.0   // warp window falloff, in hole radii
    var renderScale = 0.0    // fraction of native pixels; 0 = auto (cap height)

    var preset: Preset {
        Presets.all[min(max(presetIndex, 0), Presets.all.count - 1)]
    }

    private static var store: ScreenSaverDefaults? {
        let module = Bundle(for: BlackHoleSaverView.self).bundleIdentifier
            ?? "dev.s13k.BlackHoleSaver"
        return ScreenSaverDefaults(forModuleWithName: module)
    }

    static func load() -> Settings {
        var s = Settings()
        guard let d = store else { return s }
        d.register(defaults: [
            "presetIndex": s.presetIndex, "holeSize": s.holeSize,
            "driftSpeed": s.driftSpeed, "warpReach": s.warpReach,
            "renderScale": s.renderScale,
        ])
        s.presetIndex = d.integer(forKey: "presetIndex")
        s.holeSize    = d.double(forKey: "holeSize")
            .clamped(to: holeSizeRange)   // sanitize values from older builds
        s.driftSpeed  = d.double(forKey: "driftSpeed")
        s.warpReach   = d.double(forKey: "warpReach").clamped(to: warpReachRange)
        s.renderScale = d.double(forKey: "renderScale")
        return s
    }

    func save() {
        guard let d = Settings.store else { return }
        d.set(presetIndex, forKey: "presetIndex")
        d.set(holeSize,    forKey: "holeSize")
        d.set(driftSpeed,  forKey: "driftSpeed")
        d.set(warpReach,   forKey: "warpReach")
        d.set(renderScale, forKey: "renderScale")
        d.synchronize()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - View

// NOTE: the @objc name here must exactly match NSPrincipalClass in Info.plist.
@objc(BlackHoleSaverView)
final class BlackHoleSaverView: ScreenSaverView {

    private var mtkView: MTKView?
    private var renderer: Renderer?
    private var renderScale: CGFloat = 1.0

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        setup()
    }

    private func setup() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let view = MTKView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        // We drive rendering manually from animateOneFrame()
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        addSubview(view)
        mtkView = view

        let renderer = Renderer(device: device)
        view.delegate = renderer
        self.renderer = renderer

        applySettings()
    }

    /// Pushes the saved settings into the renderer and the drawable size.
    private func applySettings() {
        let s = Settings.load()
        renderer?.look       = s.preset.look
        renderer?.holeSize   = Float(s.holeSize)
        renderer?.driftSpeed = Float(s.driftSpeed)
        renderer?.warpReach  = Float(s.warpReach)
        renderScale = CGFloat(s.renderScale)
        updateDrawableSize()
    }

    /// The drawable runs at native pixels times the quality scale; the layer
    /// stretches it back to the view, so a lower scale only costs sharpness.
    /// Auto (scale 0) caps the drawable height: the geodesic cost grows with
    /// the square of the pixel height, and on a 5K panel the warp reads the
    /// same at ~1800 rows while costing a third as much.
    private static let autoMaxHeight: CGFloat = 1800
    private func updateDrawableSize() {
        guard let view = mtkView else { return }
        let backing = window?.backingScaleFactor ?? 2.0
        var scale = backing
        if !isPreview {
            if renderScale > 0 {
                scale *= renderScale
            } else {
                let pixelHeight = bounds.height * backing
                scale *= min(1.0, Self.autoMaxHeight / max(pixelHeight, 1))
            }
        }
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: max(bounds.width * scale, 1),
                                   height: max(bounds.height * scale, 1))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func startAnimation() {
        super.startAnimation()
        applySettings()
        // By now the view lives in the saver window, so we can capture
        // everything *below* that window = the actual desktop content.
        if renderer?.screenTexture == nil {
            renderer?.captureScreen(behind: window)
        }
    }

    override func animateOneFrame() {
        mtkView?.draw()
    }

    // MARK: Configure sheet

    private var sheet: NSWindow?
    private var presetPopup: NSPopUpButton?
    private var sizeSlider: NSSlider?
    private var driftSlider: NSSlider?
    private var warpSlider: NSSlider?
    private var qualityPopup: NSPopUpButton?
    private static let qualityScales: [Double] = [0.0, 1.0, 0.75, 0.5]

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if sheet == nil { sheet = buildSheet() }
        let s = Settings.load()
        presetPopup?.selectItem(at: s.presetIndex)
        sizeSlider?.doubleValue = s.holeSize
        driftSlider?.doubleValue = s.driftSpeed
        warpSlider?.doubleValue = s.warpReach
        let qi = Self.qualityScales.firstIndex(where: { abs($0 - s.renderScale) < 0.01 }) ?? 0
        qualityPopup?.selectItem(at: qi)
        return sheet
    }

    private func buildSheet() -> NSWindow {
        let presets = NSPopUpButton(frame: .zero, pullsDown: false)
        presets.addItems(withTitles: Presets.all.map(\.name))
        presetPopup = presets

        let size = NSSlider(value: 0.05,
                            minValue: Settings.holeSizeRange.lowerBound,
                            maxValue: Settings.holeSizeRange.upperBound,
                            target: nil, action: nil)
        sizeSlider = size

        let drift = NSSlider(value: 1.0, minValue: 0.0, maxValue: 2.5,
                             target: nil, action: nil)
        driftSlider = drift

        let warp = NSSlider(value: 12.0,
                            minValue: Settings.warpReachRange.lowerBound,
                            maxValue: Settings.warpReachRange.upperBound,
                            target: nil, action: nil)
        warpSlider = warp

        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        quality.addItems(withTitles: ["Auto (recommended)", "Full resolution",
                                      "Balanced (75%)", "Performance (50%)"])
        qualityPopup = quality

        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

        let grid = NSGridView(views: [
            [label("Preset:"), presets],
            [label("Hole size:"), size],
            [label("Drift speed:"), drift],
            [label("Warp reach:"), warp],
            [label("Quality:"), quality],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for row in 0..<grid.numberOfRows {
            grid.row(at: row).yPlacement = .center
        }

        let cancel = NSButton(title: "Cancel", target: self,
                              action: #selector(sheetCancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(sheetOK(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let content = NSView()
        for v in [grid, buttons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // controls column shares one width so the rows line up
            presets.widthAnchor.constraint(equalToConstant: 240),
            size.widthAnchor.constraint(equalTo: presets.widthAnchor),
            drift.widthAnchor.constraint(equalTo: presets.widthAnchor),
            warp.widthAnchor.constraint(equalTo: presets.widthAnchor),
            quality.widthAnchor.constraint(equalTo: presets.widthAnchor),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),

            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Black Hole"
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    @objc private func sheetOK(_ sender: Any?) {
        var s = Settings.load()
        s.presetIndex = presetPopup?.indexOfSelectedItem ?? s.presetIndex
        s.holeSize    = sizeSlider?.doubleValue ?? s.holeSize
        s.driftSpeed  = driftSlider?.doubleValue ?? s.driftSpeed
        s.warpReach   = warpSlider?.doubleValue ?? s.warpReach
        let qi = qualityPopup?.indexOfSelectedItem ?? 0
        s.renderScale = Self.qualityScales[min(max(qi, 0), Self.qualityScales.count - 1)]
        s.save()
        applySettings()
        dismissSheet(.OK)
    }

    @objc private func sheetCancel(_ sender: Any?) {
        dismissSheet(.cancel)
    }

    private func dismissSheet(_ code: NSApplication.ModalResponse) {
        guard let sheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: code)
        } else {
            sheet.close()
        }
    }
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {

    // Must match the struct layout in Shaders.metal (same member order).
    struct Uniforms {
        var time: Float = 0
        var aspect: Float = 1
        var center = SIMD2<Float>(0.5, 0.5)
        var holeRadius: Float = 0.10
        var hasCapture: Float = 0
        var diskTemp: Float = 5500
        var diskIncl: Float = 1.5
        var diskRoll: Float = 0.35
        var diskInner: Float = 1.8
        var diskOuter: Float = 8.0
        var diskOpacity: Float = 0.9
        var dopplerMix: Float = 0.6
        var diskBeam: Float = 2.5
        var diskGain: Float = 2.2
        var diskContrast: Float = 1.6
        var diskWind: Float = 7.0
        var diskSpeed: Float = 5.0
        var exposure: Float = 1.4
        var starGain: Float = 0.0
        var lensDepth: Float = 13.0
        var warpReach: Float = 12.0
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private(set) var screenTexture: MTLTexture?
    private var fallbackTexture: MTLTexture?
    private let startTime = CACurrentMediaTime()

    // Live settings, pushed by the view (defaults -> here).
    var look = Presets.all[0].look
    var holeSize: Float = 0.05
    var driftSpeed: Float = 1.0
    var warpReach: Float = 12.0

    init(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        super.init()
        buildPipeline()
        fallbackTexture = Self.makeSolidTexture(device: device)
    }

    private func buildPipeline() {
        // IMPORTANT: a .saver is a plugin, so Bundle.main is NOT our bundle.
        let bundle = Bundle(for: Renderer.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            NSLog("BlackHoleSaver: failed to load metallib from bundle")
            return
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        desc.fragmentFunction = library.makeFunction(name: "blackhole_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("BlackHoleSaver: pipeline error \(error)")
        }
    }

    /// Captures the screen content beneath the screensaver window via
    /// ScreenCaptureKit. Requires Screen Recording permission for the
    /// saver host process (legacyScreenSaver). Asynchronous: the texture
    /// appears a moment after the saver starts; the shader shows the
    /// starfield fallback until then.
    func captureScreen(behind window: NSWindow?) {
        let saverWindowID = CGWindowID(window?.windowNumber ?? 0)
        var displayID = CGMainDisplayID()
        if let screen = window?.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            displayID = CGDirectDisplayID(number.uint32Value)
        }
        let scale = window?.backingScaleFactor ?? 2

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else {
                    NSLog("BlackHoleSaver: no display available to capture")
                    return
                }
                // Exclude the saver overlay itself. On modern macOS the
                // visible saver surface is composited by WallpaperAgent,
                // not our own window, so matching windowNumber alone isn't
                // enough — drop everything at or above the screen-saver
                // window level (saver overlays, lock-screen chrome).
                let saverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
                let excluded = content.windows.filter {
                    $0.windowID == saverWindowID || $0.windowLayer >= saverLevel
                }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)

                let loader = MTKTextureLoader(device: self.device)
                let texture = try await loader.newTexture(cgImage: image, options: [
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                ])
                await MainActor.run { self.screenTexture = texture }
            } catch {
                NSLog("BlackHoleSaver: ScreenCaptureKit capture failed: \(error) (no Screen Recording permission?)")
            }
        }
    }

    private static func makeSolidTexture(device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        var pixel: UInt32 = 0xFF000000 // opaque black
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return tex
    }

    /// Unit Lissajous wander: 2+2 incommensurate sines per axis, so the
    /// orbit never visibly repeats.
    private static func lissa(_ t: Float) -> SIMD2<Float> {
        SIMD2<Float>(0.75 * sin(t * 0.37) + 0.25 * sin(t * 0.83 + 1.0),
                     0.70 * sin(t * 0.54 + 2.1) + 0.30 * sin(t * 1.07))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        let t = Float(CACurrentMediaTime() - startTime)

        var u = Uniforms()
        u.time = t
        u.aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        // Lazy non-repeating drift; amplitude keeps most of the disk on-screen.
        let wander = Self.lissa(t * 0.3 * driftSpeed)
        u.center = SIMD2<Float>(0.5, 0.5) + wander * SIMD2<Float>(0.16, 0.12)
        u.holeRadius = holeSize
        u.hasCapture = screenTexture != nil ? 1 : 0

        u.diskTemp = look.temp
        u.diskIncl = look.incl
        u.diskRoll = look.roll
        u.diskInner = look.inner
        u.diskOuter = look.outer
        u.diskOpacity = look.opacity
        u.dopplerMix = look.doppler
        u.diskBeam = look.beam
        u.diskGain = look.gain
        u.diskContrast = look.contrast
        u.diskWind = look.wind
        u.diskSpeed = look.speed
        u.exposure = look.exposure
        // With no capture the desktop sky is black; make sure the lensing
        // still reads by keeping a starfield up.
        u.starGain = screenTexture != nil ? look.star : max(look.star, 0.6)
        u.warpReach = warpReach

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(screenTexture ?? fallbackTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
