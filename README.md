# 双摄相机（DualCamera）

一个原生 SwiftUI iPhone 相机示例：通过 `AVCaptureMultiCamSession` 同时启用前置摄像头和后置广角摄像头，为 iPhone 16 Pro 提供稳定的双摄实时预览与合成拍照。

> 不按“iPhone 17 专属功能”处理。应用会依据设备实际能力启用 MultiCam，因此 iPhone 16 Pro 只要系统允许该前后摄组合，便可直接使用。

## 功能

- 后置广角全屏预览，前置镜像画中画预览
- 一次快门同时请求前后摄照片，合成为一张画中画照片并在应用内预览
- 检查相机授权、MultiCam 支持、可并发的摄像头组合及 30fps 兼容格式
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
5. 点击快门，确认应用内预览中包含两路照片。

完整的配置、功能验收与故障排查请参阅 [使用说明](docs/使用说明.md)。

## 实现概览

`DualCameraController` 使用手动连接而非 AVCaptureSession 自动路由：

```text
后置广角 input ──┬── 后置预览层
                 └── 后置 PhotoOutput

前置 TrueDepth input ──┬── 前置预览层（镜像）
                       └── 前置 PhotoOutput（镜像）
```

启动时，应用依次验证 `AVCaptureMultiCamSession.isMultiCamSupported`、
`supportedMultiCamDeviceSets` 和每个设备的 `isMultiCamSupported` 格式，再以可持续运行的 720p+ / 30fps 格式启动会话。该流程避免在 iPhone 16 Pro 上因为错误使用虚拟后摄或高带宽格式而导致会话无法启动。

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

当前工作区已通过前两项校验和工程生成。完整 `xcodebuild` 受本机 Xcode 平台组件安装状态限制（命令行提示“iOS 26.5 is not installed”）而未能执行到编译阶段；安装对应 iOS 平台组件后即可运行上述命令。真机验收仍应覆盖两个预览、连续快门、锁屏/切后台恢复和高温/系统中断提示。

## 隐私

本应用仅请求相机权限，用于实时预览和应用内合成照片。当前版本不会将照片自动写入系统相册，也不会上传、分析或传输相机数据。

## 项目结构

```text
DualCamera/
├── ContentView.swift             # SwiftUI 交互界面
├── DualCameraController.swift    # MultiCam 会话、拍照、状态管理
├── DualCameraPreview.swift       # 双预览层布局
└── Info.plist                    # 相机权限说明
docs/使用说明.md                    # 配置和真机验收手册
```
