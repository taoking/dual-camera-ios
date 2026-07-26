# 双摄相机（DualCamera）

一个原生 SwiftUI iPhone 相机示例：通过 `AVCaptureMultiCamSession` 同时启用前置摄像头和后置摄像头，为 iPhone 16 Pro 提供双摄实时预览、画中画拍照与视频录制。

> 不按“iPhone 17 专属功能”处理。应用会依据设备实际能力启用 MultiCam，因此 iPhone 16 Pro 只要系统允许该前后摄组合，便可直接使用。

## 功能

- 原创双镜头 App Icon，已接入 iOS Asset Catalog
- 后置全屏预览，前置镜像画中画预览
- 后置超广角／广角／长焦选择；仅显示系统确认可与前摄并发的镜头
- 一次快门同时请求前后摄照片，合成为一张画中画照片；保存成功后自动返回实时预览并提示
- 前后摄画中画视频录制、麦克风录音、视频预览与手动保存到系统相册；保存成功后自动继续拍摄
- 检查相机／麦克风授权、MultiCam 支持、可并发的摄像头组合及 30fps 兼容格式
- 显示系统中断、媒体服务重置等运行时问题，不会伪装成单摄模式

## 系统要求

| 项目 | 要求 |
| --- | --- |
| Xcode | Xcode 15 或更高版本 |
| 最低系统 | iOS 17.0 |
| 验证设备 | iPhone 16 Pro（或其他 `AVCaptureMultiCamSession` 支持设备） |
| 模拟器 | 可编译界面，但不能验证双摄硬件 |

## 快速开始

1. 克隆仓库并用 Xcode 打开 `DualCamera.xcodeproj`。
2. 在 **Signing & Capabilities** 为 `DualCamera` 选择自己的 Development Team 和唯一的 Bundle Identifier。
3. 选择已连接的 iPhone 16 Pro，点击 Run。
4. 首次启动时授予相机权限。后置画面应填满屏幕，前置画面应出现在右下角。
5. 在顶部菜单选择可用的后置镜头；不可与前摄同时运行的镜头不会显示。
6. 点击白色快门，确认应用内预览中包含两路照片；点击“保存并继续拍摄”写入系统相册后，应用自动回到双摄预览。
7. 点击右侧红点开始视频录制。首次录制时授予麦克风权限；点击中央停止键后可预览并保存视频。

完整的配置、功能验收与故障排查请参阅 [使用说明](docs/使用说明.md)。

从 Apple 账号申请、项目签名、真机安装、IPA 打包、TestFlight 到 App Store 发布，请参阅 [iOS 应用开发、打包与发布全流程指南](docs/iOS应用开发、打包与发布全流程指南.md)。

## 实现概览

`DualCameraController` 使用手动连接而非 AVCaptureSession 自动路由，并按拍照／视频模式切换输出，控制 MultiCam 硬件带宽：

```text
后置广角 input ──┬── 后置预览层
                 └── 后置 PhotoOutput

前置 TrueDepth input ──┬── 前置预览层（镜像）
                       └── 前置 PhotoOutput（镜像）

视频模式：

后置 VideoDataOutput ─┐
前置 VideoDataOutput ─┼── Core Image 画中画合成 ── AVAssetWriter（H.264）
麦克风 AudioDataOutput ─┘                              └── AAC 音频
```

启动时，应用依次验证 `AVCaptureMultiCamSession.isMultiCamSupported`、
`supportedMultiCamDeviceSets` 和每个设备的 `isMultiCamSupported` 格式，再以可持续运行的 720p+ / 30fps 格式启动会话。录制时会从照片输出切换为视频／音频输出，避免同时常驻两套高带宽媒体输出。该流程避免在 iPhone 16 Pro 上因为错误使用虚拟后摄或高带宽格式而导致会话无法启动。

## 本地验证

```sh
# Swift API 与类型校验
xcrun swiftc -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -target arm64-apple-ios17.0 -typecheck DualCamera/*.swift

# 权限和应用配置校验
plutil -lint DualCamera/Info.plist

# 生成 Xcode 工程（已安装 XcodeGen 时）
xcodegen generate

# 完整设备 SDK 构建
xcodebuild -project DualCamera.xcodeproj -scheme DualCamera \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

本工作区已通过 Swift 类型检查、`Info.plist` 校验、工程生成和 iPhoneOS 设备 SDK 完整构建。为解决初始的 Xcode 平台组件缺失，已安装 iOS 26.5 Simulator（arm64）；随后以上 iPhoneOS 构建命令获得 `BUILD SUCCEEDED`。真机验收仍应覆盖两个预览、连续快门、锁屏/切后台恢复和高温/系统中断提示。

## 隐私

本应用请求相机权限用于双摄预览与拍照，麦克风权限用于视频录音，“添加照片”权限仅在你点击保存照片或视频时使用。应用不会自动写入相册，也不会上传、分析或传输相机数据。

## 项目结构

```text
DualCamera/
├── ContentView.swift             # SwiftUI 交互界面
├── DualCameraController.swift    # MultiCam 会话、拍照/录像模式、状态与保存
├── DualCameraPreview.swift       # 双预览层布局
├── DualCameraVideoRecorder.swift # 画中画视频合成、H.264/AAC 写入
├── Assets.xcassets               # App Icon 资源集
└── Info.plist                    # 相机、麦克风、相册权限说明
docs/使用说明.md                    # 配置和真机验收手册
```
