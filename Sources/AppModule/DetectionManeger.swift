import Foundation
import Vision
import CoreML
import ARKit
import simd

// MARK: - Data Model
struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let normalizedRect: CGRect   // Vision normalized rect (bottom-left origin)
    let distanceMeters: Float
}

// MARK: - Detection Manager
// Runs YOLOv8n inference via Vision and computes monocular distance
// using the ray-ground intersection method from the paper.
final class DetectionManager {
    static let shared = DetectionManager()

    // Confidence threshold — lower = more detections, more noise
    private let confidenceThreshold: Float = 0.40

    // The Vision CoreML request — lazily initialized when the model is loaded
    private var visionRequest: VNCoreMLRequest?

    // Completion handler called on the main thread with fresh detections
    var onDetections: (([DetectedObject], CGSize) -> Void)?

    private init() {
        setupModel()
    }

    // MARK: - Model Setup
    private func setupModel() {
        // The compiled model (.mlmodelc) must be bundled in the app.
        // We look for it in the main bundle — codemagic copies it during build.
        guard let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage") else {
            print("⚠️ YOLOv8n model not found in bundle. Detection will not run.")
            print("   Make sure yolov8n.mlpackage is in Sources/AppModule/ and listed in Package.swift resources.")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // Use Neural Engine when available
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: mlModel)

            visionRequest = VNCoreMLRequest(model: vnModel) { [weak self] request, error in
                if let error = error {
                    print("Vision error: \(error)")
                    return
                }
                // Results handled in processFrame
            }
            // Scale to fill — matches how ARKit frames are cropped
            visionRequest?.imageCropAndScaleOption = .scaleFill
            print("✅ YOLOv8n model loaded successfully")
        } catch {
            print("❌ Failed to load YOLOv8n model: \(error)")
        }
    }

    // MARK: - Process ARFrame
    // Call this from ARSessionDelegate.session(_:didUpdate:)
    func processFrame(_ frame: ARFrame, cameraHeight: Float) {
        guard let request = visionRequest else { return }

        let pixelBuffer = frame.capturedImage
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))

        // Get camera intrinsics and extrinsics from ARKit
        let intrinsics = frame.camera.intrinsics   // 3x3 matrix: fx, fy, cx, cy
        let cameraTransform = frame.camera.transform  // 4x4 world transform

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,  // ARKit frames are landscape-right
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("Vision perform error: \(error)")
            return
        }

        guard let results = request.results as? [VNRecognizedObjectObservation] else { return }

        var detections: [DetectedObject] = []

        for obs in results {
            guard let top = obs.labels.first, top.confidence >= confidenceThreshold else { continue }

            let bbox = obs.boundingBox  // Normalized, bottom-left origin

            // Compute distance using monocular ray-ground intersection
            let distance = computeDistance(
                boundingBox: bbox,
                imageSize: imageSize,
                intrinsics: intrinsics,
                cameraTransform: cameraTransform,
                cameraHeight: cameraHeight
            )

            let det = DetectedObject(
                label: top.identifier,
                confidence: top.confidence,
                normalizedRect: bbox,
                distanceMeters: distance
            )
            detections.append(det)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onDetections?(detections, imageSize)
        }
    }

    // MARK: - Monocular Ray-Ground Intersection Distance
    // Implements the geometric fallback from the paper:
    // bottom-center pixel → normalized image coord → camera ray →
    // world ray → intersect with Y = -h ground plane → forward distance Z
    private func computeDistance(
        boundingBox bbox: CGRect,
        imageSize: CGSize,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        cameraHeight: Float
    ) -> Float {

        // --- 1. Extract intrinsics ---
        // simd_float3x3 columns: col0=(fx,0,0), col1=(0,fy,0), col2=(cx,cy,1)
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        // --- 2. Bottom-center pixel of bounding box ---
        // Vision bbox: origin bottom-left, y up → convert to image coords (origin top-left, y down)
        // ub in [0,1] → pixel space
        let ubNorm = bbox.midX
        let vbNorm = 1.0 - bbox.minY  // bottom of box in image coords (y flipped)

        let ub = Float(ubNorm) * Float(imageSize.width)
        let vb = Float(vbNorm) * Float(imageSize.height)

        // --- 3. Normalized image coordinates ---
        let xn = (ub - cx) / fx
        let yn = (vb - cy) / fy

        // --- 4. Camera-frame ray direction (pinhole model) ---
        // ARKit camera frame: X right, Y up, Z backward (toward viewer)
        // Standard pinhole: Z forward → we negate Z to match ARKit convention
        let rayCamera = simd_float3(xn, yn, 1.0)

        // --- 5. Transform ray to world frame using ARKit rotation ---
        // cameraTransform is a 4x4 column-major matrix; upper-left 3x3 is rotation R
        let R = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let rayWorld = simd_normalize(R * rayCamera)

        // --- 6. Ray-ground intersection ---
        // ARKit world frame: Y is up (gravity-aligned, .gravity worldAlignment)
        // Ground plane: Y = -h  →  intersection when ray.y component brings us to Y = -h
        // Camera position from transform
        let camPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Ground plane Y = camPos.y - cameraHeight (absolute ground in world Y)
        let groundY = camPos.y - cameraHeight

        // Parameter t: camPos.y + t * rayWorld.y = groundY → t = (groundY - camPos.y) / rayWorld.y
        let denom = rayWorld.y
        guard abs(denom) > 1e-6 else {
            // Ray nearly horizontal — cannot intersect ground reliably
            return estimateFallbackFromBboxSize(bbox: bbox, fx: fx, cameraHeight: cameraHeight)
        }

        let t = (groundY - camPos.y) / denom

        guard t > 0.1 else {
            // Intersection behind camera — use fallback
            return estimateFallbackFromBboxSize(bbox: bbox, fx: fx, cameraHeight: cameraHeight)
        }

        // Intersection point in world frame
        let intersect = camPos + t * rayWorld

        // --- 7. Forward distance (Euclidean on XZ plane from camera) ---
        let dx = intersect.x - camPos.x
        let dz = intersect.z - camPos.z
        let distance = sqrt(dx * dx + dz * dz)

        // Clamp to sane range [0.3m, 20m]
        return max(0.3, min(20.0, distance))
    }

    // MARK: - Fallback: angular size heuristic when ray-ground fails
    // Uses apparent width + known average object height as crude estimate
    private func estimateFallbackFromBboxSize(bbox: CGRect, fx: Float, cameraHeight: Float) -> Float {
        // Use camera height as a proxy for scene scale
        // This is rough but better than returning 0
        let bboxHeightFraction = Float(bbox.height)
        guard bboxHeightFraction > 0.01 else { return 5.0 }
        // Assume average obstacle height ~ cameraHeight (heuristic)
        let estimatedDist = cameraHeight / (bboxHeightFraction * (fx / 500.0))
        return max(0.3, min(20.0, estimatedDist))
    }
}