# iOS 应用开发、打包与发布全流程指南

本文覆盖将本仓库的双摄相机 App 安装到 iPhone、交付测试人员和发布 App Store 的完整流程，也适用于一般原生 iOS App。

> iPhone App 不能像 Android 一样将未签名安装包发给任意用户安装。真机安装、IPA 导出和正式分发都受 Apple 签名与分发规则约束。

## 1. 先确定分发目标

先明确“谁安装、安装多久、是否上架”，再决定账号和打包方式。

| 目标 | 推荐方式 | 需付费开发者计划 | 典型用途 |
| --- | --- | --- | --- |
| 自己的 iPhone 调试 | Xcode Run + Personal Team | 否 | 开发、功能验证 |
| 已登记的少量设备 | Debugging / Release Testing | 是 | 团队验收、指定设备测试 |
| 内外部 Beta 用户 | TestFlight | 是 | 测试与反馈 |
| 面向公众 | App Store | 是 | 正式产品 |
| 指定企业/学校 | Custom App | 是 | B2B、教育机构 |
| 合格组织内部员工 | Enterprise + MDM | 是，且有资格限制 | 企业内部应用 |

免费 Apple Account 可用于学习和个人设备测试；TestFlight、App Store 和可控的设备分发需要 Apple Developer Program。参见 [Apple 官方会员对比](https://developer.apple.com/support/compare-memberships/)。

## 2. Apple 账号与开发者计划

### 2.1 准备 Apple Account

1. 在 [Apple Account](https://account.apple.com/) 创建或登录账号。
2. 启用双重认证（2FA），确认常用邮箱和手机号码可用。
3. 始终使用法定姓名和可联系地址；不要共享账号密码、恢复密钥、App Store Connect API Key、签名私钥或 `.p12` 文件。

### 2.2 免费 Personal Team：个人设备安装

在 **Xcode → Settings → Apple Accounts** 登录 Apple Account。未加入付费计划的账号会显示为 **Personal Team**；选择该 Team 后可直接从 Xcode 运行到自己的 iPhone。

当前限制如下：

- App ID 最多 10 个、可注册设备最多 3 台、每台最多安装 3 个 App。
- 相关资源与描述文件通常在 7 天后失效，需要重新构建、签名和安装。
- 不能用于 App Store、TestFlight、Release Testing 或企业分发。

详细限制以 Apple 的 [开发者账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account) 为准。

### 2.3 Apple Developer Program：测试分发和上架

从 [Apple Developer Program Enrollment](https://developer.apple.com/programs/enroll/) 申请。当前标准年费为 **99 美元/会员年**，本地币种价格以结算页为准；符合条件的非营利组织、教育机构和政府实体可申请减免。

选择申请主体：

- **个人/个体经营者**：需要开启 2FA 的 Apple Account、法定姓名、真实地址与电话。App Store 卖方名称将显示个人法定姓名。
- **组织**：申请人必须具备代表组织签署协议的授权；组织应为可签约的法人实体。除政府实体外，通常要提供匹配法人信息的 D-U-N-S Number、组织域名邮箱和可正常访问的网站。App Store 卖方名称将显示组织法定名称。

审核和付款完成后，由 Account Holder 接受协议。组织团队建议按最小权限添加 Account Holder、Admin、Developer、App Manager 等角色。

## 3. 立项与合规准备

编码前完成以下清单，后续审核和运营将直接使用：

1. 产品目标、目标用户、核心流程、最低 iOS 版本、离线/网络依赖和收费方式。
2. App 名称、图标、截图、支持邮箱、支持网站和隐私政策 URL。
3. 数据地图：每种数据的收集方、用途、保留期限、第三方 SDK、跨境传输和删除入口。
4. 权限设计：仅在用户即将使用功能时请求权限，并提供清晰、真实的权限用途文案。
5. 登录、支付、定位、健康、儿童、相机、相册、用户生成内容等功能的法规和审核风险评估。

本项目使用相机，`Info.plist` 已含 `NSCameraUsageDescription`。若以后保存照片到系统相册，必须补充相应的照片库权限与隐私声明。

提交前还应检查最新的 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

## 4. 配置 Xcode 工程

1. 安装当前稳定版 Xcode，首次启动时完成许可和平台组件安装。
2. 打开 `DualCamera.xcodeproj`。
3. 选择 `DualCamera` target，在 **Signing & Capabilities** 中：
   - 打开 **Automatically manage signing**。
   - 选择 Personal Team 或已加入的付费 Team。
   - 将 Bundle Identifier 改成团队下唯一的值，例如 `com.yourcompany.dualcamera`；不要保留示例值 `com.example.dualcamera`。
4. 确认 Deployment Target 为项目要求的 iOS 17.0。
5. 在 `Info.plist` 设置显示名、版本号和构建号。上传 App Store Connect 时构建号必须递增。

Apple 对真机调试的要求是：在 Xcode 的 Apple Accounts 登录账号，且在项目 Signing & Capabilities 中为 target 分配 Team；参见 [在物理设备上运行 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)。

工程实践建议：

- 使用 Git、分支、Pull Request 和 CI；不要提交 `DerivedData`、证书、描述文件、私钥、真实用户数据或服务端密钥。
- 分离 UI、业务状态、设备服务、网络层和数据模型；关键业务写单元测试。
- 用统一机制维护版本号；为每次发布保留 Archive、Git tag、变更说明和测试记录。
- 记录第三方 SDK 版本、许可证和隐私行为；新 SDK 接入后重做隐私核查。

## 5. 开发与测试流程

```text
需求/原型 → 技术方案 → 实现 → 单元测试 → 模拟器检查
→ 真机检查 → 代码评审 → Beta 分发 → 缺陷修复 → 发布
```

模拟器适合 UI、状态和普通网络逻辑；相机、蓝牙、推送、后台运行、性能、热管理、蜂窝网络和硬件能力必须在真实设备验证。

### 本项目的 iPhone 16 Pro 验收

1. 用线缆连接 iPhone，手机上选择“信任此电脑”。
2. 在 Xcode Scheme 目的地选择该 iPhone。
3. 点击 Run；首次选 Team 时 Xcode 会创建开发证书和描述文件。
4. 授予相机权限，确认后置全屏与前置画中画均为实时画面。
5. 连续拍照、切后台后返回、相机被电话/视频会议/屏幕录制占用、低电量和高温时分别检查提示与恢复。

> 模拟器无法证明前后摄并发采集；这一步必须由物理 iPhone 完成。

## 6. 签名的核心概念

| 名称 | 作用 | 是否提交到 Git |
| --- | --- | --- |
| Bundle ID / App ID | App 的唯一身份，与服务能力绑定 | 仅记录标识符 |
| Signing Certificate | 证明构建来自团队；私钥保存在钥匙串 | 否，严禁泄露 `.p12` |
| Provisioning Profile | 约束 App ID、证书、设备和分发用途 | 否，按需由 Xcode 管理 |
| Entitlements | 声明推送、iCloud、Keychain 等能力 | 是，作为工程配置审查 |

开发阶段优先选 **Automatically manage signing**。涉及多团队、CI 专用证书、已注册设备清单或 Release Testing 时才手动管理；此时必须让 App ID、证书、设备和描述文件精确匹配。App Store Connect 上传需要显式 App ID，参见 [创建 App Store Connect 描述文件](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)。

## 7. 打包产物及用途

| 文件 | 含义 | 用途 |
| --- | --- | --- |
| `.app` | 已构建的应用包 | Xcode/`devicectl` 安装到已签名、已注册设备 |
| `.xcarchive` | Xcode 归档，含 App、符号和发布元数据 | 导出、上传和留档 |
| `.ipa` | 已签名的 iOS 分发包 | 已登记设备的测试分发或受控交付 |

IPA 不是“发给任意人即可安装”的文件。能否安装取决于证书、描述文件、设备注册和分发类型。

## 8. 生成并安装开发版

### 8.1 用 Xcode 图形界面（推荐）

1. 选择 **Any iOS Device (arm64)** 或真实设备。
2. 选择 **Product → Archive**。
3. 在 Organizer 选择 Archive，点击 **Distribute App**。
4. 按目的选择：
   - **Debugging**：开发调试，安装到已注册设备。
   - **Release Testing**：付费团队对已注册设备做发布前测试。
   - **TestFlight & App Store**：上传 App Store Connect。
   - **TestFlight Internal Only**：仅团队内部 TestFlight。
5. 让 Xcode 自动签名并导出或上传；导出的 IPA 应放在受控存储，不能公开分享。

选择项及用途以 [Xcode 分发文档](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/) 为准。

### 8.2 命令行归档与 IPA 导出

先在 Xcode 完成账号、Team 和唯一 Bundle ID 配置，再执行：

```sh
mkdir -p build

xcodebuild \
  -project DualCamera.xcodeproj \
  -scheme DualCamera \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$PWD/build/DualCamera.xcarchive" \
  -allowProvisioningUpdates \
  clean archive
```

`-allowProvisioningUpdates` 可能在开发者账号中创建或更新签名资源，只能用有权限的 Team 账号。

创建 `build/ExportOptions-debugging.plist`，把 `TEAM_ID` 换成实际 Team ID：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>debugging</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>TEAM_ID</string>
</dict>
</plist>
```

导出：

```sh
xcodebuild -exportArchive \
  -archivePath "$PWD/build/DualCamera.xcarchive" \
  -exportPath "$PWD/build/export-debugging" \
  -exportOptionsPlist "$PWD/build/ExportOptions-debugging.plist" \
  -allowProvisioningUpdates
```

成功后 IPA 位于 `build/export-debugging/`。Xcode 26 使用 `debugging`、`release-testing`、`app-store-connect` 等 export method；请以本机 `xcodebuild -help` 为准。

### 8.3 安装到已连接 iPhone

最简单方式是选择设备后在 Xcode 点击 Run。命令行可安装 Archive 内已经签名的 `.app`：

```sh
# 查看设备 UDID
xcrun devicectl list devices

# 替换 DEVICE_UDID 和实际路径
xcrun devicectl device install app \
  --device DEVICE_UDID \
  "$PWD/build/DualCamera.xcarchive/Products/Applications/双摄相机.app"
```

如果提示不受信任或无法启动，检查 Team、Bundle ID、设备注册、描述文件有效期及手机开发者信任设置。不要通过来源不明企业证书或修改系统安全设置绕过签名。

## 9. TestFlight：给测试人员安装

TestFlight 是向多人 Beta 分发的首选：无需收集 UDID，用户用 TestFlight App 安装、更新和提交反馈。

1. 加入付费计划，在 [App Store Connect](https://appstoreconnect.apple.com/) 接受协议；销售付费 App 或内购时补齐税务和收款信息。
2. 在 **Apps** 创建 App Record，设置名称、Bundle ID、SKU、主语言和平台。
3. Xcode 中选择 **Product → Archive → Distribute App → TestFlight & App Store**，上传 Archive。
4. 等待 App Store Connect 处理构建；每次上传均使用新的构建号。
5. 在 TestFlight 填写 Beta 说明、测试重点和反馈邮箱。
6. 添加内部测试者；邀请外部测试者时，首个构建须通过 TestFlight Beta App Review。
7. 通过邮件或 Public Link 发邀请，收集崩溃和反馈后持续迭代。

Apple 当前支持最多 100 名内部测试者和 10,000 名外部测试者，详见 [TestFlight 官方页面](https://developer.apple.com/testflight/)。

## 10. App Store 提交与发布

### 提交材料

- 唯一 Bundle ID、App 名称、SKU、分类、年龄分级、地区和价格。
- 各设备尺寸的真实截图、描述、关键词、支持 URL 和营销 URL（如需）。
- 可公开访问的隐私政策 URL 与准确的 App Privacy 数据申报，包含第三方 SDK 行为。
- 有登录时提供审核用测试账号或完整演示模式，并在 Review Notes 中写明流程。
- 后端、支付、硬件依赖和地域限制在审核期可用，并提供必要说明。
- 真机测试完成，无崩溃、占位内容、失效链接、隐藏或未文档化功能。

Apple 要求 iOS App 提供隐私政策 URL，并在 App Store Connect 中如实描述自身和第三方合作方的数据处理；详见 [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)。

### 提交流程

1. 在 App Store Connect 创建版本，填写元数据并选择处理完成的构建。
2. 填写 App Review 信息、联系信息、登录凭据和审核备注。
3. 完成出口合规、内容权利、年龄分级、隐私和商业条款确认。
4. 提交审核；若被拒绝，在 Resolution Center 阅读具体问题，修复后再提交。
5. 审核通过后选择手动、自动或分阶段发布，并监控崩溃、评价和隐私变化。

App Store Connect 必须先有 App Record 才能上传构建；当前流程见 [App Store Connect workflow](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow)。

## 11. 私有、非公开与企业分发

- **Unlisted App**：仍经审核并在 App Store 托管，但通常仅能通过直达链接发现。
- **Custom App**：在 Apple Business Manager 或 Apple School Manager 面向指定组织分发。
- **Enterprise**：仅供符合 Apple Developer Enterprise Program 条件的组织向自有员工分发，通常配合 MDM；不可用于客户、公众或朋友。

Public、Private 和 Unlisted 的规则及切换限制见 [App Store 分发方式说明](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/set-distribution-methods)。开始前选择正确的方式，避免因切换而需要新建 App Record。

## 12. 发布后的持续工作

1. 监控崩溃、性能、评论、客服工单和审核反馈。
2. 每次新增 SDK、权限、数据用途或后端能力时，更新隐私政策与 App Privacy 回答。
3. iOS/Xcode 新版本后回归相机、权限、登录、支付和后台等关键流程。
4. 轮换有风险的密钥，检查证书/描述文件到期日，保持依赖可维护。
5. 每次发版保留 Archive、Git tag、测试记录、变更说明和可重现的 CI 日志。

## 13. 本项目的最短路线

```text
今天自己安装
  Apple Account → Xcode 登录 → Personal Team → 修改 Bundle ID
  → 连接 iPhone 16 Pro → Run → 每 7 天重新签名

一周内给测试人员体验
  加入 Apple Developer Program → 创建 App Record
  → Archive → 上传 TestFlight → 邀请测试者

正式上线
  完成隐私政策/截图/元数据/审核材料 → TestFlight 回归
  → 提交 App Review → 发布并持续运营
```

如果目标只是把本仓库安装到自己的 iPhone，应优先走第一条路线，不必先制作可转发 IPA；若要让其他人稳定安装和更新，TestFlight 通常比手工分发 IPA 更合适。
