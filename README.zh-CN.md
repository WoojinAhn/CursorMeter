[English](README.md) | [한국어](README.ko.md) | **简体中文** | [日本語](README.ja.md)

<p align="center">
  <img src="Resources/AppIcon.png" width="80" alt="CursorMeter 图标">
</p>

<h1 align="center">CursorMeter</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/github/license/WoojinAhn/CursorMeter" alt="许可证">
  <img src="https://img.shields.io/github/v/release/WoojinAhn/CursorMeter" alt="发布版本">
</p>

一款轻量的 macOS 菜单栏应用，让 [Cursor](https://www.cursor.com/) IDE 使用量一目了然，无需打开浏览器标签页。

与编辑器内的扩展不同，CursorMeter 是独立运行的原生 macOS 应用：无论 IDE 是否打开，它都会显示在菜单栏中，并通过 Keychain 在重启后保持登录状态。

Cursor [于 2026 年 2 月 11 日宣布为个人套餐引入两类使用额度](https://cursor.com/blog/increased-agent-usage)。CursorMeter 现在根据 Cursor 提供的使用百分比，分别显示 **Cursor Models** 和 **Other Models**。

双额度仪表目前提供**一种视觉布局：中央饼图和外环**。在 Settings → Display 中，你可以交换两者的位置，并选择弹出面板显示百分比、美元金额或两者。后续更新计划提供更多视觉布局。

## 功能

- **双额度使用情况一目了然** — 对于受支持的个人付费套餐，中央饼图显示 Cursor Models，外环显示 Other Models。每个区域都有自己的百分比和颜色；可在 Display 设置中选择外环对应的额度。缺失的数据保持不可用状态。
- **弹出面板中的今日用量占比** — 较浅的色块根据记录的套餐内使用金额估算今日用量的贡献，以韩国标准时间（UTC+9）午夜为日界线。将鼠标悬停在大圆上可查看其含义。只有数据相互匹配且通过验证时才会显示高亮；任一类额度达到 100% 时，高亮会隐藏。整体填充比例和提醒仍使用 Cursor 提供的百分比。
- 在菜单栏查看使用量和重置日期；单额度套餐还会在数据可用时显示请求次数
- **清晰的使用量提醒** — 为 Cursor Models、Other Models 和符合条件的额外付费预算分别设置警告/严重阈值（默认：80%/90%）。通知显示实际使用量和设置的级别。同一次更新中的警告与大幅增长会合并为一条简洁通知。
- **用量突增效果** — 中等幅度增长时菜单栏图标闪现 ⚡，大幅增长时闪现 🚀，让突增不易被忽略。提供三个强度级别（Quiet / Normal / Bold）和两组图标样式（⚡/🚀 或 💲/💸）；Bold 还会在第 2 级突增时发送 macOS 通知，独立于使用量提醒的监控对象及其总开关。双额度套餐保留套餐内使用金额 $0.05/$0.30 的灵敏度，并同时使用 +5/+15 个百分点的信号；消息会注明测量范围，不猜测增长原因。
- **每周使用量图表**（所有套餐）— 滚动显示最近 7 天的柱状图，可在 Settings → Display 中选择 **Amount**（默认）或 **Usage units**。柱高、颜色和悬停提示使用同一指标。Amount 包括套餐覆盖用量和按需用量的金额，并非仅指额外收费；若缺少金额数据，图表会改用加权使用单位（`requestsCosts`）。可配置今日高亮方式（Outline / Dim others / Both）。
- **每周图表的数据时效** — 暂时失败时保留上一次图表。连续两次失败后显示带日期的最近更新时间；如果尚未载入任何历史数据，则显示简短的重试提示。现有刷新计划会自动重试。
- **使用量详情** — 弹出面板放大显示双额度仪表，可显示百分比、记录的美元金额或两者；在 Display 设置中选择格式。可选的估算上限默认关闭，仅在相互匹配的使用量与金额数据足以支持时显示。这些是非官方估算值，不代表套餐计费权益。圆形的整体填充比例和提醒始终使用报告的百分比。按需支出与 Bot 活动单独统计。
- **最近使用记录** — Settings → Usage 最多显示最近 30 次请求，包括模型、时间、类型、token 数和美元金额。Included 金额表示套餐已覆盖的用量，并非额外收费。可选择 **Local**（此 Mac 的时区，默认）或 **UTC**；**Open Cursor** 可打开完整历史记录和账单控制台。
- **保存在此 Mac 上** — 一份大小受限的快照可跨重启保留，并显示原始缓存日期和时间。刷新失败时会保留符合使用条件的已保存数据。每台 Mac 有自己的缓存和刷新计划；这不是本地历史归档或设备同步服务。
- **共享刷新** — 弹出面板与 Usage 标签页共享一次进行中的刷新，两次获准开始的刷新之间至少间隔 3 秒，并提供至少 1.3 秒的进度反馈。列表复用现有的每周事件响应。打开标签页或切换时区不会发起请求。
- 双额度套餐默认保持紧凑的菜单栏图标。在 Settings → Display 中开启 **Show percentages**，即可在圆形旁显示两个使用百分比：上方对应外环，下方对应中央。悬停提示仍会注明两类额度名称；点击可查看详情。单额度套餐保留仅图标、分数和百分比模式，以及你已保存的偏好。
- 设置界面（刷新间隔、通知阈值、菜单栏显示格式、突增效果强度、每周图表样式、最近使用记录）
- 支持登录时启动
- 应用内更新检查
- **零配置登录** — 如果同一台 Mac 上的 Cursor IDE 已登录，CursorMeter 会自动连接，无需单独登录。如果 IDE 尚未登录，弹出面板会提供引导：一键打开 IDE，完成登录后应用便会自动连接。退出登录会暂停自动连接 IDE，直到你重新连接。
- **浏览器（WebView）登录已弃用** — 该方式仍可使用（Google、GitHub、Enterprise SSO），但默认隐藏，需要在 Settings → General → "Enable browser login" 中主动开启。仅当未安装 Cursor IDE 应用时，它才会自动重新显示，以确保始终至少有一种连接方式。
- 可配置自动刷新间隔（1/2/5/15 分钟）
- **活动触发刷新** — 本地 Cursor 活动会在约 1 分钟内触发刷新，无需等待下一次轮询。定时轮询仍作为后备方式，包括获取其他设备上的使用量。何时可见取决于 Cursor 的上报延迟。可在 Settings → Refresh → "Refresh on Cursor activity" 中开关。
- 使用 Keychain 存储凭据
- 纯 AppKit，无外部依赖

## 安全性

- 零外部依赖（仅使用 macOS SDK）
- 两级 WebView 主机白名单（精确匹配 + 后缀匹配），在导航动作和响应两处强制使用 `https`
- 保存登录会话前验证必需的 Cookie
- 对从 GitHub Releases API 获取的所有 URL，通过主机验证后再调用 `NSWorkspace.open`
- 使用 `URLSessionConfiguration.ephemeral`（无 HTTP 磁盘缓存）；大小受限的最近使用/计费周期快照以及成功提醒记录单独存储
- 使用 Keychain 存储凭据

完整的威胁模型和报告政策请参阅 [`SECURITY.md`（英文）](SECURITY.md)。

## 系统要求

- macOS 14（Sonoma）或更高版本
- Apple Silicon 或 Intel Mac（Intel 需要发布版本包含 `x86_64` ZIP）

## 安装

### 快速安装（推荐）

Apple Silicon 和 Intel Mac 使用同一条命令。脚本会识别你的 Mac，下载匹配的构建版本；若提供了校验和则进行验证，然后安装到 `/Applications`。

```bash
curl -fsSL https://raw.githubusercontent.com/WoojinAhn/CursorMeter/main/Scripts/install.sh | bash
```

Intel 安装需要发布版本包含 `x86_64` ZIP。如果最新版本尚未提供该文件，脚本会停止，不会替换现有应用。

### 手动安装

1. 从 [Releases](https://github.com/WoojinAhn/CursorMeter/releases) 下载适合你的 Mac 的 ZIP：**Apple Silicon：** `CursorMeter-<version>.zip`；**Intel：** `CursorMeter-<version>-x86_64.zip`（发布版本提供时）。
2. 可选 — 如果发布版本包含 `.zip.sha256` 文件，可验证下载内容：
   `shasum -a 256 -c CursorMeter-<version>.zip.sha256`
   Intel 请改用 `CursorMeter-<version>-x86_64.zip.sha256`。
   （此操作可检测损坏或错误的文件，并非验证发布者签名；应用使用 ad-hoc 签名，参见第 4 步。）
3. 解压并将 `CursorMeter.app` 拖入 `/Applications`
4. 首次启动时，macOS 可能会拦截应用（未签名）。可通过以下方式打开：
   - **右键点击**应用 → **Open** → 在对话框中点击 **Open**
   - 或：System Settings → Privacy & Security → 点击 **Open Anyway**

## 从源码构建

```bash
# 构建并创建 .app 包（ad-hoc 签名）
bash Scripts/package_app.sh

# 安装
cp -r CursorMeter.app /Applications/
```

需要 Swift 6.0+ 和 Xcode。若要为特定架构构建，请运行 `BUILD_ARCH=arm64 bash Scripts/package_app.sh` 或 `BUILD_ARCH=x86_64 bash Scripts/package_app.sh`。两者都会生成 `CursorMeter.app`；可设置 `APP_OUTPUT_DIR`，将它们保存在不同目录。

## 测试

```bash
swift test    # 运行所有测试（需要 Xcode）
```

测试套件覆盖视图模型逻辑（凭据链、过期数据检测、阈值、突增事件）、自定义控件（双滑块范围控件）、通知规则、日志脱敏，以及通过 URLProtocol mock 进行的 API 客户端集成测试。手动测试场景请参阅 [test-checklist.md](docs/test-checklist.md)。

## 免责声明

本应用使用 Cursor 的多个**未公开文档的内部端点**（使用量、认证和控制台 API；完整列表见 [`docs/API_REFERENCE.md`](docs/API_REFERENCE.md)）。这些端点可能随时变更或被封锁，恕不另行通知。

## 参与贡献

发现了问题或有新想法？欢迎[提交 issue](https://github.com/WoojinAhn/CursorMeter/issues)，我们始终欢迎反馈和建议。目前不接受 Pull Request。

## 截图

<table>
  <tr>
    <th align="center">两类额度，一个仪表</th>
    <th align="center">显示选项</th>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/screenshots/popover-weekly.png"><img src="docs/screenshots/popover-weekly.png" alt="中央饼图显示 Cursor Models，外环显示 Other Models，以及使用量数值和每周图表" width="300"></a></td>
    <td align="center" valign="top"><a href="docs/screenshots/settings-display.png"><img src="docs/screenshots/settings-display.png" alt="Display 设置，包括菜单栏双行百分比、环形位置、弹出面板数值、可选估算和突增效果" width="300"></a></td>
  </tr>
  <tr>
    <td align="center">两类额度及本周活动。</td>
    <td align="center">选择数值、位置和效果。</td>
  </tr>
  <tr>
    <th align="center">独立提醒</th>
    <th align="center">最近请求</th>
  </tr>
  <tr>
    <td align="center" valign="top"><a href="docs/screenshots/settings-alerts.png"><img src="docs/screenshots/settings-alerts.png" alt="为各模型额度和额外付费预算分别提供开关及双滑块警告/严重阈值控件" width="300"></a></td>
    <td align="center" valign="top"><a href="docs/screenshots/settings-usage.png"><img src="docs/screenshots/settings-usage.png" alt="最近请求，包含模型、时间、使用类型、token 数和金额" width="300"></a></td>
  </tr>
  <tr>
    <td align="center">每类额度各有警告和严重级别。</td>
    <td align="center">最多 30 次请求，使用本地时间或 UTC。</td>
  </tr>
</table>

<p align="center"><em>当前原生 AppKit 界面，使用演示数据。模型名称、金额和推算上限仅为示例，不代表套餐权益。点击图片可查看原图。</em></p>

<details>
  <summary>百分比、美元金额和可选估算上限</summary>
  <table>
    <tr><th>百分比</th><th>美元金额</th><th>两者及估算值</th></tr>
    <tr>
      <td valign="top"><a href="docs/screenshots/popover-percent.png"><img src="docs/screenshots/popover-percent.png" alt="显示两类使用百分比的弹出面板" width="220"></a></td>
      <td valign="top"><a href="docs/screenshots/popover-dollars.png"><img src="docs/screenshots/popover-dollars.png" alt="显示记录的美元金额和可选推算上限的弹出面板" width="220"></a></td>
      <td valign="top"><a href="docs/screenshots/popover-estimated.png"><img src="docs/screenshots/popover-estimated.png" alt="显示百分比、记录的美元金额及可选推算上限的弹出面板" width="220"></a></td>
    </tr>
  </table>
  <p>估算值默认关闭，仅在相互匹配的使用量和金额观测足以支持时显示。它们不会改变圆形显示或提醒。<a href="docs/screenshots/estimated-limits-help.png">查看应用内说明。</a></p>
</details>

<details>
  <summary>关闭每周图表后的弹出面板</summary>
  <p align="center">
    <a href="docs/screenshots/popover.png"><img src="docs/screenshots/popover.png" alt="关闭每周图表后的双额度仪表弹出面板" width="300"></a>
  </p>
</details>

## 许可证

MIT
