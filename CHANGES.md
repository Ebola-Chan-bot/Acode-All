# Acode 保留的更改汇总

> 基准: `78205d99aa1d81a38b0ae185c091d5a9d8f90f0a`
>
> 已放弃: 所有调试日志相关更改 (HDC debug client/server, 报错.txt, pty_test, deploy.ps1 大改, .gitignore logs 规则)

---

## 一、终端核心组件

### 1. `src/components/terminal/terminal.js` (+218/--)

- **字体回退**: fontFamily 改为 `"xxx", monospace` 格式，避免自定义字体缺失时无法显示
- **智能 resize**: 新增 `setupResizeHandling()` 方法，100ms 防抖，检测键盘弹出（高度比变化）时自动调整光标可见性并保留滚动位置
- **acode CLI 集成**: 新增 OSC 7777 协议处理器，支持 `open-file`/`open-folder` 命令从终端直接打开文件
- **触摸选择**: 为移动端添加了完整的触摸文本选择支持
- **事件处理**: 新增终端标题变更、bell 事件处理

### 2. `src/components/terminal/terminalDefaults.js` (+8/--)

- 新增 `DEFAULT_TERMINAL_SETTINGS` 集中配置：默认字体 MesloLGS NF Regular，触摸选择参数 (tapHoldDuration/moveThreshold/handleSize/hapticFeedback)，imageSupport，fontLigatures 等
- 新增 `getTerminalSettings()` 函数，合并用户设置与默认值，校验 letterSpacing 范围 (0-2)

### 3. `src/components/terminal/terminalManager.js` (+108/--)

- **会话持久化**: 新增 `getPersistedSessions()` / `savePersistedSessions()` / `persistTerminalSession()` 方法，将终端会话保存到 localStorage
- **崩溃恢复**: 新增 `restorePersistedSessions()` 方法，应用重启时自动恢复之前的终端会话，恢复失败时弹出提示
- **编号管理**: 新增 `extractTerminalNumber()` 和 `getNextAvailableTerminalNumber()` 管理终端编号

### 4. `src/settings/terminalSettings.js` (+26/--)

- 集成终端设置 UI：fontSize (8-32px)、fontFamily 选择、theme 选择、cursorStyle/cursorInactiveStyle、fontWeight 等可视化配置项

---

## 二、终端插件 (Native + JS)

### 5. `src/plugins/terminal/src/android/Executor.java` (新增文件, +135)

- 终端执行核心插件：实现与 Android Service 的绑定、Messenger IPC、基于 Latch 的同步等待 (10s 超时)
- 提供 `nativeLog()` 静态方法，通过 HTTP POST 向调试服务器发送日志
- 处理 Android 13+ POST_NOTIFICATIONS 权限请求

### 6. `src/plugins/terminal/src/android/BackgroundExecutor.java` (+89/--)

- 后台进程管理：`start()` 使用 UUID 跟踪进程并实时流式传输 stdout/stderr，`write()` 向 stdin 写入，`stop()` 终止进程
- 集成 `Executor.nativeLog()` 实现安装/执行阶段的后台错误上报

### 7. `src/plugins/terminal/www/Executor.js` (新增文件, +18)

- Native Executor/BackgroundExecutor 的 JavaScript 接口
- 提供 `start()`、`write()`、`stop()`、`execute()`、`moveToBackground()`/`moveToForeground()` 异步方法

### 8. `src/plugins/terminal/www/Terminal.js` (+380/--)

- **多阶段安装**: Phase 1 下载 Alpine tar + axs 二进制 (支持增量下载, 使用 marker 文件)，Phase 2 解压文件系统并显示进度
- **AXS 运行模式**: 新增 `_axsMode` 追踪 (inside-proot / outside-proot)，网络不可达时自动回退到 outside-proot 模式
- **崩溃恢复**: 通过 `.configured`/`.downloaded`/`.extracted` marker 文件追踪安装状态，异常中断可续装
- **设备 IP 获取**: 新增 `getDeviceIp()` 方法，兼容 HarmonyOS (`ip route` + `hostname -I` 双重获取)
- **状态检测**: 新增 `isAxsRunning()` 方法，使用 `kill -0` 回退检查

### 9. `src/plugins/terminal/scripts/init-alpine.sh` (+264/--)

- 包验证改用文件存在性检查（替代不可靠的 `apk info`）
- 新增清华镜像回退，主镜像失败时自动切换
- 新增时区配置 (`$ANDROID_TZ`)
- `.configured` marker 改由 JS 层创建，避免 proot bind-mount 与 Java mkdirs() 冲突

### 10. `src/plugins/terminal/scripts/init-sandbox.sh` (+38/--)

- 显式加载 `libproot.so` / `libproot32.so` 支持 F-Droid 构建
- 处理 `libtalloc.so.2` 符号链接
- 移除 `--sysvipc` 参数避免 Huawei/HarmonyOS、Samsung Knox 等严格 seccomp 内核上的 Bus Error
- 新增 `--setup-only` 模式，允许调用方在 proot 外部启动 AXS

---

## 三、系统插件

### 11. `src/plugins/system/android/com/foxdebug/system/System.java` (+20)

- 新增全局未捕获异常处理器，捕获任意线程的未捕获异常并通过 `sendLogToJavaScript()` 发送到 JS 层
- 新增 `sendLogToJavaScript(level, message)` 辅助方法，注入 JS 调用 `window.log()`

### 12. `src/plugins/system/www/plugin.js` (+55/--)

- 新增 `copyAsset(assetName, destPath)` 方法
- inAppBrowser 回调代码缩进重格式化（无功能变化）

---

## 四、认证

### 13. `src/lib/auth.js` (-1)

- `isLoggedIn()` 的 catch 块移除了 `console.error(error)` 调用，未登录状态码 (0/401) 不再作为错误输出

---

## 五、依赖

### 14. `package.json` / `package-lock.json` (+32/--)

- `cordova-plugin-file` 移除了 `ANDROIDX_WEBKIT_VERSION` 配置项
- 相关 lock 文件同步更新
