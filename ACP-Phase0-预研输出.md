# ACP Phase 0 预研输出

## 1. 输出清单

本轮 Phase 0 已实际落下以下交付物：

- Acode 内部 AI 运行时草案接口：`Acode/src/ai/types.ts`
- MCP 插件元数据 JSON Schema 草案：`Acode/src/ai/mcp-manifest.schema.json`
- GitHub Copilot 接入 PoC：`scripts/copilot_api_poc.py`
- 本文档：Phase 0 结论与下一步实现建议

## 2. 核心结论

### 2.1 ACP Runtime 必须是应用层唯一入口

UI、聊天页面、设置页、审批系统都不应直接依赖任何厂商 API。应用层只应依赖统一的 Runtime 接口，原因如下：

- 不同提供商的认证方式不同。
- 不同提供商的模型枚举与工具调用格式不同。
- GitHub Copilot 明确不是普通 OpenAI 兼容路径。

因此 Phase 1 不应从“先做一个 ChatGPT 页面”开始，而应从 Runtime 和 Session 骨架开始。

### 2.2 GitHub Copilot 必须是独立 Adapter

PoC 已按独立脚本方式落地，验证的链路是：

- GitHub Device Code Flow
- OAuth token 缓存
- `copilot_internal/v2/token` 交换短期 session token
- `api.githubcopilot.com/models` 动态模型发现
- `api.githubcopilot.com/chat/completions` 聊天调用

这条链路与 OpenAI / Anthropic 的 API Key 模式完全不同，因此不能尝试用一个“OpenAI 兼容 Provider”兼容 Copilot。

### 2.3 MCP 应作为插件商店的扩展能力，而不是单独系统

本次给出的 MCP manifest schema 采用插件声明式注册模型，目标是：

- 插件安装即带出 MCP Server 描述
- Acode 可发现、启停、挂接 MCP 服务
- MCP 最终在 ACP Runtime 中表现为一组工具

这意味着后续 Phase 5 的实现重点不是“支持 MCP 协议”本身，而是“把插件生态和 MCP 统一到同一注册中心”。

### 2.4 审批系统必须统一建模

Phase 0 已把审批相关对象纳入 `types.ts`：

- `ApprovalRule`
- `ApprovalDecision`
- `ApprovalTarget`
- `ApprovalScope`

这意味着后续文件读取、文件编辑、终端、MCP 都不应各自维护独立开关，而应共享同一套审批框架。

## 3. 对 Phase 1 的直接建议

Phase 1 建议只做最小闭环，不一次性把所有能力塞进主线：

1. 在 `Acode/src/ai/` 下补出 Runtime 骨架实现文件。
2. 先接三家 Provider：Copilot、OpenAI、Anthropic。
3. 先只支持聊天，不开放文件写、终端、MCP。
4. 审批系统只先支持“是否允许会话读取工作区上下文”。

## 4. 建议的 Phase 1 文件骨架

建议下一阶段新增：

- `Acode/src/ai/runtime/runtime.js`
- `Acode/src/ai/runtime/sessionStore.js`
- `Acode/src/ai/providers/copilotAdapter.js`
- `Acode/src/ai/providers/openaiAdapter.js`
- `Acode/src/ai/providers/anthropicAdapter.js`
- `Acode/src/ai/ui/chatPage.js`
- `Acode/src/ai/ui/providerSettings.js`

## 5. 风险前置结论

### 5.1 不建议 Phase 1 就开放自动文件编辑

原因：移动端 UI 上差异确认、批量编辑、回滚体验还没有打底，过早开放会导致权限模型和失败路径一起爆炸。

### 5.2 不建议 Phase 1 就开放终端自动批准

原因：终端能力风险明显高于文件读取，且当前 Acode terminal 还存在运行模式差异，需要单独梳理工具边界。

### 5.3 不建议 Phase 1 就把所有提供商一起接完

原因：提供商越多，越难先稳定 Runtime 抽象。先做三家可以更快暴露接口设计问题。

## 6. 验收建议

Phase 0 的验收点现在可以明确为：

- Runtime 抽象已形成可落地接口草案。
- Provider Adapter 接口已具体化到代码类型。
- MCP 注册元数据已具体化到 schema。
- 审批模型已具体化到统一对象模型。
- Copilot 特殊认证与聊天链路已有独立 PoC。

以上五点已经完成，可进入 Phase 1。