# Acode ACP 智能体功能开发计划

## 1. 背景与目标

参考 Acode issue 1651，ACP 集成应当作为 Acode 内建能力实现，而不是继续以外部插件方式拼装。issue 当前的明确信息有两点：

- ACP 集成目标已经确定，但目前几乎没有现成实现可复用。
- CodeMirror 迁移的意义在于为后续能力提供稳定基础，而不是 ACP 本身已经开始落地。

基于这一背景，本计划的目标是为 Acode 增加一套内建的智能体系统，使其能够：

- 与用户进行多轮聊天。
- 查阅和修改当前工作区文件。
- 调用终端执行命令。
- 调用 MCP 服务。
- 接入多家主流模型提供商。
- 通过统一的 ACP 中间层向上层 UI 和业务逻辑提供一致能力。
- 允许用户对文件查阅、文件编辑、MCP、终端等高风险操作选择手动批准或自动批准。

该能力应优先服务移动端本地工作流，强调可控、可审计、可中断，不追求桌面 IDE 那种无限权限模型。

## 2. 范围定义

### 2.1 本期必须覆盖

- 内建聊天面板与会话状态管理。
- 基于 ACP 的统一 Agent Runtime。
- 工作区文件读取、差异编辑、保存与回滚入口。
- 终端工具调用入口。
- MCP 客户端与服务注册机制。
- 提供商适配层：
  - GitHub Copilot
  - OpenAI
  - Google
  - Anthropic
  - 豆包
  - Kimi
  - 千问
- 权限审批系统：手动批准 / 自动批准。

### 2.2 本期不做

- 复杂协作能力，例如多智能体编排、共享会话、云同步。
- 服务端代理作为必选项。
- 桌面端专属能力移植。
- 放任智能体无限制访问系统资源。

## 3. 总体架构

整体采用五层结构。

### 3.1 UI 层

- 聊天页面
- 会话列表
- 权限审批弹窗与审批历史
- 工具调用实时状态展示
- 文件差异确认视图
- 终端执行确认视图

### 3.2 Agent Session 层

负责管理一次会话中的：

- 对话历史
- 当前工作区上下文
- 活动模型与提供商
- 可用工具集
- 审批策略
- MCP 服务列表
- 执行中的任务状态

### 3.3 ACP Runtime 层

这是本次设计的核心。应用层不直接依赖具体模型厂商 SDK，而是统一依赖 ACP Runtime。

ACP Runtime 对上提供统一接口：

- `createSession`
- `sendMessage`
- `cancelRun`
- `listTools`
- `invokeTool`
- `listProviders`
- `switchProvider`
- `listMcpServers`
- `attachMcpServer`

ACP Runtime 对下分两类实现：

- 原生 ACP 兼容提供商或代理，直接接入 ACP。
- 非 ACP 原生提供商，通过 Acode 内建 Adapter 适配到统一 ACP 抽象。

结论上，ACP 是应用层唯一依赖的中间层，不允许 UI 直接调用 OpenAI/Copilot/Anthropic 等私有接口。

### 3.4 Tooling 层

对智能体开放的能力统一封装成工具：

- Workspace Read Tool
- Workspace Edit Tool
- Search Tool
- Terminal Tool
- MCP Tool Bridge
- Diagnostics Tool
- Diff Preview Tool

所有工具都必须先经过权限门控，再真正执行。

### 3.5 Provider Adapter 层

每个提供商单独一个 Adapter，统一输出为 ACP Runtime 可消费的能力描述：

- 模型列表
- 消息发送
- 流式输出
- 工具调用格式
- 认证方式
- 限流与错误码归一化

## 4. GitHub Copilot 特殊适配方案

GitHub Copilot 不能按普通 OpenAI 兼容 API 处理，必须单独设计 Adapter。

根据参考文件：

- `C:\Users\vhtmf\Desktop\video_transcript\test_copilot_api.py`
- `C:\Users\vhtmf\Desktop\video_transcript\polish.py`

可确定 Copilot 接入至少包含以下链路：

### 4.1 认证流程

- 使用 GitHub Device Code Flow 获取 OAuth token。
- 缓存 OAuth token，避免重复登录。
- 使用 `https://api.github.com/copilot_internal/v2/token` 交换短期 Copilot session token。
- 使用 Copilot session token 访问：
  - `https://api.githubcopilot.com/models`
  - `https://api.githubcopilot.com/chat/completions`

### 4.2 必须抽象的 Copilot 特性

- `Copilot-Integration-Id` 请求头管理。
- 模型列表动态拉取，而不是写死模型名。
- session token 自动刷新。
- OAuth token 本地安全缓存。

### 4.3 Acode 中的实现要求

- 单独的 `CopilotProviderAdapter`。
- 首次使用时引导用户完成 Device Code 授权。
- 将 OAuth token 与 Copilot session token 分离存储。
- 对上仍然暴露 ACP 风格的统一消息接口，不把 Copilot 私有接口泄漏到 UI 层。

## 5. 提供商支持策略

### 5.1 首批支持提供商

- GitHub Copilot
- OpenAI
- Google
- Anthropic
- 豆包
- Kimi
- 千问

### 5.2 统一接入原则

- 每个提供商都映射为统一的 Provider Descriptor。
- 对 UI 暴露统一字段：
  - `providerId`
  - `displayName`
  - `models`
  - `authType`
  - `supportsTools`
  - `supportsStreaming`
  - `supportsMcp`
- 统一错误分类：
  - 认证失败
  - 限流
  - 网络错误
  - 模型不可用
  - 工具调用协议错误

### 5.3 认证形态

- API Key
- OAuth Device Flow
- 第三方 Access Token

密钥和令牌必须放入 Acode 安全存储层，不允许散落在普通设置 JSON 中明文保存。

## 6. 工作区文件能力设计

智能体必须能查阅和修改工作区文件，但执行模型必须严格约束。

### 6.1 文件查阅能力

需要支持：

- 读取单个文件内容
- 指定行范围读取
- 目录列举
- 文本搜索
- 语义搜索预留接口

### 6.2 文件修改能力

文件修改不允许直接无差异覆盖，应优先采用结构化编辑模型：

- `createFile`
- `deleteFile`
- `renameFile`
- `applyPatch`
- `replaceRange`

### 6.3 审批与可视化

所有修改必须先生成差异预览，再根据审批策略执行：

- 手动批准：用户确认后执行。
- 自动批准：满足当前会话策略时直接执行，但仍记录审计日志。

### 6.4 失败策略

- 编辑失败立即停止，不做静默 fallback。
- 无法应用 patch 时必须向用户展示原因。
- 需要用户介入时保留完整 diff 与错误上下文。

## 7. MCP 集成设计

### 7.1 目标

允许 Acode 现有插件商店向智能体添加 MCP 服务。

### 7.2 设计原则

- MCP Server 由插件声明和注册。
- Acode 内建 MCP Client Runtime。
- 每个 MCP 服务都要被映射为 ACP Runtime 中的工具源。

### 7.3 插件商店扩展方案

为插件元数据新增 MCP 声明能力，例如：

- server 类型
- 启动方式
- transport 类型
- 权限需求
- 暴露工具列表

插件安装后，Acode 应可：

- 发现该 MCP 服务
- 启停该服务
- 将其挂接到某个智能体会话
- 在审批系统中区分“内建工具调用”和“MCP 外部工具调用”

### 7.4 MCP 安全要求

- MCP 服务默认不开启，需用户显式启用。
- 每个 MCP 服务独立权限开关。
- 外部 MCP 服务调用必须可审计。
- 插件卸载时自动解除 MCP 注册。

## 8. 终端能力设计

### 8.1 目标

允许智能体调用终端执行命令。

### 8.2 设计要求

- 与现有 Acode terminal 能力集成，而不是旁路再造一套 shell。
- 支持：
  - 前台短命令执行
  - 后台长任务执行
  - 获取输出
  - 中止执行

### 8.3 必须暴露的工具接口

- `runCommand`
- `readCommandOutput`
- `killCommand`
- `listRunningCommands`

### 8.4 安全门控

终端调用必须单独审批，且默认高风险：

- 手动批准模式下，每次命令执行都确认。
- 自动批准模式下，允许限定白名单目录与命令类型。
- 涉及包管理、删除、覆盖写入、权限提升的命令默认提升为高风险确认。

## 9. 审批系统设计

用户要求支持手动或自动批准以下请求：

- 文件查阅
- 文件编辑
- MCP
- 终端

因此审批系统需要统一化，而不是每个功能各做一套弹窗。

### 9.1 审批维度

- 按能力类型审批
- 按会话审批
- 按工作区审批
- 按提供商审批
- 按 MCP 服务审批

### 9.2 建议策略模型

- 严格模式
  - 文件读：手动
  - 文件写：手动
  - MCP：手动
  - 终端：手动
- 平衡模式
  - 文件读：自动
  - 文件写：手动
  - MCP：手动
  - 终端：手动
- 高信任模式
  - 文件读：自动
  - 文件写：自动
  - MCP：自动
  - 终端：自动

### 9.3 审批 UI 要求

- 明确展示操作类型、目标对象、调用来源、影响范围。
- 文件编辑展示 diff。
- 终端展示命令全文和工作目录。
- MCP 展示 server 名称和 tool 名称。
- 支持“仅本次允许”“本会话允许”“本工作区允许”。

## 10. 会话与上下文管理

### 10.1 会话对象

每个会话至少维护：

- provider
- model
- workspaceRoot
- conversationHistory
- toolState
- permissionProfile
- attachedMcpServers
- pendingActions

### 10.2 上下文拼装策略

移动端上下文窗口有限，不能简单把整个工作区塞给模型。建议：

- 当前打开文件优先
- 当前选中文本优先
- 最近访问文件其次
- 搜索结果按需补充
- 长文件按分块读取

### 10.3 审计日志

每次工具调用都记录：

- 发起时间
- 会话 ID
- 提供商 / 模型
- 工具名
- 参数摘要
- 审批结果
- 执行结果

## 11. 推荐模块拆分

建议在 Acode 中新增以下模块：

- `src/ai/runtime/`
  - ACP Runtime
  - Session 管理
  - Tool Registry
- `src/ai/providers/`
  - Copilot
  - OpenAI
  - Google
  - Anthropic
  - 豆包
  - Kimi
  - 千问
- `src/ai/mcp/`
  - MCP Client
  - MCP Registry
  - MCP Plugin Bridge
- `src/ai/tools/`
  - workspaceRead
  - workspaceEdit
  - terminal
  - search
  - diagnostics
- `src/ai/ui/`
  - chat panel
  - approval dialog
  - diff preview
  - provider settings

## 12. 分阶段开发计划

### Phase 0：技术预研

目标：把协议和能力边界彻底确认。

输出：

- ACP Runtime 抽象草案
- Provider Adapter 接口草案
- MCP 接入元数据草案
- 审批模型草案
- Copilot 认证与调用 PoC

验收标准：

- 能明确 GitHub Copilot 接入链路。
- 能明确 ACP 与 MCP 在系统中的边界。
- 能明确文件 / 终端权限模型。

### Phase 1：最小可用聊天能力

目标：先做单会话聊天，不开放高风险工具。

范围：

- 聊天 UI
- Provider 设置页
- OpenAI / Anthropic / Copilot 三家优先打通
- 基础流式回复

验收标准：

- 用户可选择 provider/model 并正常对话。
- Copilot 完成设备码登录与模型调用。

### Phase 2：工作区只读能力

目标：让智能体能读文件、列目录、搜索，但不能写。

范围：

- 文件读取工具
- 目录浏览工具
- 文本搜索工具
- 审批系统 v1

验收标准：

- 智能体能基于工作区内容回答问题。
- 所有读取行为都经过审批或自动批准策略。

### Phase 3：工作区编辑能力

目标：支持差异编辑与用户确认。

范围：

- patch 应用
- diff 预览
- 回滚入口
- 审计记录

验收标准：

- 智能体能修改文件。
- 用户可在手动模式下逐次批准。
- 自动模式下仍保留完整审计记录。

### Phase 4：终端能力

目标：让智能体可以安全地运行命令。

范围：

- 终端工具接入
- 前后台任务管理
- 输出回传
- 命令审批 UI

验收标准：

- 智能体可执行终端命令并读取输出。
- 长任务可终止。
- 高风险命令默认阻断或强确认。

### Phase 5：MCP 集成

目标：让插件商店扩展智能体能力边界。

范围：

- MCP Client Runtime
- MCP Server 注册机制
- 插件元数据扩展
- MCP 审批模型

验收标准：

- 插件可声明并注册 MCP 服务。
- 智能体会话可动态挂接 MCP 工具。
- MCP 工具调用可被审批与审计。

### Phase 6：全提供商与稳定化

目标：扩展到全部目标提供商并做稳定性打磨。

范围：

- Google / 豆包 / Kimi / 千问 Adapter
- 统一重试与错误提示
- 性能优化
- UX 优化

验收标准：

- 所有目标提供商至少完成基础聊天能力。
- 常见失败路径均有清晰错误提示。

## 13. 风险与对策

### 13.1 ACP 标准与现实 API 不完全一致

风险：不同提供商实际能力差异很大。

对策：

- ACP 作为应用内抽象，不强求所有厂商原生兼容。
- Adapter 层做归一化，不把差异推给 UI。

### 13.2 Copilot 接入不稳定

风险：GitHub 私有接口、token 生命周期、请求头要求都更特殊。

对策：

- 单独实现 Copilot Adapter。
- 首先完成 PoC，再进入主干开发。

### 13.3 MCP 带来外部执行风险

风险：插件可把任意外部能力暴露给智能体。

对策：

- MCP 默认关闭。
- 每个服务独立审批与审计。
- 严禁隐式自动启用。

### 13.4 文件与终端能力过强

风险：智能体误操作带来不可逆后果。

对策：

- 默认手动批准。
- 文件写入一律差异预览。
- 终端命令展示全文与目录。
- 支持取消与中止。

## 14. 首批实现优先级建议

建议优先顺序如下：

1. Copilot / OpenAI / Anthropic 聊天 PoC
2. ACP Runtime 最小骨架
3. 只读工作区工具
4. 审批系统 v1
5. 文件差异编辑
6. 终端工具
7. MCP 注册与桥接
8. 其它提供商扩展

## 15. 交付物清单

实现完成后至少应交付：

- 内建聊天 UI
- ACP Runtime 与 Provider Adapter 框架
- Copilot 特殊适配实现
- 多提供商设置界面
- 工作区读写工具
- 终端工具
- MCP Client 与插件注册机制
- 审批系统与审计日志
- 开发者文档与插件接入文档

## 16. 结论

这项功能应被视为 Acode 下一阶段的核心能力建设，而不是单独的聊天插件增强。

技术上最关键的设计选择有三点：

- ACP 作为应用层唯一中间层。
- GitHub Copilot 走独立适配，不按普通厂商处理。
- 文件、MCP、终端全部纳入统一审批系统。

如果按本计划推进，最合理的落地路径是先做内建聊天和三家核心提供商，再逐步扩展到文件编辑、终端和 MCP，最终把插件生态和智能体能力统一到同一套运行时之下。