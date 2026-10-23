import UIKit
import MetalKit
#if !targetEnvironment(simulator)
import MetalFX
#endif

/// Isolated display-chain tests. No game render targets, timing or settings are
/// changed. The generated scene supplies known, per-pixel depth and motion.
enum GraphicsExperimentMode: String { case hdr, fg60, fg120 }

@available(iOS 16.0, macCatalyst 16.0, *)
final class GraphicsExperimentController: UIViewController, MTKViewDelegate {
    typealias Mode = GraphicsExperimentMode
    private let mode: Mode
    private let information = UILabel()
    private var canvas: MTKView!
    private var queue: MTLCommandQueue!
    private var displayPipeline: MTLRenderPipelineState!
    private var scenePipeline: MTLComputePipelineState!
    #if targetEnvironment(simulator)
    private var midpointPipeline: MTLComputePipelineState!
    private var previousDepth: MTLTexture!
    private var reference: MTLTexture!
    private var probeRequested = false
    private var probeResult: [String: Any] = [:]
    #endif
    private var colors: [MTLTexture] = []
    private var depth: MTLTexture!, motion: MTLTexture!, generated: MTLTexture!
    #if !targetEnvironment(simulator)
    private var interpolatorStorage: AnyObject?
    @available(iOS 26.0, macCatalyst 26.0, *)
    private var interpolator: MTLFXFrameInterpolator? {
        get { interpolatorStorage as? MTLFXFrameInterpolator }
        set { interpolatorStorage = newValue }
    }
    #endif
    private let presents = PresentedFrames()
    private let permits = DispatchSemaphore(value: 3)
    private var begun = CACurrentMediaTime(), lastReport = 0.0
    private var sourceFrames = 0, generatedFrames = 0, submitted = 0, completed = 0
    private var displaySource: MTLTexture?
    private var lastX = Float(0), realNext = false, failed = false
    private var hdrSample: Float?
    private var suspended = false
    private var observers: [NSObjectProtocol] = []
    private let pauseButton = UIButton(type: .system), comparisonButton = UIButton(type: .system)
    private var manuallyPaused = false, interpolationEnabled = true, historyValid = false
    private var historyResets = 0, cuts = 0, repeats = 0
    private var lastScene = 0
    private var samples: [[String: Any]] = []
    private var lastCounts = (time: 0.0, source: 0, generated: 0, output: 0)
    private var rates = (source: 0.0, generated: 0.0, output: 0.0)
    private var sourceRate: Int { mode == .fg60 ? 30 : 60 }
    private var targetRate: Int { mode == .fg60 ? 60 : 120 }
    init(mode: Mode) { self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic controller") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        information.textColor = .white; information.numberOfLines = 0
        information.font = .monospacedSystemFont(ofSize: UIDevice.current.userInterfaceIdiom == .phone ? 11 : 16, weight: .medium)
        information.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        information.text = L("图形试验准备中…"); information.accessibilityIdentifier = "experiment.status"
        let close = UIButton(type: .system); close.setTitle(L("结束试验"), for: .normal)
        close.accessibilityIdentifier = "experiment.close"
        close.addTarget(self, action: #selector(finish), for: .touchUpInside)
        pauseButton.setTitle(L("暂停试验"), for: .normal)
        pauseButton.accessibilityIdentifier = "experiment.pause"
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        comparisonButton.setTitle(L("插帧：开"), for: .normal)
        comparisonButton.accessibilityIdentifier = "experiment.interpolation"
        comparisonButton.addTarget(self, action: #selector(toggleInterpolation), for: .touchUpInside)
        comparisonButton.isHidden = mode == .hdr; pauseButton.isHidden = mode == .hdr
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        canvas = MTKView(frame: .zero, device: device)
        canvas.autoResizeDrawable = false
        canvas.drawableSize = CGSize(width: 1280, height: 720)
        canvas.colorPixelFormat = mode == .hdr ? .rgba16Float : .bgra8Unorm
        canvas.framebufferOnly = mode != .hdr // HDR test reads back one real floating-point output pixel.
        canvas.preferredFramesPerSecond = mode == .hdr ? 60 : targetRate
        if mode == .hdr, let layer = canvas.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            layer.wantsExtendedDynamicRangeContent = true
        }
        let buttons = UIStackView(arrangedSubviews: [comparisonButton, pauseButton, close]); buttons.spacing = 16
        buttons.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        view.addSubview(canvas); view.addSubview(information); view.addSubview(buttons)
        [canvas!, information, buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor), canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            information.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            information.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)])
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = lib.makeFunction(name: "vertexMain")
            p.fragmentFunction = lib.makeFunction(name: mode == .hdr ? "hdrMain" : "sampleMain")
            p.colorAttachments[0].pixelFormat = canvas.colorPixelFormat
            displayPipeline = try device.makeRenderPipelineState(descriptor: p)
            if mode != .hdr {
                scenePipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "sceneMain")!)
                try configureInterpolation(device)
            }
            canvas.delegate = self
        } catch { fail(error.localizedDescription) }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspended = true; self?.canvas.isPaused = true; self?.historyValid = false
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.suspended = false; self.presents.reset()
            #if !targetEnvironment(simulator)
            if #available(iOS 26.0, macCatalyst 26.0, *) { self.interpolator?.shouldResetHistory = true }
            #endif
            self.canvas.isPaused = self.failed || self.manuallyPaused
            self.historyValid = false; self.realNext = false
        })
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let screen = view.window?.screen ?? UIScreen.main
        if mode == .fg120 && (UIDevice.current.userInterfaceIdiom == .phone || screen.maximumFramesPerSecond < 120) { fail(L("当前屏幕不支持 120Hz")) }
        if mode == .hdr && screen.potentialEDRHeadroom <= 1 { fail(L("当前屏幕没有 EDR 高亮余量")) }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func fail(_ message: String) {
        failed = true; canvas?.isPaused = true
        information.text = LF("图形试验未运行：%@\n游戏设置保持不变。", message)
        NSLog("PJDV experiment %@ failed: %@", mode.rawValue, message)
    }
    private func configureInterpolation(_ device: MTLDevice) throws {
        #if targetEnvironment(simulator)
        guard mode == .fg60 else {
            throw NSError(domain: "GraphicsExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey: L("模拟器仅测试 30→60")])
        }
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        midpointPipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "simMidpoint")!)
        colors = (0..<2).map { _ in texture(device, .rgba8Unorm, [.shaderWrite, .shaderRead]) }
        depth = texture(device, .r32Float, [.shaderWrite, .shaderRead])
        previousDepth = texture(device, .r32Float, [.shaderWrite, .shaderRead])
        motion = texture(device, .rg16Float, [.shaderWrite, .shaderRead])
        generated = texture(device, .bgra8Unorm, [.shaderWrite, .shaderRead])
        reference = texture(device, .rgba8Unorm, [.shaderWrite, .shaderRead])
        NSLog("PJDV fg60 backend=simulator-known-motion; MetalFX unavailable; synthetic scene only")
        #else
        guard #available(iOS 26.0, macCatalyst 26.0, *) else {
            throw NSError(domain: "GraphicsExperiment", code: 4, userInfo: [NSLocalizedDescriptionKey: L("帧生成实验需要 iOS 26 或更新系统；游戏仍可正常运行。")])
        }
        guard MTLFXFrameInterpolatorDescriptor.supportsDevice(device) else {
            throw NSError(domain: "GraphicsExperiment", code: 2, userInfo: [NSLocalizedDescriptionKey: L("设备不支持 MetalFX 插帧")])
        }
        let desc = MTLFXFrameInterpolatorDescriptor()
        desc.inputWidth = 1280; desc.inputHeight = 720; desc.outputWidth = 1280; desc.outputHeight = 720
        desc.colorTextureFormat = .rgba8Unorm; desc.outputTextureFormat = .bgra8Unorm
        desc.depthTextureFormat = .r32Float; desc.motionTextureFormat = .rg16Float
        guard let fx = desc.makeFrameInterpolator(device: device) else {
            throw NSError(domain: "GraphicsExperiment", code: 3, userInfo: [NSLocalizedDescriptionKey: L("无法创建 MetalFX 插帧器")])
        }
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1280, height: 720, mipmapped: false)
            d.storageMode = .private; d.usage = usage
            return device.makeTexture(descriptor: d)!
        }
        colors = (0..<2).map { _ in texture(.rgba8Unorm, fx.colorTextureUsage.union([.shaderWrite, .shaderRead])) }
        depth = texture(.r32Float, fx.depthTextureUsage.union(.shaderWrite))
        motion = texture(.rg16Float, fx.motionTextureUsage.union(.shaderWrite))
        generated = texture(.bgra8Unorm, fx.outputTextureUsage.union(.shaderRead))
        fx.deltaTime = 1 / Float(sourceRate); fx.nearPlane = 0.1; fx.farPlane = 100
        fx.fieldOfView = 60; fx.aspectRatio = 16 / 9; fx.motionVectorScaleX = 1; fx.motionVectorScaleY = 1
        fx.shouldResetHistory = true; interpolator = fx
        #endif
    }
    private func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1280, height: 720, mipmapped: false)
        d.storageMode = .private; d.usage = usage
        return device.makeTexture(descriptor: d)!
    }
    @objc private func togglePause() {
        manuallyPaused.toggle(); canvas.isPaused = manuallyPaused
        pauseButton.setTitle(L(manuallyPaused ? "恢复试验" : "暂停试验"), for: .normal)
        if !manuallyPaused { historyValid = false; realNext = false; presents.reset() }
        report(force: true)
    }
    @objc private func toggleInterpolation() {
        interpolationEnabled.toggle(); historyValid = false; realNext = false
        comparisonButton.setTitle(L(interpolationEnabled ? "插帧：开" : "插帧：关（30 FPS 对照）"), for: .normal)
        report(force: true)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard !failed, !suspended, permits.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { permits.signal(); return }
        var selected: MTLTexture?
        var kind = "hdr", logicalTime = 0.0
        #if targetEnvironment(simulator)
        var probeBuffers: [MTLBuffer] = []
        #endif
        if mode != .hdr {
            if realNext {
                selected = displaySource; realNext = false; kind = "real"
                logicalTime = Double(sourceFrames - 1) / Double(sourceRate)
            } else {
                let index = sourceFrames % 2
                let scene = sourceFrames / (sourceRate * 8)
                let x = Float(1280) * (0.5 + 0.3 * sin(Float(sourceFrames) / Float(sourceRate) * 0.8 + Float(scene) * 1.9))
                let cut = sourceFrames > 0 && scene != lastScene
                if cut { historyValid = false; cuts += 1 }
                #if targetEnvironment(simulator)
                if historyValid, let blit = cb.makeBlitCommandEncoder() {
                    blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                              sourceSize: MTLSize(width: 1280, height: 720, depth: 1), to: previousDepth,
                              destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                    blit.endEncoding()
                }
                #endif
                encodeScene(cb, color: colors[index], x: x, previousX: historyValid ? lastX : x, scene: scene)
                if historyValid && interpolationEnabled {
                    #if targetEnvironment(simulator)
                    var delta = x - lastX
                    let compute = cb.makeComputeCommandEncoder()!
                    compute.setComputePipelineState(midpointPipeline)
                    compute.setTexture(colors[1-index], index: 0); compute.setTexture(colors[index], index: 1)
                    compute.setTexture(previousDepth, index: 2); compute.setTexture(depth, index: 3)
                    compute.setTexture(generated, index: 4)
                    compute.setBytes(&delta, length: MemoryLayout<Float>.size, index: 0)
                    compute.dispatchThreadgroups(MTLSize(width: 80, height: 45, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    compute.endEncoding()
                    if !probeRequested && sourceFrames >= 45 {
                        probeRequested = true
                        // Analytic reference is read back only; it never feeds the output.
                        encodeScene(cb, color: reference, x: (x + lastX) * 0.5, previousX: x, scene: scene,
                                    depthTarget: texture(view.device!, .r32Float, [.shaderWrite]),
                                    motionTarget: texture(view.device!, .rg16Float, [.shaderWrite]))
                        let blit = cb.makeBlitCommandEncoder()!
                        for texture in [colors[1-index], colors[index], generated!, reference!] {
                            let buffer = view.device!.makeBuffer(length: 1280 * 720 * 4, options: .storageModeShared)!
                            probeBuffers.append(buffer)
                            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                                      sourceSize: MTLSize(width: 1280, height: 720, depth: 1), to: buffer,
                                      destinationOffset: 0, destinationBytesPerRow: 1280 * 4, destinationBytesPerImage: 1280 * 720 * 4)
                        }
                        blit.endEncoding()
                    }
                    #else
                    guard #available(iOS 26.0, macCatalyst 26.0, *), let fx = interpolator else { permits.signal(); return }
                    fx.colorTexture = colors[index]; fx.prevColorTexture = colors[1-index]
                    fx.depthTexture = depth; fx.motionTexture = motion; fx.outputTexture = generated
                    fx.encode(commandBuffer: cb); fx.shouldResetHistory = false
                    #endif
                    selected = generated; generatedFrames += 1; kind = "generated"
                    logicalTime = (Double(sourceFrames) - 0.5) / Double(sourceRate)
                } else if historyValid {
                    // A/B control: the same 30 source FPS and 60 display callbacks,
                    // but repeat the previous image instead of generating a midpoint.
                    selected = displaySource; repeats += 1; kind = "repeat"
                    logicalTime = Double(sourceFrames - 1) / Double(sourceRate)
                } else {
                    selected = colors[index]; historyResets += 1; kind = cut ? "cut" : "reset"
                    logicalTime = Double(sourceFrames) / Double(sourceRate)
                    #if !targetEnvironment(simulator)
                    if #available(iOS 26.0, macCatalyst 26.0, *) { interpolator?.shouldResetHistory = true }
                    #endif
                }
                displaySource = colors[index]
                realNext = sourceFrames > 0
                lastX = x; lastScene = scene; sourceFrames += 1; historyValid = true
            }
        }
        let encoder = cb.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(displayPipeline)
        if let selected { encoder.setFragmentTexture(selected, index: 0) }
        var peak = Float(min(4, (view.window?.screen ?? UIScreen.main).potentialEDRHeadroom))
        encoder.setFragmentBytes(&peak, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        var sample: MTLBuffer?
        if mode == .hdr && hdrSample == nil {
            sample = view.device!.makeBuffer(length: 256, options: .storageModeShared)
            let blit = cb.makeBlitCommandEncoder()!
            blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 1152, y: 432, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                      to: sample!, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endEncoding()
        }
        let readback = sample
        #if targetEnvironment(simulator)
        let readbacks = probeBuffers
        #endif
        cb.addCompletedHandler { [weak self, permits] command in
            permits.signal()
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = command.error { self.fail(error.localizedDescription); return }
                self.completed += 1
                #if targetEnvironment(simulator)
                if !readbacks.isEmpty { self.analyzeProbe(readbacks) }
                #endif
                if let readback { self.hdrSample = Float(Float16(bitPattern: readback.contents().load(as: UInt16.self))) }
            }
        }
        #if targetEnvironment(simulator)
        cb.addCompletedHandler { [weak self] command in
            if command.status == .completed { self?.presents.record(command.gpuEndTime) }
        }
        #else
        drawable.addPresentedHandler { [weak self] in self?.presents.record($0.presentedTime) }
        #endif
        cb.present(drawable); cb.commit(); submitted += 1
        if mode != .hdr {
            samples.append(["kind": kind, "logicalTime": logicalTime, "wallTime": CACurrentMediaTime() - begun,
                            "sourceFrames": sourceFrames, "generatedFrames": generatedFrames])
            if samples.count > 240 { samples.removeFirst(samples.count - 240) }
        }
        report()
    }
    private func encodeScene(_ cb: MTLCommandBuffer, color: MTLTexture, x: Float, previousX: Float, scene: Int,
                             depthTarget: MTLTexture? = nil, motionTarget: MTLTexture? = nil) {
        var u = SIMD4<Float>(x, previousX, 1280, 720), sceneID = UInt32(scene)
        let compute = cb.makeComputeCommandEncoder()!
        compute.setComputePipelineState(scenePipeline)
        compute.setTexture(color, index: 0); compute.setTexture(depthTarget ?? depth, index: 1); compute.setTexture(motionTarget ?? motion, index: 2)
        compute.setBytes(&u, length: MemoryLayout.size(ofValue: u), index: 0)
        compute.setBytes(&sceneID, length: MemoryLayout.size(ofValue: sceneID), index: 1)
        compute.dispatchThreadgroups(MTLSize(width: 80, height: 45, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }
    #if targetEnvironment(simulator)
    private func analyzeProbe(_ buffers: [MTLBuffer]) {
        let bytes = buffers.map { $0.contents().assumingMemoryBound(to: UInt8.self) }
        var previousDifference = 0, currentDifference = 0, referenceError = 0, exactPixels = 0
        var blendError = 0
        for pixel in 0..<(1280 * 720) {
            let offset = pixel * 4
            var previous = 0, current = 0, error = 0
            for channel in 0..<3 {
                let value = Int(bytes[2][offset + (2-channel)]) // generated BGRA, others RGBA
                previous += abs(value - Int(bytes[0][offset + channel]))
                current += abs(value - Int(bytes[1][offset + channel]))
                error += abs(value - Int(bytes[3][offset + channel]))
                blendError += abs((Int(bytes[0][offset + channel]) + Int(bytes[1][offset + channel])) / 2 - Int(bytes[3][offset + channel]))
            }
            if previous > 3 { previousDifference += 1 }
            if current > 3 { currentDifference += 1 }
            if error <= 3 { exactPixels += 1 }; referenceError += error
        }
        probeResult = ["width": 1280, "height": 720, "differentFromPreviousPixels": previousDifference,
                       "differentFromCurrentPixels": currentDifference,
                       "referenceMeanAbsoluteByteError": Double(referenceError) / Double(1280 * 720 * 3),
                       "unwarpedBlendMeanAbsoluteByteError": Double(blendError) / Double(1280 * 720 * 3),
                       "referencePixelsWithinOneByte": exactPixels,
                       "passed": previousDifference > 100 && currentDifference > 100 && referenceError < blendError && Double(referenceError) / Double(1280 * 720 * 3) < 0.5]
        if let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            for (index, name) in ["previous", "current", "generated", "reference"].enumerated() {
                let data = Data(bytes: buffers[index].contents(), count: 1280 * 720 * 4)
                let flags: CGBitmapInfo = index == 2 ? [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)] : [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
                if let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: 1280, height: 720, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                    try? UIImage(cgImage: image).pngData()?.write(to: root.appendingPathComponent("PJDV-fg60-\(name).png"), options: .atomic)
                }
            }
        }
        NSLog("PJDV fg60 midpoint probe %@", String(describing: probeResult))
    }
    #endif
    private func report(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastReport > 1 else { return }; lastReport = now
        let screen = view.window?.screen ?? UIScreen.main
        let fps = presents.fps(at: now)
        if now - lastCounts.time > 0.5 {
            let dt = now - lastCounts.time
            rates = (Double(sourceFrames - lastCounts.source) / dt, Double(generatedFrames - lastCounts.generated) / dt, Double(completed - lastCounts.output) / dt)
            lastCounts = (now, sourceFrames, generatedFrames, completed)
        }
        if manuallyPaused { rates = (0, 0, 0) }
        #if targetEnvironment(simulator)
        let timingName = L("GPU 完成（非屏幕呈现）")
        #else
        let timingName = L("实际呈现")
        #endif
        #if targetEnvironment(simulator)
        let backend = "Simulator known-motion warp (not MetalFX)"
        let name = mode == .hdr ? L("HDR / EDR 测试图") : L("30→60 模拟器插帧实验")
        #else
        let backend = "MetalFX"
        let name = mode == .hdr ? L("HDR / EDR 测试图") : LF("MetalFX %d→%d 测试场景", sourceRate, targetRate)
        #endif
        information.text = LF("%@（实验性）\n独立测试场景，尚未接入游戏\n%@ %.1f fps · 屏幕上限 %dHz\n源帧提交 %d · 生成帧 %d\nEDR 当前 %.2f / 潜在 %.2f\nHDR GPU 采样：%@", name, timingName, fps, screen.maximumFramesPerSecond, sourceFrames, generatedFrames, screen.currentEDRHeadroom, screen.potentialEDRHeadroom, hdrSample.map { String(format: "%.3f", $0) } ?? "—")
        if mode != .hdr {
            #if targetEnvironment(simulator)
            let backendLabel = L("模拟器替代算法（非 MetalFX）")
            #else
            let backendLabel = "MetalFX"
            #endif
            information.text = "\(name)\n\(L("独立场景；非游戏插帧"))\n\(backendLabel)\n\(L("源帧 / 生成 / GPU 完成")) \(String(format: "%.1f / %.1f / %.1f", rates.source, rates.generated, rates.output)) FPS\n\(L("镜头切换 / 历史重置")) \(cuts) / \(historyResets)"
        }
        var result: [String: Any] = ["mode": mode.rawValue, "scope": "synthetic display-chain test; not game frame generation or native game HDR",
            "device": canvas.device?.name ?? "", "elapsed": now - begun, "sourceRateTarget": sourceRate, "outputRateTarget": mode == .hdr ? 60 : targetRate,
            "sourceSubmitted": sourceFrames, "generatedEncoded": generatedFrames, "outputSubmitted": submitted, "outputCompleted": completed,
            "presentedFPS": fps, "screenMaximumHz": screen.maximumFramesPerSecond, "currentEDRHeadroom": screen.currentEDRHeadroom,
            "potentialEDRHeadroom": screen.potentialEDRHeadroom, "hdrPixelLinear": hdrSample as Any? ?? NSNull(), "failed": failed,
            "backend": backend, "interpolationEnabled": interpolationEnabled, "paused": manuallyPaused,
            "sourceFPS": rates.source, "generatedFPS": rates.generated, "completedFPS": rates.output,
            "historyResets": historyResets, "sceneCuts": cuts, "repeatedFrames": repeats, "recentFrames": samples,
            "timingScope": "GPU completion only on Simulator; not physical display FPS", "gameAttached": false]
        #if targetEnvironment(simulator)
        result["midpointProbe"] = probeResult
        #endif
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: root.appendingPathComponent("PJDV-experiment-\(mode.rawValue).json"), options: .atomic)
        }
    }
    @objc private func finish() { report(force: true); canvas.isPaused = true; dismiss(animated: true) }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); canvas?.isPaused = true; canvas?.delegate = nil
        (canvas?.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = false
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V {float4 p [[position]]; float2 uv;};
    vertex V vertexMain(uint i [[vertex_id]]) {
        float2 uv=float2((i<<1)&2,i&2); return {float4(uv*float2(2,-2)+float2(-1,1),0,1),uv};
    }
    fragment float4 sampleMain(V v [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);return t.sample(s,v.uv);
    }
    fragment float4 hdrMain(V v [[stage_in]], constant float &peak [[buffer(0)]]) {
        float c=0.02;
        if(v.uv.y>.3 && v.uv.y<.8) {uint band=min(uint(v.uv.x*5),4u);c=1+(peak-1)*float(band)/4;}
        return float4(float3(c),1);
    }
    kernel void sceneMain(texture2d<float,access::write> color [[texture(0)]], texture2d<float,access::write> depth [[texture(1)]],
                          texture2d<float,access::write> motion [[texture(2)]], constant float4 &u [[buffer(0)]], constant uint &scene [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
        if(p.x>=uint(u.z)||p.y>=uint(u.w))return;
        bool object=abs(float(p.x)-u.x)<110 && abs(float(p.y)-u.w*.52)<150;
        float checker=float(((p.x/24)+(p.y/24))%2);
        float3 rgb=object?float3(.05,.75,.65):float3(.03+checker*.06)*(scene%2?float3(1,1.5,2):float3(1));
        // Band-limit the moving texture so the analytic reference does not
        // compare a point-sampled hard stripe against a bilinearly warped one.
        if(object) {float stripe=pow(.5+.5*cos((float(p.x)-u.x)*.2617994),8.0);rgb=mix(rgb,float3(.95,.3,.15),stripe);}
        color.write(float4(rgb,1),p);depth.write(float4(object?.5:.99),p);
        motion.write(float4(object?u.y-u.x:0,0,0,0),p);
    }
    // Simulator-only substitute. This is a two-frame warp for this scene's
    // rigid horizontal object with known displacement. It is NOT optical flow,
    // MetalFX, a generic game interpolator, or a new render at the midpoint.
    kernel void simMidpoint(texture2d<float> previous [[texture(0)]], texture2d<float> current [[texture(1)]],
                            texture2d<float> oldDepth [[texture(2)]], texture2d<float> newDepth [[texture(3)]],
                            texture2d<float,access::write> output [[texture(4)]], constant float &dx [[buffer(0)]],
                            uint2 p [[thread_position_in_grid]]) {
        if(p.x>=output.get_width()||p.y>=output.get_height())return;
        constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
        float2 uv=float2(p)+.5;
        float2 a=uv-float2(dx*.5,0), b=uv+float2(dx*.5,0);
        float4 color;
        if(oldDepth.sample(s,a).r<.75 && newDepth.sample(s,b).r<.75) {
            color=(previous.sample(s,a)+current.sample(s,b))*.5;
        } else {
            color=oldDepth.read(p).r>.75?previous.read(p):current.read(p);
        }
        output.write(color,p);
    }
    """
}
