<p align="center">
  <b>简体中文</b> · <a href="README.en.md">English</a>
</p>

# MyType

**让口述接上桌面 Agent 的工作流。**

MyType 是一个以语音为入口的 macOS 个人 Agent 交互项目。我基于 [Type4Me](https://github.com/joewongjc/type4me) 的语音输入与文字处理能力，扩展了桌面 Agent 会话检索、任务路由、上下文交接和统一 Inbox，探索从表达想法到继续推进工作的完整过程。

[了解工作流](#从一句口述到继续一项工作) · [看关键实现](#我做了哪些关键设计) · [从源码使用](#从源码使用)

## 为什么做

使用多个桌面 Agent 时，一个想法往往还要经过找旧对话、核对项目、补充背景、交接任务和检查结果，才能继续推进。工作分散在不同窗口和会话里，表达与执行之间有不少手动衔接。

我希望以正在处理的事情为中心组织入口：用户说出事项或下一步要求，系统帮助找回对应工作，准备交接或新任务，再把反馈带回可继续处理的位置。

因此，MyType 保留日常语音输入，同时把开发重点放在输入之后的任务衔接。

## 从一句口述到继续一项工作

在 Agent 专用入口中，口述先进入操作意图判断，再进入对应的工作流程：

```text
口述事项
  ├─ 找回工作 → 检索候选 → 确认并打开原会话
  ├─ 新建任务 → 确认项目 → 进入新的 Agent 任务
  └─ 交接工作 → 选择来源与接收方 → 预览上下文并投递
                                      ↓
                           Inbox 汇集反馈与待处理请求
                                      ↓
                                回到原会话继续
```

| 用户要做的事 | MyType 怎样承接 |
| --- | --- |
| 找回之前的工作 | 用事项、项目或内容描述检索历史会话，保留应用来源，并定位到桌面原会话。 |
| 开始一项新任务 | 识别明确的新建意图，先让用户确认项目，再准备新的 Agent 任务。 |
| 把背景交给另一个 Agent | 选择来源和接收会话，组织可见历史与后续要求，经原生接口交接。 |
| 处理 Agent 的反馈 | 在统一 Inbox 查看完成反馈、等待输入及待处理请求，回到对应会话继续工作。 |

当前公开实现围绕 **Codex 与 Claude** 两类桌面 Agent 展开。任务由对应 Agent 执行，MyType 负责入口、工作定位、交接与反馈衔接。

## 我做了哪些关键设计

### 1. 先判断用户要怎样推进工作

同一句口述可能是在找旧任务、建立新任务，或要求转交已有上下文。我将这些操作分开处理，使事项描述不会轻易变成新任务，交接也有明确的来源、接收方与确认步骤。

实现包括意图分类、事项查询、候选选择、新任务准备及交接窗口。

[意图分类](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentIntentClassifier.swift) · [任务路由](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentRouterService.swift) · [新任务服务](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentNewTaskService.swift)

### 2. 找到历史内容之后，还要回到正确的会话

检索结果需要关联具体的工作现场。我将事项匹配与原生会话目录结合：以 **Qwen3-Embedding** 支持语义匹配，通过 AgentsView 检索历史内容，再将结果映射到 Codex / Claude 的会话身份与导航能力。

候选匹配、原会话定位和请求打开分别记录状态；内容命中但无法定位时，也保留明确的反馈。

[会话目录](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentSessionCatalog.swift) · [索引服务](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentIndexService.swift) · [Embedding 服务](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentEmbeddingService.swift)

### 3. 让交接和反馈共享同一个任务身份

上下文交接包含所选来源的可见历史、接收会话和用户的下一步要求。MyType 分别接入 **Codex queue** 与 **Claude inbox** 原生路径，并处理接收方不可用、身份歧义及投递失败等状态。

Inbox 延续相同的应用与会话身份，区分完成消息、等待输入和待处理请求，使收到反馈后仍能回到对应工作。投递状态与 Agent 的任务完成反馈分别呈现。

[原生交接](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentHandoffDeliveryService.swift) · [消息来源监听](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentNotificationService.swift) · [Inbox 状态](https://github.com/duroey/MyType/blob/main/Type4Me/Services/AgentInboxStore.swift)

## 当前结果与迭代方向

公开代码已将语音入口、两类 Agent 的会话检索、任务路由、原生交接、新任务与 Inbox 组织为一套工作流程。

这是一个持续迭代的个人研发项目。当前成果以可查的实现与工作链路为主，端到端体验仍随桌面 Agent 的版本和原生接口持续验证。

本地研发还在探索更多 Agent 接入、连续录音与上下文绑定，以及低打扰的多模态、全双工交互。这些进展与当前公开版本分别管理。

## 从源码使用

1. 准备 **macOS 14 及以上**和 Xcode Command Line Tools。
2. 按 [CONTRIBUTING.md](CONTRIBUTING.md) 构建与配置 MyType；本地 ASR 的可选依赖也在其中说明。
3. 配置需要使用的语音识别、大模型或本地模型服务。
4. Agent 历史检索需要 **AgentsView 后端及相应许可证**；按构建说明配置后，在设置中授权读取本机会话。
5. 保持对应的 Codex / Claude 环境可用，在 Agent 入口中找回、新建或交接工作。

本仓库当前以源码构建方式提供 MyType。上游 Type4Me 的安装包与演示展示其基础产品，不包含 MyType 的 Agent 扩展。

<details>
<summary><b>保留的基础语音与文字处理能力</b></summary>

MyType 沿用 Type4Me 的输入基座，包括：

- 本地与云端语音识别，以及识别服务配置。
- 文字润色、翻译、语音提问、自定义 Prompt 和手动输入。
- 热词、片段替换、历史记录与用量管理。
- 可配置快捷键和菜单栏入口。

使用方式见 [模式与功能详解](docs/usage/modes.md) 和 [URL Scheme 命令参考](docs/usage/url-scheme.md)。

</details>

## 项目来源与个人贡献

[Type4Me](https://github.com/joewongjc/type4me) 提供语音识别、文字处理及原有界面基础。我的工作围绕桌面 Agent 的会话检索、任务路由、原生交接、新任务和反馈入口展开，并通过自用问题定位与迭代推进系统衔接。

MyType 保留独立的应用身份、数据与配置边界。上游文档和界面素材保留其来源，不能作为 MyType 新增能力的演示或使用效果。

开发与使用文档：[构建与贡献](CONTRIBUTING.md) · [文档中心](docs/README.md) · [开发指南](AGENTS.md)

感谢 [SenseVoice](https://github.com/FunAudioLLM/SenseVoice)、[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)、[Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) 及其他基础组件；完整来源见[第三方声明](Type4Me/Resources/THIRD_PARTY_LICENSES.txt)。

## 许可证

MyType 采用[专有商业授权声明](LICENSE)，有权按新条款授权的原创新增部分须另行取得授权。
上游 Type4Me 继续适用 [MIT 许可证](Type4Me/Resources/ThirdPartyNotices/Type4Me-LICENSE)，其他组件保留各自许可；参见[第三方声明](Type4Me/Resources/THIRD_PARTY_LICENSES.txt)。
已经按 MIT 或其他许可证授出的旧版及相关内容，其既有权利不受本次调整影响。
