import SwiftUI
import ARKit

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var arManager = ARManager.shared
    @State private var showHeightPrompt: Bool = false
    @State private var heightInput: String = ""

    var body: some View {
        ZStack {
            // --- Layer 1: AR Camera Feed ---
            ARViewContainer(arManager: arManager)
                .edgesIgnoringSafeArea(.all)

            // --- Layer 2: Detection Overlay (Bounding Boxes) ---
            DetectionOverlay(detections: arManager.currentDetections,
                             imageSize: arManager.lastImageSize,
                             screenSize: UIScreen.main.bounds.size)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(false) // Touches pass through

            // --- Layer 3: Status HUD ---
            VStack {
                // Top status bar
                HStack {
                    Circle()
                        .fill(arManager.isTracking ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(arManager.isTracking ? "Tracking" : "Initializing...")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)

                    Spacer()

                    Text("h = \(String(format: "%.2f", arManager.cameraHeight)) m")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.yellow)

                    Button(action: { showHeightPrompt = true }) {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55))

                Spacer()

                // Bottom detection count
                if !arManager.currentDetections.isEmpty {
                    Text("\(arManager.currentDetections.count) object(s) detected")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(10)
                        .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            // Check if height has been set before
            let savedHeight = UserDefaults.standard.float(forKey: "cameraHeight")
            if savedHeight > 0 {
                arManager.cameraHeight = savedHeight
                arManager.startSession()
            } else {
                showHeightPrompt = true
            }
        }
        // MARK: - Height Input Sheet
        .sheet(isPresented: $showHeightPrompt, onDismiss: {
            arManager.startSession()
        }) {
            HeightInputView(
                heightInput: $heightInput,
                isPresented: $showHeightPrompt,
                onConfirm: { h in
                    arManager.cameraHeight = h
                    UserDefaults.standard.set(h, forKey: "cameraHeight")
                }
            )
        }
    }
}

// MARK: - Height Input View
struct HeightInputView: View {
    @Binding var heightInput: String
    @Binding var isPresented: Bool
    var onConfirm: (Float) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: 52))
                .foregroundColor(.blue)

            Text("Camera Height")
                .font(.system(size: 28, weight: .bold))

            Text("Enter the height of your phone\nabove the ground in meters.\nThis is used for distance estimation.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Common preset buttons
            HStack(spacing: 12) {
                ForEach(["0.8", "1.0", "1.2", "1.5"], id: \.self) { preset in
                    Button(action: { heightInput = preset }) {
                        Text("\(preset) m")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(heightInput == preset ? Color.blue : Color(.systemGray5))
                            .foregroundColor(heightInput == preset ? .white : .primary)
                            .cornerRadius(20)
                    }
                }
            }

            TextField("e.g. 1.20", text: $heightInput)
                .keyboardType(.decimalPad)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 160)
                .font(.system(size: 18, design: .monospaced))
                .multilineTextAlignment(.center)

            Button(action: {
                let raw = heightInput.replacingOccurrences(of: ",", with: ".")
                if let h = Float(raw), h > 0.1, h < 3.0 {
                    onConfirm(h)
                    isPresented = false
                }
            }) {
                Text("Confirm")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canConfirm ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                    .padding(.horizontal, 40)
            }
            .disabled(!canConfirm)

            Spacer()
        }
        .padding()
    }

    private var canConfirm: Bool {
        let raw = heightInput.replacingOccurrences(of: ",", with: ".")
        if let h = Float(raw) { return h > 0.1 && h < 3.0 }
        return false
    }
}

// MARK: - AR View Container (same pattern as your working app)
struct ARViewContainer: UIViewRepresentable {
    var arManager: ARManager

    func makeUIView(context: Context) -> ARSCNView {
        return arManager.sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Detection Overlay
// Draws bounding boxes as a SwiftUI canvas layer on top of the AR feed.
struct DetectionOverlay: View {
    let detections: [DetectedObject]
    let imageSize: CGSize       // The pixel size of the camera image
    let screenSize: CGSize      // The screen size

    var body: some View {
        Canvas { context, size in
            for det in detections {
                let rect = projectBoundingBox(det.normalizedRect,
                                              imageSize: imageSize,
                                              screenSize: size)
                guard rect.width > 0, rect.height > 0 else { continue }

                let color = classColor(det.label)

                // Draw bounding box
                var path = Path()
                path.addRect(rect)
                context.stroke(path, with: .color(color), lineWidth: 2.5)

                // Draw filled label background
                let label = "\(det.label)  \(String(format: "%.1f", det.distanceMeters)) m"
                let fontSize: CGFloat = 13
                let padding: CGFloat = 5
                let textSize = labelTextSize(label, fontSize: fontSize)
                let labelRect = CGRect(x: rect.minX,
                                       y: max(0, rect.minY - textSize.height - padding * 2),
                                       width: textSize.width + padding * 2,
                                       height: textSize.height + padding * 2)

                var bgPath = Path()
                bgPath.addRoundedRect(in: labelRect, cornerSize: CGSize(width: 4, height: 4))
                context.fill(bgPath, with: .color(color))

                // Draw label text
                context.draw(
                    Text(label)
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white),
                    at: CGPoint(x: labelRect.minX + padding,
                                y: labelRect.minY + padding),
                    anchor: .topLeading
                )
            }
        }
    }

    // --- Map normalized VNDetectedObjectObservation rect (bottom-left origin) to screen rect ---
    private func projectBoundingBox(_ normalized: CGRect,
                                     imageSize: CGSize,
                                     screenSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        // Vision rects have origin at bottom-left; flip Y for screen (top-left origin)
        let flipped = CGRect(
            x: normalized.origin.x,
            y: 1.0 - normalized.origin.y - normalized.height,
            width: normalized.width,
            height: normalized.height
        )

        // Scale to screen
        return CGRect(
            x: flipped.origin.x * screenSize.width,
            y: flipped.origin.y * screenSize.height,
            width: flipped.width * screenSize.width,
            height: flipped.height * screenSize.height
        )
    }

    private func classColor(_ label: String) -> Color {
        // Deterministic color per class
        let colors: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .yellow, .cyan]
        let hash = abs(label.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return colors[hash % colors.count]
    }

    private func labelTextSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        return size
    }
}