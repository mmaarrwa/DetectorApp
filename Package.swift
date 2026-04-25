// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DetectorApp",
    platforms: [.iOS("16.0")],
    products: [
        .executable(
            name: "DetectorApp",
            targets: ["AppModule"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources",
            resources: [
                .process("../Info.plist"),
                // The YOLOv8n CoreML model package
                // Download from: https://github.com/ultralytics/assets/releases/download/v0.0.0/yolov8n.mlpackage.zip
                // Place it at: Sources/AppModule/yolov8n.mlpackage
                .process("AppModule/yolov8n.mlpackage")
            ]
        )
    ]
)