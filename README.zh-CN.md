# DustWatch

[English README](README.md)

DustWatch 是一个 macOS 菜单栏应用，用来长期记录 Mac 的热状态。它会记录
CPU/GPU 温度、风扇转速和负载，并根据历史数据提示可能的散热能力下降，比如积灰。

这个项目同时面向两类人：

- 普通用户：想让应用安静地后台运行，并在需要清灰时得到一个清晰提示。
- 开发者：想研究一个本地传感器采集、SwiftUI/AppKit 图表、SQLite 存储和热风险分析项目。

DustWatch 仍处在 beta 阶段。当前传感器读取和风险模型已经可以实际使用，但积灰风险算法还没有在足够多的机器、房间温度、季节、负载和散热结构上验证。欢迎用户和开发者提供误判案例、实际数据、算法想法和代码改进。

## 运行要求

- macOS 13 Ventura 或更高版本
- Apple Silicon 是主要支持目标
- Release workflow 会构建 Intel 版本，但传感器解析属于尽力支持
- 本地构建不需要 Apple Developer 账号
- 安装 Xcode command-line tools 即可构建

DustWatch 没有开启 App Sandbox。读取 SMC 传感器需要使用 macOS 的私有接口，沙盒应用无法访问这些接口。

## 安装

最简单的方式是从 GitHub Releases 下载最新 DMG：

<https://github.com/NormanZyq/dust-watch-mac/releases>

打开 DMG，把 `DustWatch.app` 拖到 `/Applications` 后启动。当前 beta 版本使用 ad-hoc 签名，macOS 第一次可能会拦截启动。如果出现拦截，请打开**系统设置 > 隐私与安全性**，为 DustWatch 选择**仍要打开**。

启动后，DustWatch 会打开 dashboard，并在菜单栏保留图标继续后台运行。默认采样间隔是 60 秒。

## 日常使用

- **概览**：显示今日峰值、近期趋势和当前积灰风险等级。
- **实时**：查看最近的原始采样曲线。
- **历史**：按 24 小时、7 天、30 天、90 天或全部数据查看，并支持原始/小时/日聚合和 CSV 导出。
- **热力图**：按天展示过去数周或数月的热状态强度。
- **对比**：当模型有足够证据时，展示当前散热损失对比。
- **设置**：调整采样、告警阈值、近期分析窗口、通知、演示数据和散热参考校准。

设置会立即保存，不需要手动保存按钮。校准按钮只应该在你确认机器散热状态健康时使用，例如刚刚清灰后。重置校准不会删除历史样本，只会清除校准时间点，让模型恢复为自动学习历史最佳散热参考。

如果当前 macOS 版本无法读取 SMC 传感器，可以在设置或菜单栏里启用演示模式。演示模式会生成更真实的模拟数据，用来体验 UI、图表和风险模型。

## 积灰风险算法

当前模型不再使用用户手动选择的“基线时间窗口”。它会尝试从历史原始样本中学习已经观察到的、稳定的最强散热能力，再把近期窗口和这个参考模型对比。

大致流程：

1. 按相近负载分桶，CPU 和 GPU 分开分析。
2. 在每个负载桶内，选取稳定低温片段作为已经观察到的最佳散热参考。
3. 如果有空闲样本，则比较“相对空闲温度的升温”，而不是直接比较绝对温度。这样可以减少房间温度变化造成的误判。
4. 使用 Mann-Whitney U 检验比较近期样本和参考样本的分布差异。
5. 同一负载下的风扇转速上升会作为辅助证据。
6. 只有当参考数据足够成熟，并且信号跨多个近期日期或多个负载桶相互印证时，才会给出清灰建议。

概览页里的风险等级会尽量保守：

- **样本不足**：DustWatch 需要更多历史数据。保持后台运行即可，采样负载很低。
- **无**：没有发现具有统计意义的散热能力下降。
- **轻微 / 观察中**：模型看到了信号，但证据还不足以建议清灰。
- **需要清灰**：模型发现了更强、更持续的散热能力下降信号。

这个算法仍然是实验性的。环境温度大幅变化、异常负载、传感器缺失或错误、散热垫变化、固件策略变化、历史数据太短，都可能造成误判。后续很值得改进的方向包括：更好的环境温度估计、模型置信度展示、更大的真实数据集、针对不同机型的参数调优。

## 数据和隐私

所有数据都保存在本机。DustWatch 没有遥测服务。

数据库路径：

```sh
~/Library/Application Support/DustWatch/data.db
```

数据库是标准 SQLite：

| 表 | 用途 | 保留策略 |
| --- | --- | --- |
| `samples` | 原始传感器样本 | 约一年加近期窗口 |
| `samples_hourly` | 小时聚合 | 最多一年 |
| `samples_daily` | 日聚合 | 长期保留 |
| `alerts` | 本地通知节流记录 | 长期保留 |
| `config` | 用户设置 | 单行 |

查看最近样本：

```sh
sqlite3 ~/Library/Application\ Support/DustWatch/data.db \
  "SELECT datetime(ts, 'unixepoch'), cpu_temp, gpu_temp, fan_max FROM samples ORDER BY ts DESC LIMIT 10;"
```

## 从源码构建

```sh
git clone https://github.com/NormanZyq/dust-watch-mac.git
cd dust-watch-mac
./build.sh
cp -R build/DustWatch.app /Applications/
```

常用命令：

```sh
swift test
./build.sh debug
./build.sh clean
./build.sh --arch arm64
./build.sh --arch x86_64
```

`build.sh` 会编译 Swift package，组装 `DustWatch.app`，复制 Info.plist、本地化资源、图标和 entitlements，并进行 ad-hoc 签名。

## 项目结构

```text
Sources/
  App/             App 入口和 AppDelegate
  SMC/             SMC 与系统传感器读取
  Sampler/         周期采样循环
  Storage/         SQLite schema、查询、聚合和迁移
  Analysis/        散热参考模型和积灰风险逻辑
  Notifications/   本地通知封装
  UI/              菜单栏、dashboard、图表、设置
  Resources/       Info.plist、entitlements、图标、本地化
Tests/             迁移和风险逻辑的 XCTest
build.sh           SwiftPM 构建、app bundle 组装、ad-hoc 签名
```

## 发布

推送 `v*` tag 会触发 GitHub Actions release workflow。它会构建 arm64 和 x86_64 两个 DMG，并发布 prerelease 和自动生成的 release notes。

```sh
git tag -a v0.x.y -m "v0.x.y"
git push origin main v0.x.y
```

## 参与改进

当前最有价值的贡献是验证和改进风险模型：

- 风险等级明显不符合实际情况的案例
- 区分积灰、环境温度变化和负载变化的新思路
- 更好的测试数据和模拟方式
- 特定 macOS 或硬件版本上的传感器读取修复
- 让风险解释更清晰的 UI 改进

反馈时请尽量附上 macOS 版本、Mac 型号、近期是否清过灰，以及足够的负载背景，这会让热状态变化更容易解释。

## 许可证

MIT。见 [LICENSE](LICENSE)。

## 致谢

SMC 读取层采用了和 SMCKit、smcFanControl 这类工具相近的社区文档化思路。Apple 没有为这个场景提供稳定的公开 SMC API，所以这部分可能需要持续维护。
