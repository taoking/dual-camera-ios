# 变更记录

## Unreleased — 2026-07-27

### 新增

- 双摄照片的画中画、左右分屏、上下分屏与 3:4／1:1／9:16 比例。
- 画中画拖动、吸附、尺寸档位，及布局／镜像／网格／倒计时等持久化设置。
- 合成照片分享、成片加原图的可选保存模式、相册权限“去设置”入口。
- 后摄对焦／测光、缩放、倒计时、触感反馈、硬件诊断和 Fake Camera Mode。
- `CameraViewModel`、布局引擎、照片合成、相册服务、OSLog 与单元测试目标。
- `CameraFormatSelector`、`CameraSessionConfigurator`、照片／视频 Coordinator、生命周期／授权／运行期监视和诊断模块。
- 可注入 PhotoKit、UserDefaults 适配，Fake Camera UI Test Target 及自适应模拟器 GitHub Actions。

### 变更

- 将拍照改为具备 UUID、期望两路结果与超时清理的事务。
- 预览与成片改用同一布局引擎；修复默认画中画位置被错误约束到左上角的问题。
- 保存成功后仍自动返回预览；中断、后台和媒体服务重置的恢复逻辑得到增强。
- 快速／均衡模式在 Session 启动前设置 PhotoOutput 上限和单次请求值，超出系统上限时安全钳制。
- MultiCam 配置改为有限尝试 30fps／24fps 候选，只有硬件和压力成本均不超过 1 才接受；serious／critical／shutdown 压力执行分级保护。
- inactive 不再等同 background；相机／麦克风授权回调会重新检查运行意图、active/background 和媒体预览。
- 画中画拖动中不再逐帧写 UserDefaults 或重设镜像；后摄缩放以手势起始倍率计算。
- “前后原图”改为优先保存 `fileDataRepresentation()`；前摄预览、合成镜像和单路相机文件方向分离。
- 照片、视频和媒体保存错误改为独立状态与类型化用户操作，麦克风拒绝或单次媒体失败不破坏拍照 Ready。
- 保留固定画中画视频，补充幂等停止、无帧错误、临时 `.mov` 清理和播放器释放。

### 限制

- 双路照片为近同步采集，非严格硬件同步曝光。
- 双路视频使用最近可用前摄帧合成，同样不承诺逐帧硬件同步。
- 本轮后续真机验收尚未逐项完成，详见 `docs/真机验收.md`。
- GitHub Actions 仅完成配置，尚未在本分支取得远端成功记录。
