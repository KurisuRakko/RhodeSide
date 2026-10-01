// swift-tools-version:6.0
// Rhodeside：macOS 桌宠。命令行 `swift build -c release` 就能编；.app 由 scripts/build-app.sh 组装。
import PackageDescription

let package = Package(
    name: "Rhodeside",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑，不依赖 AppKit：几何、布局、配置（以后还有平台遮挡和行为状态机）
        .target(name: "PetCore"),
        .executableTarget(
            name: "Rhodeside",
            dependencies: ["PetCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(name: "PetCoreTests", dependencies: ["PetCore"]),
    ],
    // AppKit 回调和 WebKit 委托大多默认在主线程；用 Swift 5 语言模式，免得为严格并发检查写一堆样板
    swiftLanguageModes: [.v5]
)
