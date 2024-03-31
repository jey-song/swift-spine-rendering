import Foundation
import Logging
import Metal
import MetalExtension
import MetalKit
import SpineSharedStructs

public extension MTLPixelFormat {
    static let spineDepthTexture: MTLPixelFormat = .depth32Float

    /// We will use for any 4 component texture in spine
    /// It is also format, which we get from texture loading, so we had to stick to it, or change how we are loading texture
    static let spineTexture: MTLPixelFormat = .bgra8Unorm
}

public protocol SpineViewRenderer: AnyObject {

    var bonesFilter: SpineSkeletonBonesFilter { get }

    /// We are using triple buffering. This index define which buffer we should use on this frame rendering
    var currentBufferIndex: Int { get set }

    /// Render skeleton using `renderPassDescriptor`. `animationMetalStack` should have updated `screenFrame` before calling this method
    /// - Parameters:
    ///   - renderPassDescriptor: pass descriptor, which already has `colorAttachments[0]` and `depthAttachment`. colorAttachments[0] is texture with output
    ///   - commandBuffer: command buffer, which should be used to group rendering of all needed  skeletons
    func render(renderPassDescriptor: MTLRenderPassDescriptor, using commandBuffer: MTLCommandBuffer)
}

#if canImport(UIKit)
import UIKit

// TODO: Crossplatform compilation with macOS here is questionable, as `CADisplayLink` available only since macOS 14.0
public final class SpineView: MTKView {

    public var cameraFrame: ScreenFrame

    public var presentedSkeletons: [SpineSkeleton] { renderingElements.values.map { $0.skeleton } }

    // TODO: Provide only skeleton names, instead of whole skeletons
    /// If needed, sort skeletons in needed order for current frame
    public var skeletonSorter: (inout [SpineSkeleton]) -> Void = { _ in }

    public var speed: Double {
        get { clock.speed }
        set { clock.speed = newValue }
    }

    public var showFpsCount: Bool = true {
        didSet {
            fpsLabel.isHidden = !showFpsCount
        }
    }

    public init(metalStack: SpineMetalStack,
                currentMediaTimeProvider: CurrentMediaTimeProvider,
                cameraFrame: ScreenFrame,
                logger: Logger) {
        self.metalStack = metalStack
        self.cameraFrame = cameraFrame
        let bounds = metalStack.renderAreaSize.bounds
        self.clock = SpineSkeletonClockMediaTimeImpl(currentMediaTimeProvider: currentMediaTimeProvider)
        self.logger = logger

        super.init(frame: bounds, device: metalStack.generalMetalStack.device)
        depthStencilPixelFormat = .spineDepthTexture
        framebufferOnly = false

        addFpsLabel()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: API

    public func add(skeleton: SpineSkeleton) {
        let renderer = SpineViewSkeletonRenderer(spineSkeleton: skeleton,
                                                 spineMetalStack: metalStack,
                                                 logger: logger)
        let renderingElement = RenderingElement(skeleton: skeleton, renderer: renderer)
        renderingElements[skeleton.name] = renderingElement
    }

    /// - complexity: O(n)
    public func remove(skeleton: SpineSkeleton) {
        renderingElements.removeValue(forKey: skeleton.name)
    }

    /// - complexity: O(n)
    public func contains(skeleton: SpineSkeleton) -> Bool {
        renderingElements[skeleton.name] != nil
    }

    private(set)
    public var isPlaying: Bool = false

    /// Should be called in order for animation to start playing
    public func play() {
        guard !isPlaying else {
            return
        }
        isPlaying = true
        clock.start()
        addDisplayLinkIfNeeded()
    }

    public func pause() {
        isPlaying = false
        removeDisplayLink()
    }

    // MARK: UIView overrides

    public override func didMoveToWindow() {
        guard window != nil else {
            removeDisplayLink()
            return
        }

        guard isPlaying else {
            return
        }

        addDisplayLinkIfNeeded()
    }

    // MARK: Private

    private let logger: Logger

    private let metalStack: SpineMetalStack
    private var displayLink: CADisplayLink?

    private struct RenderingElement {
        let skeleton: SpineSkeleton
        let renderer: SpineViewRenderer
    }

    /// keys is skeleton name
    private var renderingElements = [String: RenderingElement]()

    private let availableFramesIndecesStorage = AvailableFramesIndecesStorage()
    private var renderedFrameTimes = RenderedFrameTimes()

    private let clock: RestartableSpineClock

    @objc
    private func update() {
        // We are using triple buffering. For now we limit this calls to main thread, so we can avoid locks.
        // https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html .

        if showFpsCount {
            updateFps(renderedFrameTimes.framesCountInLastSecond())
        }

        let currentFameIndex = availableFramesIndecesStorage.reserveFrameIndex()

        guard let currentFameIndex else {
            logger.warning("Skipping frame, because no free buffer")
            return
        }

#if DEBUG
        metalStack.captureScope.begin()
#endif // DEBUG

        if isPlaying {
            clock.cutCurrentFrameTime()
        } else {
            clock.pause()
        }

        let elapsedSinceLastUpdate = Float(clock.delta())

        metalStack.set(cameraFrame.cgRect, for: currentFameIndex)

        // Update all skeletons positions
        renderingElements.values.forEach { $0.skeleton.updateState(elapsedSinceLastUpdate) }

        var sortedElements = Array(renderingElements.values)

        sortedElements.sort { (lhs: RenderingElement, rhs: RenderingElement) in
            let lBounds = lhs.skeleton.bounds(bonesFilter: lhs.renderer.bonesFilter)
            let rBounds = rhs.skeleton.bounds(bonesFilter: rhs.renderer.bonesFilter)
            return lBounds.y > rBounds.y
        }

        var sortedSkeletons = sortedElements.map { $0.skeleton }
        skeletonSorter(&sortedSkeletons)

        let sortedNames = sortedSkeletons.map { $0.name }

        let commandQueue = metalStack.generalMetalStack.commandQueue
        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "CommandBuffer for all skeletons"

        let currentDrawable = currentDrawable!

        var loadAction: MTLLoadAction = .clear

        let drawableTexture = currentDrawable.texture

        for skeletonName in sortedNames {

            guard let renderingElement = renderingElements[skeletonName] else {
                fatalError("Somehow we trying to render not presented skeleton: \(skeletonName)")
                continue
            }

            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = drawableTexture
            renderPassDescriptor.colorAttachments[0].loadAction = loadAction
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)

            renderPassDescriptor.depthAttachment = MTLRenderPassDepthAttachmentDescriptor()
            renderPassDescriptor.depthAttachment.clearDepth = 1
            renderPassDescriptor.depthAttachment.texture = self.depthStencilTexture

            let renderer = renderingElement.renderer
            renderer.currentBufferIndex = currentFameIndex
            renderer.render(renderPassDescriptor: renderPassDescriptor,
                            using: commandBuffer)

            loadAction = .load
        }

        commandBuffer.present(currentDrawable)

        commandBuffer.addCompletedHandler { [availableFramesIndecesStorage, weak self] _ in
            DispatchQueue.main.async {
                availableFramesIndecesStorage.freeFrameIndex(currentFameIndex)
                guard let self else {
                    return
                }

                if self.showFpsCount {
                    self.renderedFrameTimes.insert(Date().timeIntervalSince1970)
                }
            }
        }

        commandBuffer.commit()
#if DEBUG
        metalStack.captureScope.end()
#endif // DEBUG

        // I have to call this method to avoid errors in logs:
        // [CAMetalLayerDrawable texture] should not be called after already presenting this drawable. Get a nextDrawable instead.
        // Each CAMetalLayerDrawable can only be presented once!
        draw()
    }

    private func addDisplayLinkIfNeeded() {
        guard displayLink == nil else {
            return
        }
        let dl = CADisplayLink(target: self, selector: #selector(update))
        dl.add(to: .current, forMode: .common)
        self.displayLink = dl
    }

    private func removeDisplayLink() {
        guard let existeDisplayLink = displayLink else {
            return
        }
        existeDisplayLink.remove(from: .current, forMode: .common)
        displayLink = nil
    }

    private var fpsLabel = UILabel()

    private func addFpsLabel() {
        fpsLabel.textColor = .white
        addSubview(fpsLabel)

        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fpsLabel.leftAnchor.constraint(equalTo: leftAnchor, constant: 5),
            fpsLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
        ])
    }

    func updateFps(_ fps: Int) {
        fpsLabel.text = "\(fps)fps"
    }
}

#endif // canImport(UIKit)

final private class AvailableFramesIndecesStorage {
    /// - returns: index in 0...Int.numberOfBuffers
    /// - note: Main thread usage only
    func reserveFrameIndex() -> Int? {
        precondition(Thread.isMainThread)
        defer {
            storage.dropFirst()
        }
        return storage.first
    }

    /// - note: Main thread usage only
    func freeFrameIndex(_ index: Int) {
        precondition(Thread.isMainThread)
        storage.append(index)
    }

    private var storage: [Int] = Array(0...Int.numberOfBuffers)
}

private struct RenderedFrameTimes {
    /// - parameter date: each new date should be bigger than existed ones
    /// - note: Main thread usage only
    mutating func insert(_ date: TimeInterval) {
        precondition(Thread.isMainThread)
        storage.append(date)
    }

    /// - note: Main thread usage only
    mutating func framesCountInLastSecond() -> Int {
        precondition(Thread.isMainThread)
        guard let last = storage.last else {
            return 0
        }
        let startMesurement = last - 1

        let subSequence = storage.drop(while: { $0 < startMesurement })
        storage = Array(subSequence)
        return storage.count
    }

    private var storage: [TimeInterval] = []
}

