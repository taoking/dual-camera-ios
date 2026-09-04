## 变更内容

- 为 MultiCam 增加可测试的格式评分和最多 12 组 30／24fps 成本降级，要求 `hardwareCost`、`systemPressureCost` 均不超过 1。
- 在 Session 启动前安全配置快速／均衡 PhotoOutput 质量；增加 serious／critical／shutdown 运行期压力策略。
- 拆分 Session 配置、照片事务、视频输出、授权、生命周期、运行期监视和诊断职责。
- 修复 inactive/background、权限异步回调、对焦模式 fallback、缩放基准和画中画逐帧持久化问题。
- 前后单路照片优先保存 `fileDataRepresentation()`；预览镜像、合成镜像和原始文件方向分离。
- 保留固定画中画双摄视频，补充幂等停止、无帧错误、临时文件清理和 AVPlayer 释放。
- 照片与视频改为非阻断自动保存；停止录像后立即恢复取景，最近媒体通过缩略图主动查看，保存失败可重试。
- 增加准备录制、录制中、处理中状态与单调时钟录制时长；并发保存按媒体 ID 去重，按拍摄序号保护最近媒体顺序。
- 增加结构化照片／视频／保存状态和用户操作，不再比较中文错误文案。
- 增加 68 项单元测试、3 项 Fake Camera UI 测试和自适应模拟器 GitHub Actions。

## 本地验证（2026-07-27）

- `plutil -lint DualCamera/Info.plist`：通过。
- `xcodegen generate`：通过。
- `git diff --check`：通过。
- `DualCameraTests`：68 通过、0 失败、0 跳过。
- `DualCameraUITests`：3 通过、0 失败、0 跳过；存在不影响结果的 LLDB version store 环境提示。
- iPhoneOS Debug 无签名构建：通过；没有 Swift 编译 warning。
- iPhone 16 Pro 开发签名构建、签名校验、覆盖安装和启动：通过；首次启动需在设备上显式信任开发者。

## 尚未验证

- GitHub Actions 尚未在包含本轮改动的远端提交上运行。
- 第六阶段包已在 iPhone 16 Pro 安装并启动，但真实相机与媒体流程尚未由真人逐项验收。
- MultiCam 候选、真实成本／压力、20 次连续拍照、5 次连续视频、镜头组合、权限／锁屏／中断和相册文件方向仍按 `docs/真机验收.md` 待执行。

因此 PR 应暂时保持 Draft；推送本轮提交、CI 通过并完成关键 iPhone 16 Pro 验收后再改为 Ready for Review。
