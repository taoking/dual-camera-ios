# 双摄相机（DualCamera）

面向 iPhone 16 Pro 等支持 `AVCaptureMultiCamSession` 的设备的原生 SwiftUI 双摄相机。它同时请求前后摄照片，将两路图像按同一布局规则合成为照片；并保留已有的视频录制能力。

> 双路照片是“近同步”采集：两个 `AVCapturePhotoOutput` 在同一个事务中并发请求，但 iOS 不提供严格同一时刻曝光的公开 API。

## 当前能力

- 前后摄实时预览、后置超广角／广角／长焦动态筛选
- 画中画、左右分屏、上下分屏；预览与成片共用布局引擎
- 画中画拖动、角落吸附、小／中／大尺寸与布局持久化
- 合成照片预览、系统分享、仅保存成片或同时保存前后摄原图
- 后摄点击对焦／测光、双指缩放、九宫格、3／5／10 秒倒计时、快门触感反馈
- 前摄预览镜像与成片镜像可分别设置
- 拍照事务 ID、4 秒超时、会话中断／媒体服务重置恢复及硬件成本诊断
- 已有的前后摄画中画视频录制、预览与保存（本轮未扩展其规格）

## 要求与运行

| 项目 | 要求 |
| --- | --- |
| 最低系统 | iOS 17.0 |
| 真机 | 支持 `AVCaptureMultiCamSession` 的 iPhone；以 iPhone 16 Pro 为目标机型 |
| Xcode | Xcode 15 或更高版本 |
| 模拟器 | 可运行 Fake Camera Mode 与单元测试；不能验证真实双摄硬件 |

1. 用 Xcode 打开 `DualCamera.xcodeproj`。
2. 选择 **DualCamera target → Signing & Capabilities**，填入自己的 Development Team 和唯一 Bundle Identifier。
3. 连接 iPhone，选择设备并 Run；首次按需允许相机、麦克风和“添加照片”权限。
4. 使用顶部菜单选择镜头、布局、比例及设置；点击白色快门进入合成照片预览。

工程不包含个人 Team ID，默认 Bundle Identifier 为 `com.yourcompany.dualcamera`，安装前必须由开发者配置。

## 验证命令

```sh
xcodegen generate
xcodebuild test -project DualCamera.xcodeproj -scheme DualCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project DualCamera.xcodeproj -scheme DualCamera \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

在 Scheme 的 Run Arguments 加入 `-fakeCamera`，可在没有真实双摄硬件的环境中检查布局、快门和照片预览流程。完整真机结果以 [真机验收清单](docs/真机验收.md) 为准。

## 文档

- [使用说明](docs/使用说明.md)：日常操作、权限与故障排查
- [架构说明](docs/architecture.md)：职责、并发、布局与恢复策略
- [真机验收](docs/真机验收.md)：iPhone 16 Pro 的待执行检查项
- [路线图](docs/roadmap.md)：范围边界与后续方向
- [变更记录](CHANGELOG.md)
- [iOS 应用开发、打包与发布全流程指南](docs/iOS应用开发、打包与发布全流程指南.md)

## 隐私

相机用于本地预览与拍照；麦克风仅用于已有的视频录音；“添加照片”权限仅在用户明确点击保存时使用。应用不自动写入相册，也不上传或分析相机内容。

## 已知限制

- 不支持 MultiCam 的设备会显示不支持状态，不会降级为伪双摄。
- 系统会依据并发组合、温度、通话或其他占用动态限制后置镜头；菜单只显示当前系统确认可用的组合。
- 画中画位置与比例可持久化，但不同设备和系统版本的真实取景裁切仍须按验收清单确认。
- 目前没有新增视频布局、视频倒计时或直播能力；视频功能保留为实验性已有能力。
