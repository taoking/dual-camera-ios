你正在继续开发仓库：

https://github.com/taoking/dual-camera-ios

当前开发分支：

```text
codex/media-ui-optimization
```

当前 Draft PR：

```text
PR #1 Improve dual-camera photo workflow and reliability
```

项目已经实现：

- 前后摄实时预览。
- 前后摄近同步拍照。
- 画中画、左右分屏、上下分屏。
- 画中画拖动、吸附和尺寸切换。
- 3:4、1:1、9:16 输出画幅。
- 照片合成、保存和分享。
- 后摄镜头切换、对焦、测光和缩放。
- 网格、倒计时、镜像、质量和保存模式设置。
- 前后摄画中画视频录制、录音、预览和保存。
- Fake Camera Mode。
- 基础布局与照片合成单元测试。

视频功能需要保留，不要删除、隐藏或拆到其他分支。

本轮不要继续增加新的产品功能，重点修复现有实现中的问题，收敛代码结构，完善自动测试和真机验收准备。

# 一、本轮目标

本轮必须完成：

1. 修复拍照质量模式没有真正生效的问题。
2. 完善 MultiCam 硬件成本与系统压力处理。
3. 进一步拆分过大的 `MultiCamSessionController`。
4. 修复生命周期、权限和异步启动竞态。
5. 修复对焦、曝光与缩放能力检查。
6. 优化画中画拖动过程中的状态更新和持久化。
7. 修正“前后原图”的保存定义。
8. 类型化错误和用户操作，不依赖中文文案判断状态。
9. 补充拍照事务、生命周期、保存和 Fake Camera 测试。
10. 增加可重复执行的 CI 或本地验证流程。
11. 保留并验证现有双摄视频功能。
12. 更新 PR 描述、文档和真机验收清单。

不要重新创建项目，不要重写已经稳定的布局和照片合成逻辑。

# 二、开始前检查

先完整阅读当前分支代码，重点检查：

```text
DualCamera/Camera/CameraModels.swift
DualCamera/Camera/CameraViewModel.swift
DualCamera/Camera/MultiCamSessionController.swift
DualCamera/Camera/DualCameraVideoRecorder.swift
DualCamera/Composition/DualCameraLayoutEngine.swift
DualCamera/Composition/PhotoComposer.swift
DualCamera/Services/PhotoLibraryService.swift
DualCamera/Services/CameraPreferences.swift
DualCamera/Views/DualCameraPreview.swift
DualCamera/Views/CameraControlsView.swift
DualCamera/ContentView.swift
DualCameraTests/
README.md
docs/
project.yml
```

开始修改前，简要输出：

1. 当前问题确认。
2. 本轮文件拆分方案。
3. 实施顺序。
4. 可能影响照片或视频的风险点。

随后直接修改代码，不要只生成计划。

# 三、修复拍照质量模式

当前界面提供：

- 快速模式。
- 均衡模式。

但需要确认 `AVCapturePhotoOutput.maxPhotoQualityPrioritization` 是否在 Session 启动前正确设置。

要求：

1. 在创建并配置前后摄 `AVCapturePhotoOutput` 时设置最高允许质量。
2. 快速模式请求 `.speed`。
3. 均衡模式请求 `.balanced`。
4. 请求值不得超过对应输出的 `maxPhotoQualityPrioritization`。
5. 不允许因为请求过高质量触发 Objective-C 异常或崩溃。
6. 质量设置变化时，如果需要重建 Session，应明确执行受控重建。
7. 不要在 Session 运行过程中直接修改需要重新配置的输出属性。
8. 照片与视频模式切换后，质量配置仍需正确恢复。

建议实现统一方法：

```swift
private func configurePhotoQuality(
    for output: AVCapturePhotoOutput,
    quality: CaptureQuality
)
```

并增加测试或可验证日志：

```text
后摄 max quality
前摄 max quality
本次请求 quality
```

日志不得输出照片内容。

# 四、硬件成本与系统压力处理

当前不能只展示：

```swift
session.hardwareCost
session.systemPressureCost
```

需要增加真正的格式候选和降级逻辑。

## 1. 格式候选模型

建立类似：

```swift
struct CameraFormatCandidate {
    let format: AVCaptureDevice.Format
    let frameRate: Double
    let dimensions: CMVideoDimensions
    let score: Int64
}
```

格式评分至少考虑：

- `isMultiCamSupported`
- 是否支持目标帧率。
- 分辨率距离目标值。
- 是否为过高分辨率。
- 是否支持视频录制需要的像素格式。
- 是否存在裁切或低成本格式。
- 30fps 优先，必要时降到 24fps。
- 照片模式和视频模式可能有不同优先级。

## 2. 降级顺序

推荐顺序：

```text
30fps、接近 720p
30fps、低于 720p
24fps、接近 720p
24fps、低于 720p
```

在配置前后摄组合后检查：

```swift
hardwareCost <= 1
systemPressureCost <= 1
```

如果成本过高：

1. 尝试下一组候选格式。
2. 降低帧率。
3. 降低分辨率。
4. 仍无法稳定运行时返回明确错误。

不要无限重试。

需要记录每次候选尝试：

```text
后摄格式
前摄格式
帧率
hardwareCost
systemPressureCost
是否接受
失败原因
```

## 3. 运行时压力

增加对系统压力变化的监听或处理。

至少区分：

- nominal
- fair
- serious
- critical
- shutdown

策略可以是：

- nominal / fair：正常运行。
- serious：提示用户并降低非必要负载。
- critical：停止视频录制或禁止开始新录制。
- shutdown：安全停止会话并提示设备温度或系统压力过高。

不要在压力回调中同时触发多个 Session 重建。

# 五、继续拆分 MultiCamSessionController

当前 `MultiCamSessionController` 仍然过大，需要继续拆分，但不能为了拆文件而制造复杂抽象。

建议结构：

```text
DualCamera/Camera/
├── MultiCamSessionController.swift
├── CameraAuthorizationService.swift
├── CameraCapabilityService.swift
├── CameraFormatSelector.swift
├── CameraSessionConfigurator.swift
├── PhotoCaptureCoordinator.swift
├── VideoCaptureCoordinator.swift
├── CaptureTransactionManager.swift
├── CameraLifecycleCoordinator.swift
├── CameraDiagnosticsProvider.swift
└── PhotoCaptureProcessor.swift
```

可以根据实际情况合并部分模块。

## MultiCamSessionController 最终职责

保留：

- 持有 `AVCaptureMultiCamSession`。
- 协调照片模式与视频模式。
- 调用配置器建立 Session。
- 控制启动、停止、重建。
- 向上层发布 Session 状态。
- 调度各个 Coordinator。

不再直接负责：

- PhotoKit 保存实现。
- UserDefaults 写入。
- Fake 图片绘制细节。
- 所有拍照事务细节。
- 所有视频写入细节。
- 用户提示文案拼装。
- 权限提示是否跳设置的判断。

## PhotoCaptureCoordinator

负责：

- 前后摄 `AVCapturePhotoOutput`。
- 创建拍照事务。
- 双路回调聚合。
- 4 秒超时。
- 取消与过期回调处理。
- 返回前后摄原始数据和预览图片。
- 不直接负责相册保存。

## VideoCaptureCoordinator

负责：

- 视频输出和音频输出。
- `DualCameraVideoRecorder` 生命周期。
- 开始、停止和取消录制。
- 视频结果 URL。
- 录制异常。
- 临时视频文件清理。

保留视频功能，但把视频逻辑从 Session Controller 中分离。

## CameraFormatSelector

负责：

- 前后摄组合筛选。
- 格式候选生成。
- 评分。
- 30fps / 24fps 降级。
- 照片和视频模式差异。
- 输出可测试的纯逻辑结果。

# 六、生命周期和权限竞态

当前不能把 `.inactive` 与 `.background` 完全等价处理。

建议策略：

## ScenePhase

```text
active
```

- 如果用户希望相机运行，且没有照片或视频预览覆盖，则启动或恢复 Session。

```text
inactive
```

- 暂停用户交互。
- 不要立即销毁或重建 Session。
- 系统权限弹窗、控制中心和短暂系统切换可能进入 inactive。

```text
background
```

- 停止 Session。
- 取消倒计时。
- 取消未完成拍照事务。
- 处理正在录制的视频。
- 清理临时资源。

增加明确状态：

```swift
private var wantsSessionRunning: Bool
private var appIsActive: Bool
private var appIsBackgrounded: Bool
```

所有相机和麦克风权限异步回调在启动 Session 前必须再次检查：

```text
用户是否仍希望相机运行
App 是否仍处于允许启动的状态
当前是否存在照片或视频预览覆盖
```

避免以下竞态：

```text
请求权限
→ App 进入 inactive
→ stop
→ 用户允许
→ 授权回调又启动 Session
```

还需要验证：

- 权限弹窗。
- 切后台。
- 锁屏。
- 来电。
- 控制中心。
- 照片分享面板。
- 视频预览。
- 系统设置返回。

# 七、修复对焦、曝光和缩放检查

不能使用：

```swift
supportsAutoFocus ? .autoFocus : .continuousAutoFocus
```

而不检查 fallback 是否支持。

正确逻辑：

```swift
if device.isFocusModeSupported(.autoFocus) {
    device.focusMode = .autoFocus
} else if device.isFocusModeSupported(.continuousAutoFocus) {
    device.focusMode = .continuousAutoFocus
}
```

曝光同理：

```swift
if device.isExposureModeSupported(.autoExpose) {
    device.exposureMode = .autoExpose
} else if device.isExposureModeSupported(.continuousAutoExposure) {
    device.exposureMode = .continuousAutoExposure
}
```

要求：

- 先检查 Point of Interest 支持。
- 再检查具体 Mode 支持。
- 不支持时不赋值。
- 对焦点必须限制在 0 到 1。
- 镜头切换后更新新的后摄设备引用。
- 视频录制中是否允许重新对焦需要有明确策略。
- Fake Camera Mode 不执行设备锁定。

缩放需要：

- 记录手势开始时的基础 Zoom Factor。
- 避免每个 pinch changed 都对当前值连续相乘导致缩放过快。
- 使用 `ramp(toVideoZoomFactor:withRate:)` 或稳定的直接赋值策略。
- 根据设备限制范围。
- 镜头切换后重置或恢复合理缩放值。
- 视频录制中缩放不能导致 Session 重建。

# 八、优化画中画拖动与持久化

当前拖动过程中不要在每一帧：

- 写 UserDefaults。
- 向 Session Queue 发送无关任务。
- 重复应用前摄镜像配置。

拆分以下操作：

```swift
func updateTransientLayout(_ layout: DualCameraLayout)
func commitLayout(_ layout: DualCameraLayout)
func updateMirroring(_ layout: DualCameraLayout)
```

要求：

- 拖动 `.changed`：只更新内存和预览布局。
- 拖动 `.ended`：执行吸附并持久化。
- 尺寸切换：更新并持久化。
- 布局模式切换：更新并持久化。
- 镜像变化：更新相机连接并持久化。
- 位置变化不能触发相机镜像更新。
- UserDefaults 写入应有清晰边界。

# 九、修正前后摄“原图”保存

当前前后摄照片如果经过：

```swift
UIImage → jpegData
```

就不是严格意义上的相机原始文件。

修改拍照结果模型，同时保留：

```swift
struct CapturedSourcePhoto {
    let data: Data
    let image: UIImage
    let position: AVCaptureDevice.Position
}
```

`PhotoCaptureProcessor` 应返回：

- `photo.fileDataRepresentation()`
- 用于预览和合成的 `UIImage`

`CapturedPhotoSet` 建议调整为：

```swift
struct CapturedPhotoSet {
    let id: UUID
    let capturedAt: Date
    let backPhoto: CapturedSourcePhoto
    let frontPhoto: CapturedSourcePhoto
    let composedImage: UIImage
    let layout: DualCameraLayout
    let aspectRatio: CaptureAspectRatio
}
```

保存规则：

- 合成图：允许按照设定质量重新编码。
- 前后摄单路照片：优先直接保存相机返回的原始 `Data`。
- 如果原始 Data 不可用，才明确降级为重新编码 JPEG。
- 保存失败时指出是哪一张失败。

文案可以保留“前后原图”，前提是实际保存原始文件数据。

检查前摄镜像：

- 预览镜像。
- 合成图镜像。
- 单独保存的前摄原始照片。

这三者必须定义清楚，不能互相混用。

# 十、类型化错误与用户操作

当前不能通过比较中文文案判断是否需要显示“去设置”。

建立类型化结果，例如：

```swift
enum CameraNoticeAction: Equatable {
    case none
    case openAppSettings
}
struct CameraNotice: Equatable {
    let message: String
    let kind: CameraNoticeKind
    let action: CameraNoticeAction
}
```

或者直接发布结构化错误：

```swift
enum CameraUserAction {
    case openSettings
    case retrySession
    case dismiss
}
```

要求：

- 相机权限拒绝：可打开设置。
- 麦克风权限拒绝：视频录制提示打开设置，但拍照仍可用。
- 相册权限拒绝：保存提示打开设置。
- Session 临时中断：等待恢复或重试。
- 不支持 MultiCam：只展示说明。
- 单次拍照失败：不改变长期 Session 状态。
- 视频录制失败：不影响之后拍照。

禁止依赖完整错误文案字符串判断逻辑。

# 十一、照片和视频状态分离

避免使用单个永久 `.failed` 状态覆盖全部错误。

建议区分：

```swift
enum CameraSessionState
enum PhotoCaptureState
enum VideoRecordingState
enum MediaSaveState
```

至少保证：

- 照片保存失败不破坏 Session Ready。
- 视频保存失败不破坏 Session Ready。
- 单次拍照失败后仍可继续拍照。
- 视频录制失败后能回到照片模式。
- 麦克风权限拒绝不影响照片。
- 分享面板关闭后 Session 状态正确。
- 中断恢复后清理旧的错误状态。

不要为了状态拆分制造过多 UI 代码，可以由 ViewModel 聚合成最终界面状态。

# 十二、视频功能保留与修复

视频功能必须保留。

本轮不增加新的视频布局或滤镜，但需要保证已有视频链路稳定。

重点检查：

1. 麦克风授权拒绝后仍能继续拍照。
2. 视频模式 Session 重建失败时恢复照片模式。
3. 开始录制前清理旧临时文件状态。
4. 停止录制只能执行一次。
5. 后台或中断时安全结束录制。
6. 没有视频帧时返回明确失败。
7. 音频时间戳早于视频起始时间时正确忽略。
8. 前摄帧和后摄帧不是严格同步，需要在文档说明。
9. 临时 `.mov` 文件在以下场景删除：
   - 用户关闭预览且不保存。
   - 保存成功。
   - 保存失败后用户放弃。
   - 新录制覆盖旧结果。
10. 视频预览中的 `AVPlayer` 在页面关闭后停止并释放。
11. 视频保存权限仍使用 add-only。
12. 录制期间镜头、布局和质量设置是否允许修改，需要明确禁用或延后应用。

不要在本轮增加：

- 视频三种布局。
- 视频比例设置。
- 视频滤镜。
- 直播。
- 暂停继续录制。
- 4K。
- ProRes。
- 后台录制。

# 十三、测试补充

现有测试不够，需要扩展。

## 1. CameraFormatSelectorTests

测试：

- 30fps 优先。
- 30fps 不支持时选择 24fps。
- 过高分辨率被降权。
- 低于目标分辨率的惩罚。
- 没有 MultiCam 格式时返回失败。
- 照片和视频模式候选差异。

AVCaptureDevice.Format 不容易直接构造时，可将评分输入抽象为纯数据模型进行测试。

## 2. CaptureTransactionTests

测试：

- 前后两路成功。
- 前路成功、后路失败。
- 前路失败、后路成功。
- 两路失败。
- 超时。
- 取消。
- 过期回调。
- 重复回调。
- 事务结束后可以开始下一次。
- 合成中进入后台后结果被忽略。

## 3. CameraLifecycleTests

通过协议和 Mock 测试：

- active 启动。
- inactive 不立即销毁 Session。
- background 停止。
- 权限请求期间进入后台。
- 授权回调返回时 App 已在后台。
- 照片预览期间不恢复 Session。
- 视频预览期间不恢复 Session。
- 中断结束后恢复。
- mediaServicesWereReset 后重建。

## 4. PhotoLibraryServiceTests

使用协议封装 PhotoKit 写入行为，测试：

- add-only 已授权。
- 首次请求授权。
- 拒绝权限。
- 只保存合成图。
- 保存合成图和两路原始数据。
- 部分资源编码失败。
- 系统保存失败。
- completion 只执行一次。

## 5. PhotoComposerTests

补充：

- 前摄镜像。
- Aspect Fill 裁切。
- 画中画四个角。
- 三种画中画尺寸。
- 三种输出比例。
- 左右分屏。
- 上下分屏。
- 圆角和边框。
- 非零原点画布。
- 无效图片尺寸。

## 6. CameraPreferencesTests

避免直接污染真实 `UserDefaults.standard`。

支持注入测试 Suite：

```swift
UserDefaults(suiteName: "CameraPreferencesTests")
```

测试：

- 布局保存和读取。
- 旧数据损坏时回退默认值。
- 比例。
- 保存模式。
- 质量模式。
- 网格和倒计时。
- 镜像设置。

## 7. Fake Camera UI 测试

增加 UI Test Target。

至少覆盖：

- Fake Camera 启动。
- 三种布局切换。
- 三种输出比例。
- 画中画尺寸切换。
- 倒计时快门。
- 进入照片预览。
- 打开分享面板。
- 关闭预览。
- 模拟保存失败提示。
- 视频录制按钮的基础状态切换可以用 Fake 模式或受控 Stub 测试。

CI 不依赖真实摄像头。

# 十四、构建与 CI

增加 GitHub Actions 工作流，建议：

```text
.github/workflows/ios.yml
```

执行：

1. `plutil -lint`
2. `xcodegen generate`
3. `git diff --check`
4. Simulator Unit Test
5. iPhoneOS 无签名构建

需要考虑 GitHub macOS Runner 可用的 Xcode 和模拟器名称，不要写死本地才存在的：

```text
iPhone 17 Pro / iOS 26.5
```

可通过：

```bash
xcrun simctl list devices available
```

或使用通用目标：

```bash
-destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

如果 Runner 环境没有指定机型，应选择当前可用设备。

本地继续执行：

```bash
plutil -lint DualCamera/Info.plist
xcodegen generate
git diff --check
xcodebuild \
  -project DualCamera.xcodeproj \
  -scheme DualCamera \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
xcodebuild test \
  -project DualCamera.xcodeproj \
  -scheme DualCamera \
  -destination '<实际可用模拟器>' \
  CODE_SIGNING_ALLOWED=NO
```

每个命令记录：

- 是否成功。
- 测试数量。
- 失败原因。
- 是否存在 Warning。

不要只写“测试通过”。

# 十五、代码规范

继续遵守：

1. 所有 Session 修改在专用串行执行环境中。
2. UI 状态在 MainActor 更新。
3. 不在主线程合成照片或视频帧。
4. 不滥用 `@unchecked Sendable`。
5. 不使用不必要的强制解包。
6. 不依赖中文文案控制业务逻辑。
7. Timer、Task、Observer、Delegate 正确释放。
8. 临时视频文件正确清理。
9. 不重复添加 PreviewLayer。
10. Session 启动、停止和重建必须幂等。
11. 保存 completion 只能完成一次。
12. 不无限保留 `UIImage`、`Data` 和视频帧。
13. 对复杂并发和状态切换增加注释。
14. 删除过期或错误的注释，例如旧类名。
15. 文档描述必须与实际代码一致。
16. 不将未真机验证的内容标记为已完成。

# 十六、文档更新

更新：

```text
README.md
CHANGELOG.md
plan.md
docs/architecture.md
docs/使用说明.md
docs/真机验收.md
docs/roadmap.md
```

重点修正：

- 视频是当前保留功能，不再描述为本轮外的能力。
- 照片和视频都是近同步双路采集，不是严格硬件同步。
- hardwareCost 和 systemPressureCost 是仅诊断还是已自动降级，必须按真实代码描述。
- 快速和均衡模式必须与真实实现一致。
- “前后原图”必须与实际保存方式一致。
- 自动测试和真机测试分开描述。
- GitHub Actions 未运行时不得宣称 CI 已通过。

真机验收新增：

- 快速与均衡照片质量。
- 30fps 降到 24fps 的情况。
- hardwareCost / systemPressureCost。
- 麦克风拒绝后继续拍照。
- 视频录制中断。
- 视频临时文件清理。
- 连续拍照 20 次。
- 连续视频录制 5 次。
- 视频结束后重新拍照。
- 镜头切换后拍照和视频。
- 后台期间授权回调。
- inactive 状态不错误停止。
- 锁屏后恢复。
- 高温压力提示。

# 十七、提交范围

本轮不要新增其他功能。

禁止新增：

- 视频新布局。
- 视频画幅切换。
- 暂停继续录制。
- 实时滤镜。
- AI 美颜。
- 直播。
- 云同步。
- 账号系统。
- 订阅。
- ProRAW。
- 专业手动曝光。
- 横屏支持。

如果修复过程中发现新问题：

- 属于崩溃、数据丢失、权限、生命周期、资源泄漏或构建失败的问题，直接修复。
- 属于新功能或体验增强的问题，记录到 `docs/roadmap.md`，不要扩大本轮范围。

# 十八、最终汇报

完成后必须输出：

1. 修复的问题列表。
2. 保留的视频功能及本轮修复内容。
3. 新的代码结构。
4. `MultiCamSessionController` 修改前后的行数和职责变化。
5. 新增和修改文件。
6. 拍照质量模式的最终实现。
7. 硬件成本降级策略。
8. 生命周期竞态修复方式。
9. 前后摄原始照片保存方式。
10. 新增测试及测试数量。
11. GitHub Actions 配置。
12. 实际执行的命令。
13. 编译结果。
14. 自动测试结果。
15. 未完成或无法自动验证的内容。
16. iPhone 16 Pro 真机待验收项目。
17. 是否建议将 Draft PR 改为 Ready for Review。

不要只输出“任务完成”。

所有结论必须能通过代码、测试日志或文档核实。