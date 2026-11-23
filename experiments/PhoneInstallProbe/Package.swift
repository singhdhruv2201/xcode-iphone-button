// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneInstallProbe",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ProbeCore", targets: ["ProbeCore"])],
    targets: [
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.68/idevice-xcframework-v0.1.68.zip",
            checksum: "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
        ),
        .target(name: "ProbeCore", dependencies: [.target(name: "IDevice", condition: .when(platforms: [.iOS]))], resources: [.copy("IDevice-LICENSE.txt")], linkerSettings: [
            .linkedLibrary("c++"), .linkedLibrary("z"),
            .linkedFramework("Security"), .linkedFramework("SystemConfiguration")
        ]),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"])
    ]
)
