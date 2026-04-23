import Foundation
import ARKit
import SceneKit
import simd
import SwiftUI

final class ARManager: NSObject, ObservableObject, ARSessionDelegate {
    static let shared = ARManager()

    // MARK: - Published State
    @Published var isTracking: Bool = false
    @Published var currentDetections: [DetectedObject] = []
    @Published var lastImageSize: CGSize = CGSize(width: 1920, height: 1440)
    @Published var cameraHeight: Float = 1.2   // Default 1.2m; overwritten by user input

    // MARK: - AR Scene View (same pattern as working app)
    let sceneView: ARSCNView = {
        let v = ARSCNView(frame: .zero)
        //lights the virtual3d objects so for saving the battery i will keep it
        //false till i choose to put 3d objects in the scene like at a manhole or someting (just if)
        v.autoenablesDefaultLighting = false
        // Show feature points so user can see tracking quality
        v.debugOptions = [ARSCNDebugOptions.showFeaturePoints]
        //force to redraw every frame ->maybe will end up heating the phone
        v.rendersContinuously = false
        return v
    }()

    // MARK: - Frame Throttle
    // Vision inference is expensive — run every N frames to stay real-time
    private var frameCount: Int = 0
    private let inferenceInterval: Int = 3   // Run detection every 3 frames (~20 FPS on 60FPS feed)

    // MARK: - Detection smoothing
    // Simple temporal smoothing: keep last N frames of detections and merge by IOU
    private var detectionHistory: [[DetectedObject]] = []
    private let historyLength = 2

    override init() {
        super.init()
        // Wire up detection results
        DetectionManager.shared.onDetections = { [weak self] detections, imageSize in
            guard let self = self else { return }
            self.lastImageSize = imageSize
            self.currentDetections = self.smoothDetections(detections)
        }
    }

    // MARK: - Session Management
    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            print("❌ ARKit not supported on this device")
            return
        }
        let config = ARWorldTrackingConfiguration()
        // Gravity alignment gives us a Y-up world frame — critical for ground plane math
        config.worldAlignment = .gravity

        // Enable plane detection to help ARKit understand the ground
        config.planeDetection = [.horizontal]

        // Enable scene reconstruction on LiDAR devices (bonus accuracy)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            print("🟢 LiDAR mesh reconstruction enabled")
        } else {
            print("🟡 Standard VIO mode (no LiDAR)")
        }

        sceneView.session.delegate = self
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        print("✅ ARKit session started | Camera height: \(cameraHeight)m")
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Track quality
        DispatchQueue.main.async {
            self.isTracking = frame.camera.trackingState == .normal
        }

        // Throttle inference
        frameCount += 1
        guard frameCount % inferenceInterval == 0 else { return }

        // Run detection on background queue (Vision is thread-safe)
        let height = cameraHeight
        DispatchQueue.global(qos: .userInitiated).async {
            DetectionManager.shared.processFrame(frame, cameraHeight: height)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARSession failed: \(error)")
        DispatchQueue.main.async { self.isTracking = false }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.isTracking = false }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        startSession()
    }

    // MARK: - Detection Smoothing
    // Reduces jitter by averaging detections across frames.
    // Strategy: keep the latest frame's detections but smooth distance
    // values using recent history for matching labels.
    private func smoothDetections(_ newDetections: [DetectedObject]) -> [DetectedObject] {
        detectionHistory.append(newDetections)
        if detectionHistory.count > historyLength {
            detectionHistory.removeFirst()
        }

        // For each detection in the latest frame, average its distance
        // with any matching-label detection in previous frames
        return newDetections.map { det in
            var distances: [Float] = [det.distanceMeters]
            for pastFrame in detectionHistory.dropLast() {
                if let match = pastFrame.first(where: {
                    $0.label == det.label && iouOverlap($0.normalizedRect, det.normalizedRect) > 0.3
                }) {
                    distances.append(match.distanceMeters)
                }
            }
            let avgDist = distances.reduce(0, +) / Float(distances.count)
            return DetectedObject(
                label: det.label,
                confidence: det.confidence,
                normalizedRect: det.normalizedRect,
                distanceMeters: avgDist
            )
        }
    }

    // Intersection-over-Union for two CGRects (normalized coords)
    private func iouOverlap(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = Float(intersection.width * intersection.height)
        let unionArea = Float(a.width * a.height + b.width * b.height) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}