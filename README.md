# 双摄相机（DualCamera）

面向 iPhone 16 Pro 等支持 `AVCaptureMultiCamSession` 的设备的原生 SwiftUI 双摄相机。它同时请求前后摄照片，将两路图像按同一布局规则合成为照片；并保留已有的视频录制能力。

> 双路照片和视频都是“近同步”采集：应用对两路结果做配对／时间邻近合成，但 iOS 不提供严格同一时刻曝光或逐帧硬件同步的公开保证。

## 当前能力

- 前后摄实时预览、后置超广角／广角／长焦动态筛选
- 画中画、左右分屏、上下分屏；预览与成片共用布局引擎
- 画中画拖动、角落吸附、小／中／大尺寸与布局持久化
- 照片合成后自动在独立队列保存，实时取景不停止；可选仅保存成片或同时保存相机返回的前后摄原始文件数据
- 最近照片／视频缩略图入口；按实际拍摄顺序保持最新媒体，用户主动打开后可查看，照片可分享，保存失败可重试
- 同一媒体的保存互斥保持到 PhotoKit 真实回调；较早媒体失败也会显示带“重试保存”的提示条，不会被新缩略图静默掩盖
- 带操作的错误提示在用户处理前不会被较低优先级提示覆盖；点击时按该条提示的唯一 ID 消费，旧按钮不会清除后来出现的新提示
- 未成功保存的照片任务在当前进程内最多保留 5 个；达到上限时先处理或重试旧任务，再继续拍照
- 底部「照片／视频」模式切换与单一主键；录制中主键即停止
- 常亮补光（手电筒），退出界面自动关闭
- 后摄点击对焦／测光、长按 AE/AF 锁定、右侧曝光补偿滑杆
- 双指缩放并显示等效焦距倍率、九宫格、3／5／10 秒倒计时（可点按取消）、快门触感反馈
- 查看页支持双指缩放、双击放大、下滑关闭
- 前摄预览镜像与成片镜像可分别设置
- 快速／均衡质量的安全上限配置、拍照事务 ID、4 秒超时和非致命错误恢复
- 30／24fps 格式候选、`hardwareCost`／`systemPressureCost` 自动降级与运行期压力保护
- 前后摄视频录制与录音，布局、画幅与预览和照片同源；准备／录制／处理状态与持续计时
- 停止录制后立即恢复照片取景，成片完成后在后台 add-only 保存，不因保存暂停 Session；写入期间的更新照片不会被旧视频回调覆盖
- 视频以 saving/saved/failed 显式状态决定缓存清理；失败 `.mov` 路径可跨 Controller 恢复，正常退出时按状态安全收尾
- failed 与 saving 视频按标准化 URL 去重后共享容量闸门；开始录像时，现有文件已达 5 个或累计 1 GiB 会阻止新录像并要求重试保存，不静默删除待恢复文件
- ScenePhase、权限回调、系统中断／媒体服务重置的幂等恢复；旧 writer 正在 `finishWriting` 时保持处理中闸门直到回调

## 要求与运行

| 项目 | 要求 |
| --- | --- |
| 最低系统 | iOS 17.0 |
| 真机 | 支持 `AVCaptureMultiCamSession` 的 iPhone；以 iPhone 16 Pro 为目标机型 |
| Xcode | Xcode 15 或更高版本；本地验收使用 Xcode 26.6 / iOS 26.5 SDK |
| 模拟器 | 可运行 Fake Camera Mode 与单元测试；不能验证真实双摄硬件 |

1. 用 Xcode 打开 `DualCamera.xcodeproj`。
2. 选择 **DualCamera target → Signing & Capabilities**，填入自己的 Development Team 和唯一 Bundle Identifier。
3. 连接 iPhone，选择设备并 Run；首次按需允许相机和麦克风权限。第一次拍照或录制完成、应用开始自动保存时，再允许“添加照片”权限。
4. 使用顶部菜单选择镜头、布局、比例及设置；点击白色快门拍照，点击红点开始视频录制，录制中点击中央按键停止。
5. 拍摄后取景保持可用；点击左下角最近媒体缩略图，可主动查看保存状态、分享照片或重试失败的保存。

工程不包含个人 Team ID，默认 Bundle Identifier 为 `com.yourcompany.dualcamera`，安装前必须由开发者配置。

## App Icon

图标由 `DesignAssets/make-app-icon.swift` 生成，不是一张不可复现的位图：

```sh
swift DesignAssets/make-app-icon.swift DualCamera/Assets.xcassets/AppIcon.appiconset
```

图形语义是一个光圈环加右下角的画中画角标，对应应用的实际输出。脚本输出常规、
深色、单色三份 1024，由 Xcode 自动派生全部尺寸；后两份背景透明，由系统合成。

## 安装到自己的 iPhone

连上手机并保持解锁，然后：

```sh
./scripts/install-to-device.sh
```

自动完成选 Xcode、找设备、签名、覆盖安装与启动。个人开发签名约 7 天到期，
到期后重跑同一条命令即可，不需要删除应用或重新配置。详见
[开发签名续期与真机更新手册](docs/开发签名续期与真机更新手册.md)。

## 验证命令

```sh
xcodegen generate
xcodebuild test -project DualCamera.xcodeproj -scheme DualCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -only-testing:DualCameraTests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DualCamera.xcodeproj -scheme DualCamera \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' \
  -only-testing:DualCameraUITests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project DualCamera.xcodeproj -scheme DualCamera \
  -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

单元测试不访问真实摄像头；UI 测试用 `-fakeCamera` 覆盖布局、比例、倒计时、静默后台保存、最近媒体查看、保存失败重试，以及录制状态与时长。`.github/workflows/ios.yml` 会在 Runner 上动态选择可用 iPhone 模拟器；工作流已配置，但只有远端实际运行后才能宣称 CI 通过。完整硬件结果以 [真机验收清单](docs/真机验收.md) 为准。

## 文档

- [使用说明](docs/使用说明.md)：日常操作、权限与故障排查
- [架构说明](docs/architecture.md)：职责、并发、布局与恢复策略
- [真机验收](docs/真机验收.md)：iPhone 16 Pro 的待执行检查项
- [路线图](docs/roadmap.md)：范围边界与后续方向
- [执行日志](docs/执行日志.md)：主要构建、测试、发布与真机安装结果
- [变更记录](CHANGELOG.md)
- [iOS 应用开发、打包与发布全流程指南](docs/iOS应用开发、打包与发布全流程指南.md)
- [开发签名续期与真机更新手册](docs/开发签名续期与真机更新手册.md)：7 天到期后的构建、覆盖安装、信任与排障

## 隐私

相机用于本地实时预览与拍照；麦克风仅用于视频录音。“添加照片”仅授予 add-only 权限，首次拍照或录制完成、应用开始自动保存时才请求。所有图像、声音和保存处理都在设备本地完成，应用不上传或分析拍摄内容。

## 已知限制

- 不支持 MultiCam 的设备会显示不支持状态，不会降级为伪双摄。
- 系统会依据并发组合、温度、通话或其他占用动态限制后置镜头；菜单只显示当前系统确认可用的组合。
- 画中画位置与比例可持久化，但不同设备和系统版本的真实取景裁切仍须按验收清单确认。
- 视频成片长边 1920（9:16 为 1080×1920，3:4 为 1440×1920，1:1 为 1920×1920）、HEVC 编码；本轮没有新增暂停继续、4K、ProRes、滤镜或直播。
- 失败照片的可重试操作只在当前应用进程内保留；失败视频只在对应缓存 `.mov` 仍存在时可恢复。
- 格式成本和系统压力保护已经自动执行，但不同 iPhone 16 Pro 系统版本上的实际候选、降级次数和热行为仍须真机日志确认。
