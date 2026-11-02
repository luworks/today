// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TodayModules",
  platforms: [.macOS(.v14), .iOS("27.0")],
  products: [
    .executable(name: "today-scenes", targets: ["TodaySceneInventory"]),
    .library(name: "TodayCore", targets: ["TodayCore"]),
    .library(name: "TodayShared", targets: ["TodayShared"]),
    .library(name: "TodayData", targets: ["TodayData"]),
    .library(name: "TodayPlatform", targets: ["TodayPlatform"]),
    .library(name: "TodayDesignSystem", targets: ["TodayDesignSystem"]),
    .library(name: "FeatureClock", targets: ["FeatureClock"]),
    .library(name: "FeatureHealth", targets: ["FeatureHealth"]),
    .library(name: "TodayTestSupport", targets: ["TodayTestSupport"]),
    .library(name: "One", targets: ["One"]),
    .library(name: "TodayPlannerUI", targets: ["TodayPlannerUI"]),
    .library(name: "FeatureToday", targets: ["FeatureToday"]),
    .library(name: "FeatureCalendar", targets: ["FeatureCalendar"]),
    .library(name: "FeatureReminders", targets: ["FeatureReminders"]),
    .library(name: "FeatureAsk", targets: ["FeatureAsk"]),
    .library(name: "FeatureSettings", targets: ["FeatureSettings"]),
    .library(name: "FeatureActivity", targets: ["FeatureActivity"]),
    .library(name: "FeatureSearch", targets: ["FeatureSearch"]),
    .library(name: "TodayShell", targets: ["TodayShell"]),
    .library(name: "TodayScenes", targets: ["TodayScenes"]),
  ],
  targets: [
    .executableTarget(name: "TodaySceneInventory", dependencies: ["TodayScenes"]),
    .target(name: "TodayCore"),
    .target(name: "TodayShared"),
    .target(
      name: "TodayData", dependencies: ["TodayCore", "TodayShared"],
      linkerSettings: [.linkedLibrary("sqlite3")]),
    .target(name: "TodayPlatform", dependencies: ["TodayCore", "TodayShared"]),
    .target(name: "TodayDesignSystem", dependencies: ["TodayCore"]),
    .target(name: "One", dependencies: ["TodayCore", "TodayShared", "TodayData", "TodayPlatform"]),
    .target(
      name: "TodayPlannerUI",
      dependencies: ["One", "TodayCore", "TodayDesignSystem", "TodayPlatform"]),
    .target(
      name: "FeatureClock",
      dependencies: ["One", "TodayCore", "TodayDesignSystem", "TodayPlatform"],
      path: "Sources/Features/FeatureClock", exclude: ["README.md"]),
    .target(
      name: "FeatureHealth", dependencies: ["TodayCore", "TodayDesignSystem", "TodayPlatform"],
      path: "Sources/Features/FeatureHealth"),
    .target(
      name: "TodayTestSupport",
      dependencies: ["TodayCore", "TodayShared", "TodayData", "TodayPlatform", "One"]),
    .target(
      name: "FeatureToday",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
        "TodayPlannerUI", "FeatureHealth",
      ], path: "Sources/Features/FeatureToday"),
    .target(
      name: "FeatureCalendar",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
        "TodayPlannerUI",
      ], path: "Sources/Features/FeatureCalendar"),
    .target(
      name: "FeatureReminders",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
        "TodayPlannerUI",
      ], path: "Sources/Features/FeatureReminders"),
    .target(
      name: "FeatureAsk",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
      ], path: "Sources/Features/FeatureAsk"),
    .target(
      name: "FeatureSettings",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
        "FeatureHealth",
      ], path: "Sources/Features/FeatureSettings"),
    .target(
      name: "FeatureActivity",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
      ], path: "Sources/Features/FeatureActivity"),
    .target(
      name: "FeatureSearch",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayDesignSystem", "TodayPlatform",
      ], path: "Sources/Features/FeatureSearch"),
    .target(name: "TodayScenes"),
    .target(
      name: "TodayShell",
      dependencies: [
        "One", "TodayCore", "TodayShared", "TodayData", "TodayPlatform", "TodayDesignSystem",
        "TodayPlannerUI", "FeatureToday", "FeatureCalendar", "FeatureReminders", "FeatureAsk",
        "FeatureSettings", "FeatureActivity", "FeatureSearch", "FeatureClock", "FeatureHealth",
      ]),
    .testTarget(
      name: "SceneRegistryTests", dependencies: ["TodayScenes"], path: "SceneRegistryTests"),
    .testTarget(
      name: "TodayTests",
      dependencies: ["TodayCore", "TodayShared", "TodayData", "TodayTestSupport"],
      path: "Eval/Tests/OneLogicTests",
      resources: [.copy("capture-cases.json")]),
  ],
  swiftLanguageModes: [.v6]
)
