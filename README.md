# 双摄相机（DualCamera）

面向 iPhone 16 Pro 等支持 `AVCaptureMultiCamSession` 的设备的原生 SwiftUI 双摄相机。它同时请求前后摄照片，将两路图像按同一布局规则合成为照片；并保留已有的视频录制能力。

> 双路照片和视频都是“近同步”采集：应用对两路结果做配对／时间邻近合成，但 iOS 不提供严格同一时刻曝光或逐帧硬件同步的公开保证。

## 当前能力

- 前后摄实时预览、后置超广角／广角／长焦动态筛选
- 画中画、左右分屏、上下分屏；预览与成片共用布局引擎
- 画中画拖动、角落吸附、小／中／大尺寸与布局持久化
- 合成照片预览、系统分享、仅保存成片或同时保存相机返回的前后摄原始文件数据
- 后摄点击对焦／测光、双指缩放、九宫格、3／5／10 秒倒计时、快门触感反馈
- 前摄预览镜像与成片镜像可分别设置
- 快速／均衡质量的安全上限配置、拍照事务 ID、4 秒超时和非致命错误恢复
- 30／24fps 格式候选、`hardwareCost`／`systemPressureCost` 自动降级与运行期压力保护
- 前后摄画中画视频录制、录音、预览、add-only 保存和临时文件清理
- ScenePhase、权限回调、系统中断／媒体服务重置的幂等恢复

## 要求与运行

| 项目 | 要求 |
| --- | --- |
| 最低系统 | iOS 17.0 |
| 真机 | 支持 `AVCaptureMultiCamSession` 的 iPhone；以 iPhone 16 Pro 为目标机型 |
| Xcode | Xcode 15 或更高版本；本地验收使用 Xcode 26.6 / iOS 26.5 SDK |
| 模拟器 | 可运行 Fake Camera Mode 与单元测试；不能验证真实双摄硬件 |

1. 用 Xcode 打开 `DualCamera.xcodeproj`。
2. 选择 **DualCamera target → Signing & Capabilities**，填入自己的 Development Team 和唯一 Bundle Identifier。
3. 连接 iPhone，选择设备并 Run；首次按需允许相机、麦克风和“添加照片”权限。
4. 使用顶部菜单选择镜头、布局、比例及设置；点击白色快门拍照，点击红点开始视频录制。

工程不包含个人 Team ID，默认 Bundle Identifier 为 `com.yourcompany.dualcamera`，安装前必须由开发者配置。

## 验证命令

```sh
xcodegen generate
xcodebuild test -project DualCamera.xcodeproj -scheme DualCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:DualCameraTests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DualCamera.xcodeproj -scheme DualCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:DualCameraUITests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project DualCamera.xcodeproj -scheme DualCamera \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

单元测试不访问真实摄像头；UI 测试用 `-fakeCamera` 覆盖布局、比例、倒计时、预览、受控分享、保存失败和视频按钮状态。`.github/workflows/ios.yml` 会在 Runner 上动态选择可用 iPhone 模拟器；工作流已配置，但只有远端实际运行后才能宣称 CI 通过。完整硬件结果以 [真机验收清单](docs/真机验收.md) 为准。

## 文档

- [使用说明](docs/使用说明.md)：日常操作、权限与故障排查
- [架构说明](docs/architecture.md)：职责、并发、布局与恢复策略
- [真机验收](docs/真机验收.md)：iPhone 16 Pro 的待执行检查项
- [路线图](docs/roadmap.md)：范围边界与后续方向
- [执行日志](docs/执行日志.md)：主要构建、测试、发布与真机安装结果
- [变更记录](CHANGELOG.md)
- [iOS 应用开发、打包与发布全流程指南](docs/iOS应用开发、打包与发布全流程指南.md)

## 隐私

相机用于本地预览与拍照；麦克风仅用于已有的视频录音；“添加照片”权限仅在用户明确点击保存时使用。应用不自动写入相册，也不上传或分析相机内容。

## 已知限制

- 不支持 MultiCam 的设备会显示不支持状态，不会降级为伪双摄。
- 系统会依据并发组合、温度、通话或其他占用动态限制后置镜头；菜单只显示当前系统确认可用的组合。
- 画中画位置与比例可持久化，但不同设备和系统版本的真实取景裁切仍须按验收清单确认。
- 视频沿用固定画中画、720×1280 H.264 成片；本轮没有新增视频布局、画幅、暂停继续、4K、ProRes、滤镜或直播。
- 格式成本和系统压力保护已经自动执行，但不同 iPhone 16 Pro 系统版本上的实际候选、降级次数和热行为仍须真机日志确认。
