<#
.SYNOPSIS
  一键构建部署脚本 - 将 acodex-server 嵌入 Acode 并构建 APK 部署到手机

.DESCRIPTION
  自动化完整构建流程：
  1. 初始化 Git 子模块（Acode + acodex-server），竞速克隆自动选最快线路
  2. 检测/配置构建环境（JDK, Android SDK, NDK, Rust, Node.js）
  3. 安装 Node.js 依赖并设置 Cordova 平台
  4. 交叉编译 acodex-server → Android aarch64 二进制（axs）
  5. 构建前端资源（rspack）+ 同步到平台目录
  6. 嵌入 axs 二进制并构建 debug APK
  7. 通过 ADB 或 HDC 安装到手机

.PARAMETER 动作
  执行的动作（默认 full）：
    full         = 完整流程（首次使用推荐）
    setup        = 仅初始化环境和依赖
    build-server = 仅编译 acodex-server
    build-apk    = 仅构建 APK（跳过 Rust 编译）
    deploy       = 仅推送已构建的 APK 到手机
    clean        = 清理构建产物

.PARAMETER 设备模式
  设备连接方式: adb | hdc（默认 adb）

.PARAMETER 构建模式
  构建模式: debug | release（默认 debug）

.PARAMETER 应用类型
  应用类型: paid | free（默认 paid）

.PARAMETER NDK接口级别
  NDK 编译使用的最低 Android API 等级（默认 21）

.PARAMETER 启用调试客户端
    是否向构建产物注入局域网调试客户端脚本（默认关闭）

.EXAMPLE
  .\构建部署.ps1                               # 完整流程
  .\构建部署.ps1 -动作 setup                  # 仅初始化环境
  .\构建部署.ps1 -动作 build-server           # 仅编译 acodex-server
  .\构建部署.ps1 -动作 build-apk              # 仅构建 APK
  .\构建部署.ps1 -动作 deploy                 # 仅推送 APK
  .\构建部署.ps1 -设备模式 hdc                # 使用 HDC 连接华为设备
  .\构建部署.ps1 -构建模式 release            # 构建 release 版
    .\构建部署.ps1 -动作 build-apk -启用调试客户端 # 构建带调试服务器注入的 debug 包
  .\构建部署.ps1 -动作 clean                  # 清理构建产物
#>

param(
    [ValidateSet("full", "setup", "build-server", "build-apk", "deploy", "clean")]
    [string]$动作 = "full",

    [ValidateSet("adb", "hdc")]
    [string]$设备模式 = "adb",

    [ValidateSet("debug", "release")]
    [string]$构建模式 = "debug",

    [ValidateSet("paid", "free")]
    [string]$应用类型 = "paid",

    [switch]$启用调试客户端,

    [int]$NDK接口级别 = 28
)

$ErrorActionPreference = "Continue"

# ─── 路径配置 ─────────────────────────────────────────────────────────
$工作区根目录     = Resolve-Path (Join-Path $PSScriptRoot "..")
$Acode根目录      = Join-Path $工作区根目录 "Acode"
$Acodex根目录     = Join-Path $工作区根目录 "acodex-server"
$平台根目录       = Join-Path $Acode根目录 "platforms/android"
$平台Assets目录   = Join-Path $平台根目录 "app/src/main/assets"
$平台AssetsWww    = Join-Path $平台Assets目录 "www"
$Gradlew路径      = Join-Path $平台根目录 "gradlew.bat"
$调试APK输出目录  = Join-Path $平台根目录 "app/build/outputs/apk/debug"
$发布APK输出目录  = Join-Path $平台根目录 "app/build/outputs/apk/release"
$配置XML路径      = Join-Path $Acode根目录 "config.xml"
$Www目录          = Join-Path $Acode根目录 "www"
$HDC程序路径      = "C:\Program Files (x86)\HiSuite\hwtools\hdc.exe"

# ─── 工具函数 ─────────────────────────────────────────────────────────
function 输出步骤($消息) { Write-Host "`n▶ $消息" -ForegroundColor Cyan }
function 输出成功($消息) { Write-Host "  ✓ $消息" -ForegroundColor Green }
function 输出警告($消息) { Write-Host "  ⚠ $消息" -ForegroundColor Yellow }
function 输出错误($消息) { Write-Host "  ✗ $消息" -ForegroundColor Red }

function 检查命令($命令, $提示) {
    if (-not (Get-Command $命令 -ErrorAction SilentlyContinue)) {
        输出错误 "找不到 '$命令'，$提示"
        exit 1
    }
}

function 获取应用信息 {
    if (-not (Test-Path $配置XML路径)) {
        return @{ 名称 = "app-debug"; 版本 = "0.0.0" }
    }
    [xml]$配置文档 = Get-Content $配置XML路径 -Encoding UTF8
    $名称 = $配置文档.widget.name
    $版本 = $配置文档.widget.version
    if ([string]::IsNullOrWhiteSpace($名称)) { $名称 = "app-debug" }
    if ([string]::IsNullOrWhiteSpace($版本)) { $版本 = "0.0.0" }
    return @{ 名称 = $名称; 版本 = $版本 }
}

# ─── 环境检测与自动配置 ───────────────────────────────────────────────
function 初始化构建环境 {
    输出步骤 "检测构建环境"

    检查命令 "git" "请安装 Git: https://git-scm.com/"
    输出成功 "Git: $(git --version)"

    检查命令 "node" "请安装 Node.js: https://nodejs.org/"
    输出成功 "Node.js: $(node --version)"

    检查命令 "npm" "请安装 npm（随 Node.js 安装）"
    输出成功 "npm: $(npm --version)"

    # JAVA_HOME 自动检测
    if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin/javac.exe'))) {
        $JDK候选目录 = @(
            'C:\Program Files\Android\openjdk',
            'C:\Program Files\Java',
            'C:\Program Files\Eclipse Adoptium',
            'C:\Program Files\Microsoft\jdk*',
            "$env:USERPROFILE\.gradle\jdks"
        )
        $Javac路径 = Get-ChildItem -Path $JDK候选目录 -Filter javac.exe -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($Javac路径) {
            $env:JAVA_HOME = (Split-Path (Split-Path $Javac路径.FullName))
            输出成功 "自动检测 JAVA_HOME: $env:JAVA_HOME"
        } else {
            输出错误 "找不到 JDK，请安装 JDK 17+ 或设置 JAVA_HOME"
            输出错误 "推荐: https://adoptium.net/"
            exit 1
        }
    } else {
        输出成功 "JAVA_HOME: $env:JAVA_HOME"
    }

    # ANDROID_HOME 自动检测
    if (-not $env:ANDROID_HOME) {
        $SDK候选目录 = @(
            "C:\Program Files (x86)\Android\android-sdk",
            "$env:LOCALAPPDATA\Android\Sdk",
            'C:\Android\Sdk',
            "$env:USERPROFILE\Android\Sdk"
        )
        foreach ($候选 in $SDK候选目录) {
            if (Test-Path $候选) {
                $env:ANDROID_HOME = $候选
                break
            }
        }
        if (-not $env:ANDROID_HOME) {
            输出错误 "找不到 Android SDK，请安装 Android Studio 或设置 ANDROID_HOME"
            exit 1
        }
    }
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    输出成功 "ANDROID_HOME: $env:ANDROID_HOME"

    # 将 platform-tools 加入 PATH（adb 所在目录）
    $PlatformTools目录 = Join-Path $env:ANDROID_HOME "platform-tools"
    if ((Test-Path $PlatformTools目录) -and ($env:PATH -notlike "*$PlatformTools目录*")) {
        $env:PATH = "$PlatformTools目录;$env:PATH"
        输出成功 "已将 platform-tools 添加到 PATH"
    }

    # Android Build Tools：确保安装了最新版，并将 cordova.gradle 中硬编码的版本号替换为实际最新版
    $BuildTools目录 = Join-Path $env:ANDROID_HOME "build-tools"
    $已安装最新版 = if (Test-Path $BuildTools目录) {
        Get-ChildItem $BuildTools目录 -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
    }
    if (-not $已安装最新版) {
        Write-Host "  未找到 Build Tools，通过 sdkmanager 安装最新版..." -ForegroundColor DarkGray
        $SDK管理器 = Join-Path $env:ANDROID_HOME "cmdline-tools\latest\bin\sdkmanager.bat"
        if (-not (Test-Path $SDK管理器)) {
            $SDK管理器 = Get-ChildItem (Join-Path $env:ANDROID_HOME "cmdline-tools") -Filter sdkmanager.bat -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 | Select-Object -ExpandProperty FullName
        }
        if (-not $SDK管理器) {
            输出错误 "找不到 sdkmanager，请通过 Android Studio → SDK Manager → SDK Tools → Android SDK Build-Tools 安装"
            exit 1
        }
        # 查询可用最新版
        $可用列表 = & $SDK管理器 --list 2>&1 | Select-String 'build-tools;' |
            ForEach-Object { ($_ -replace '.*build-tools;(\S+).*','$1').Trim() } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_ } -Descending
        $最新可用版 = $可用列表 | Select-Object -First 1
        if (-not $最新可用版) {
            输出错误 "无法获取 Build Tools 版本列表，请检查网络或手动安装"
            exit 1
        }
        Write-Host "  安装 build-tools;$最新可用版 ..." -ForegroundColor DarkGray
        echo "y" | & $SDK管理器 "build-tools;$最新可用版" 2>&1 | ForEach-Object { Write-Host "  $_" }
        $已安装最新版 = Get-ChildItem $BuildTools目录 -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
        if (-not $已安装最新版) {
            输出错误 "Build Tools 安装失败"
            exit 1
        }
    }
    $BuildTools最新版 = $已安装最新版.Name
    输出成功 "Android Build Tools 最新版: $BuildTools最新版"
    $script:BuildTools最新版 = $BuildTools最新版

    # Rust 工具链（可能不在 PATH 中，自动检测 ~/.cargo/bin）
    if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
        $Cargo二进制目录 = Join-Path $env:USERPROFILE ".cargo\bin"
        if (Test-Path (Join-Path $Cargo二进制目录 "rustup.exe")) {
            $env:PATH = "$Cargo二进制目录;$env:PATH"
            输出成功 "已将 $Cargo二进制目录 添加到 PATH"
        } else {
            输出错误 "找不到 'rustup'，请安装 Rust: https://rustup.rs/"
            exit 1
        }
    }
    检查命令 "cargo" "请安装 Rust: https://rustup.rs/"
    输出成功 "Rust: $(rustc --version)"

    # zig 工具链（musl 交叉编译所需，axs 运行在 proot Alpine 中需要 musl 链接）
    $script:Zig路径 = $null
    $Zig命令 = Get-Command zig -ErrorAction SilentlyContinue
    if ($Zig命令) {
        $script:Zig路径 = $Zig命令.Source
    } else {
        # 在 winget 常见安装位置搜索
        $WingetPkg目录 = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
        if (Test-Path $WingetPkg目录) {
            $Zig文件 = Get-ChildItem $WingetPkg目录 -Directory -Filter "zig.zig_*" -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter "zig.exe" -ErrorAction SilentlyContinue } |
                Select-Object -First 1
            if ($Zig文件) { $script:Zig路径 = $Zig文件.FullName }
        }
        # 也检查 winget links 目录
        if (-not $script:Zig路径) {
            $链接路径 = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\zig.exe"
            if (Test-Path $链接路径) { $script:Zig路径 = $链接路径 }
        }
    }
    if (-not $script:Zig路径) {
        输出步骤 "安装 zig（musl 交叉编译所需）"
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            输出错误 "找不到 zig 且 winget 不可用，请手动安装 zig: https://ziglang.org/download/"
            exit 1
        }
        winget install zig.zig --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { Write-Host "  $_" }
        # 安装后搜索 zig.exe
        Start-Sleep -Seconds 2
        $Zig命令 = Get-Command zig -ErrorAction SilentlyContinue
        if ($Zig命令) {
            $script:Zig路径 = $Zig命令.Source
        } else {
            $WingetPkg目录 = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
            if (Test-Path $WingetPkg目录) {
                $Zig文件 = Get-ChildItem $WingetPkg目录 -Directory -Filter "zig.zig_*" -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter "zig.exe" -ErrorAction SilentlyContinue } |
                    Select-Object -First 1
                if ($Zig文件) { $script:Zig路径 = $Zig文件.FullName }
            }
            if (-not $script:Zig路径) {
                $链接路径 = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\zig.exe"
                if (Test-Path $链接路径) { $script:Zig路径 = $链接路径 }
            }
        }
        if (-not $script:Zig路径) {
            输出错误 "zig 安装后仍无法找到 zig.exe"
            exit 1
        }
    }
    # 确保 zig 所在目录在 PATH 中
    $ZigBin目录 = Split-Path $script:Zig路径
    if ($env:PATH -notlike "*$ZigBin目录*") {
        $env:PATH = "$ZigBin目录;$env:PATH"
    }
    输出成功 "zig: $(& $script:Zig路径 version 2>&1)"

    # cargo-zigbuild（使用 zig 作为 Rust 交叉编译 C linker）
    if (-not (Get-Command cargo-zigbuild -ErrorAction SilentlyContinue)) {
        $CargoZigbuild路径 = Join-Path $env:USERPROFILE ".cargo\bin\cargo-zigbuild.exe"
        if (-not (Test-Path $CargoZigbuild路径)) {
            输出步骤 "安装 cargo-zigbuild"
            cargo install cargo-zigbuild 2>&1 | ForEach-Object {
                if ($_ -match 'Compiling|Installing|Installed|^error') { Write-Host "  $_" }
            }
            if ($LASTEXITCODE -ne 0) {
                输出错误 "cargo-zigbuild 安装失败"
                exit 1
            }
        }
    }
    $CargoZigbuild版本 = & cargo-zigbuild --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        输出错误 "cargo-zigbuild 不可用: $CargoZigbuild版本"
        exit 1
    }
    输出成功 "cargo-zigbuild: $CargoZigbuild版本"

    # Rust musl target（Alpine proot 环境需要 musl 链接的二进制）
    $已安装Target = rustup target list --installed 2>&1
    if ($已安装Target -notcontains "aarch64-unknown-linux-musl") {
        Write-Host "  添加 Rust target: aarch64-unknown-linux-musl" -ForegroundColor DarkGray
        rustup target add aarch64-unknown-linux-musl 2>&1 | ForEach-Object { Write-Host "  $_" }

        # 某些环境曾通过镜像拉取过 stable manifest，component URL 会被缓存为绝对地址。
        # 仅设置环境变量不够，必须先用官方源刷新 manifest，再重新安装 target。
        $验证Target = rustup target list --installed 2>&1
        if ($验证Target -notcontains "aarch64-unknown-linux-musl") {
            输出警告 "镜像下载失败，临时使用官方源刷新工具链并重试"
            $原RUSTUP_DIST_SERVER = $env:RUSTUP_DIST_SERVER
            $原RUSTUP_UPDATE_ROOT = $env:RUSTUP_UPDATE_ROOT
            $env:RUSTUP_DIST_SERVER = "https://static.rust-lang.org"
            $env:RUSTUP_UPDATE_ROOT = "https://static.rust-lang.org/rustup"

            rustup update stable 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                $env:RUSTUP_DIST_SERVER = $原RUSTUP_DIST_SERVER
                $env:RUSTUP_UPDATE_ROOT = $原RUSTUP_UPDATE_ROOT
                输出错误 "官方源刷新 stable 工具链失败"
                exit 1
            }

            rustup target add aarch64-unknown-linux-musl 2>&1 | ForEach-Object { Write-Host "  $_" }

            # 恢复镜像设置
            if ($null -eq $原RUSTUP_DIST_SERVER) {
                Remove-Item Env:RUSTUP_DIST_SERVER -ErrorAction SilentlyContinue
            } else {
                $env:RUSTUP_DIST_SERVER = $原RUSTUP_DIST_SERVER
            }
            if ($null -eq $原RUSTUP_UPDATE_ROOT) {
                Remove-Item Env:RUSTUP_UPDATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:RUSTUP_UPDATE_ROOT = $原RUSTUP_UPDATE_ROOT
            }

            $验证Target = rustup target list --installed 2>&1
            if ($验证Target -notcontains "aarch64-unknown-linux-musl") {
                输出错误 "aarch64-unknown-linux-musl target 安装失败（镜像和官方源均失败）"
                exit 1
            }
        }
    }
    输出成功 "Rust musl target: aarch64-unknown-linux-musl"
}

function 查找NDK目录 {
    if ($env:ANDROID_NDK_HOME -and (Test-Path $env:ANDROID_NDK_HOME)) {
        return $env:ANDROID_NDK_HOME
    }
    $NDK父目录 = Join-Path $env:ANDROID_HOME "ndk"
    if (Test-Path $NDK父目录) {
        $最新版本 = Get-ChildItem $NDK父目录 -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($最新版本) { return $最新版本.FullName }
    }
    $NDK捆绑目录 = Join-Path $env:ANDROID_HOME "ndk-bundle"
    if (Test-Path $NDK捆绑目录) { return $NDK捆绑目录 }

    输出错误 "找不到 Android NDK"
    输出错误 "请通过 Android Studio → SDK Manager → SDK Tools → NDK (Side by side) 安装"
    输出错误 "或设置 ANDROID_NDK_HOME 环境变量"
    exit 1
}

function 查找NDK工具链 {
    $NDK目录 = 查找NDK目录
    输出成功 "NDK: $NDK目录"

    $工具链Bin目录 = Join-Path $NDK目录 "toolchains/llvm/prebuilt/windows-x86_64/bin"
    if (-not (Test-Path $工具链Bin目录)) {
        输出错误 "NDK 工具链目录不存在: $工具链Bin目录"
        exit 1
    }

    $Clang路径 = Join-Path $工具链Bin目录 "aarch64-linux-android${NDK接口级别}-clang.cmd"
    if (-not (Test-Path $Clang路径)) {
        $Clang文件 = Get-ChildItem $工具链Bin目录 -Filter "aarch64-linux-android*-clang.cmd" |
            Sort-Object Name | Select-Object -First 1
        if ($Clang文件) {
            $Clang路径 = $Clang文件.FullName
        } else {
            输出错误 "NDK 中找不到 aarch64-linux-android clang"
            exit 1
        }
    }

    $AR路径 = Join-Path $工具链Bin目录 "llvm-ar.exe"
    if (-not (Test-Path $AR路径)) {
        输出错误 "NDK 中找不到 llvm-ar.exe"
        exit 1
    }

    return @{
        Clang路径     = $Clang路径
        AR路径        = $AR路径
        工具链Bin目录 = $工具链Bin目录
    }
}

# ─── 子模块 URL 配置 ──────────────────────────────────────────────────
$子模块名称列表 = @("Acode", "acodex-server", "acode-plugin-github")
# 每个子模块工作树中用于判断"已正确检出"的关键文件（相对路径）
$子模块校验文件 = @{
    "Acode"               = "package.json"
    "acodex-server"       = "Cargo.toml"
    "acode-plugin-github" = "package.json"
}

$子模块原始URL = @{
    "Acode"               = "https://github.com/Ebola-Chan-bot/Acode.git"
    "acode-plugin-github" = "https://github.com/Ebola-Chan-bot/acode-plugin-github.git"
    "acodex-server"       = "https://github.com/Ebola-Chan-bot/acodex_server.git"
}

$镜像前缀列表 = @(
    "",                      # 直连
    "https://ghfast.top/",
    "https://gh-proxy.com/",
    "https://ghp.ci/"
)

function 恢复子模块URL {
    $原错误策略 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    git submodule sync 2>&1 | Out-Null
    $ErrorActionPreference = $原错误策略
}

# ─── 强制清除子模块缓存 ───────────────────────────────────────────────
function 强制清除子模块缓存 {
    # 先终止可能持有文件锁的 git 进程
    Get-Process git, git-remote-https -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $原错误策略 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    foreach ($名称 in $子模块名称列表) {
        git config --local --remove-section "submodule.$名称" 2>&1 | Out-Null
    }
    $ErrorActionPreference = $原错误策略

    $未清除列表 = [System.Collections.Generic.List[string]]::new()
    foreach ($名称 in $子模块名称列表) {
        $Git缓存目录 = Join-Path $工作区根目录 ".git/modules/$名称"
        $工作目录    = Join-Path $工作区根目录 $名称
        foreach ($目标 in @($Git缓存目录, $工作目录)) {
            if (Test-Path $目标) {
                Get-ChildItem $目标 -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
                Remove-Item $目标 -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path $目标) {
                    cmd /c "rd /s /q `"$目标`"" 2>&1 | Out-Null
                }
                if (Test-Path $目标) {
                    $未清除列表.Add($目标)
                }
            }
        }
    }

    if ($未清除列表.Count -gt 0) {
        输出错误 "以下目录无法清除（可能被 VS Code 或其他进程占用）："
        foreach ($路径 in $未清除列表) { 输出错误 "  $路径" }
        输出错误 "请关闭 VS Code 后重试"
        exit 1
    }
    输出成功 "已清除所有子模块缓存和工作目录"
}

# ─── 竞速克隆 ─────────────────────────────────────────────────────────
#
# 策略：
#   t=0   先用直连启动克隆（后台 Job）
#   t=10s 若尚未完成，追加第一个镜像并行克隆（允许直连继续）
#   t=20s 若仍未完成，追加第二个镜像……依此类推
#   任意 Job 成功 → 立即终止其余所有 Job，以其临时目录为胜出结果
#   所有 Job 均失败 → 报错退出
#
$竞速追加间隔秒 = 10   # 每隔多少秒追加下一条线路

function 竞速初始化子模块 {
    $临时根前缀 = Join-Path $工作区根目录 "_竞速克隆_"

    # 清理上次可能残留的临时目录
    Get-ChildItem $工作区根目录 -Directory -Filter "_竞速克隆_*" -ErrorAction SilentlyContinue |
        ForEach-Object { cmd /c "rd /s /q `"$($_.FullName)`"" 2>&1 | Out-Null }

    # Job 脚本块：逐个子模块克隆到临时目录
    $Job脚本 = {
        param($临时克隆目录, $镜像前缀, $子模块原始URL)

        $结果 = @{ 成功 = $false; 消息 = "" }
        $子模块列表 = @("Acode", "acodex-server", "acode-plugin-github")
        $null = New-Item -ItemType Directory -Path $临时克隆目录 -Force

        foreach ($名称 in $子模块列表) {
            $原始URL  = $子模块原始URL[$名称]
            $克隆URL  = if ($镜像前缀) { "${镜像前缀}${原始URL}" } else { $原始URL }
            $目标目录 = Join-Path $临时克隆目录 $名称

            $输出 = git clone --progress --recurse-submodules $克隆URL $目标目录 2>&1
            if ($LASTEXITCODE -ne 0) {
                $标签 = if ($镜像前缀) { $镜像前缀 } else { "直连" }
                $结果.消息 = "[$标签] 克隆 $名称 失败: $($输出 | Select-Object -Last 3 | Out-String)"
                return $结果
            }
        }

        $标签 = if ($镜像前缀) { $镜像前缀 } else { "直连" }
        $结果.成功 = $true
        $结果.消息 = "[$标签] 克隆完成"
        return $结果
    }

    $活跃Job列表  = [System.Collections.Generic.List[object]]::new()
    $镜像总数     = $镜像前缀列表.Count
    $已启动线路数 = 0
    $胜出条目     = $null
    $计时器       = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "  竞速克隆：共 $镜像总数 条线路，每 ${竞速追加间隔秒}s 无进展则追加下一条" -ForegroundColor DarkGray

    while ($true) {
        # 按时间窗口追加下一条线路
        $应启动数 = [math]::Min(
            [math]::Floor($计时器.Elapsed.TotalSeconds / $竞速追加间隔秒) + 1,
            $镜像总数
        )
        while ($已启动线路数 -lt $应启动数) {
            $当前镜像前缀 = $镜像前缀列表[$已启动线路数]
            $标签          = if ($当前镜像前缀) { $当前镜像前缀 } else { "直连" }
            $临时目录路径  = "${临时根前缀}${已启动线路数}"
            Write-Host "  [+] 启动线路 $($已启动线路数 + 1)/$镜像总数：$标签" -ForegroundColor DarkGray
            $任务 = Start-Job -ScriptBlock $Job脚本 -ArgumentList $临时目录路径, $当前镜像前缀, $子模块原始URL
            $活跃Job列表.Add(@{ Job = $任务; 标签 = $标签; 临时目录 = $临时目录路径 })
            $已启动线路数++
        }

        # 检查是否有 Job 完成
        foreach ($条目 in @($活跃Job列表)) {
            $job状态 = $条目.Job.State
            if ($job状态 -in @('Completed', 'Failed', 'Stopped')) {
                $结果 = Receive-Job $条目.Job
                Remove-Job $条目.Job -Force
                $活跃Job列表.Remove($条目)

                if ($结果 -and $结果.成功) {
                    输出成功 "率先完成：$($条目.标签)"
                    $胜出条目 = $条目
                    break
                } else {
                    $原因 = if ($结果) { $结果.消息 } else { "Job 异常终止" }
                    输出警告 "线路失败：$($条目.标签) — $原因"
                }
            }
        }

        if ($胜出条目) { break }

        # 所有 Job 全部失败且无更多线路可加
        if ($活跃Job列表.Count -eq 0 -and $已启动线路数 -ge $镜像总数) {
            输出错误 "所有克隆线路均失败"
            exit 1
        }

        Start-Sleep -Milliseconds 500
    }

    # 终止并清理其余 Job 及其临时目录
    foreach ($条目 in @($活跃Job列表)) {
        Stop-Job $条目.Job -ErrorAction SilentlyContinue
        Remove-Job $条目.Job -Force -ErrorAction SilentlyContinue
        Write-Host "  [-] 已终止线路：$($条目.标签)" -ForegroundColor DarkGray
        if (Test-Path $条目.临时目录) {
            cmd /c "rd /s /q `"$($条目.临时目录)`"" 2>&1 | Out-Null
        }
    }

    # 把胜出临时目录中的子模块移入正式位置
    输出步骤 "将克隆结果移入工作区"
    foreach ($名称 in $子模块名称列表) {
        $来源 = Join-Path $胜出条目.临时目录 $名称
        $目标 = Join-Path $工作区根目录 $名称
        if (Test-Path $目标) { cmd /c "rd /s /q `"$目标`"" 2>&1 | Out-Null }
        Move-Item $来源 $目标 -Force
        输出成功 "$名称 已就位"
    }
    # 清理胜出临时目录空壳
    if (Test-Path $胜出条目.临时目录) {
        cmd /c "rd /s /q `"$($胜出条目.临时目录)`"" 2>&1 | Out-Null
    }

    # 向父仓库注册子模块
    $原错误策略 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    git submodule init 2>&1 | Out-Null
    $ErrorActionPreference = $原错误策略
    $原错误策略 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    foreach ($名称 in $子模块名称列表) {
        $子目录      = Join-Path $工作区根目录 $名称
        $子Git路径   = Join-Path $子目录 ".git"
        $模块缓存目录 = Join-Path $工作区根目录 ".git/modules/$名称"
        # 用 .NET 方法判断是否为目录（避免 Get-Item 对隐藏目录的访问问题）
        if ([System.IO.Directory]::Exists($子Git路径) -and -not (Test-Path $模块缓存目录)) {
            # 将子模块 .git 目录移入父仓库 .git/modules/<name>，使其成为正式子模块
            New-Item -ItemType Directory -Path (Split-Path $模块缓存目录) -Force | Out-Null
            Move-Item $子Git路径 $模块缓存目录 -Force
            # 用 .NET 方法写入，避免 PowerShell 5 的 -Encoding UTF8 带 BOM 导致 git 无法解析
            [System.IO.File]::WriteAllText((Join-Path $子目录 ".git"), "gitdir: ../.git/modules/$名称`n")
            git config -f (Join-Path $模块缓存目录 "config") "core.worktree" "../../../$名称" 2>&1 | Out-Null
        }
    }
    $ErrorActionPreference = $原错误策略
    恢复子模块URL
}

# ─── 子模块初始化（主入口） ───────────────────────────────────────────
function 初始化子模块 {
    输出步骤 "初始化 Git 子模块（竞速克隆）"

    Push-Location $工作区根目录
    try {
        # 检查是否已全部就绪：.git 存在 + 工作树有内容 + 关键文件存在
        # 不使用 rev-parse HEAD，因为本地有修改时 submodule commit 引用可能失效
        $需要克隆 = $false
        foreach ($名称 in $子模块名称列表) {
            $子目录 = Join-Path $工作区根目录 $名称
            $有效   = $false
            if ((Test-Path $子目录) -and (Test-Path (Join-Path $子目录 ".git"))) {
                $校验文件 = $子模块校验文件[$名称]
                if ($校验文件 -and (Test-Path (Join-Path $子目录 $校验文件))) {
                    $有效 = $true
                }
            }
            if (-not $有效) {
                输出警告 "子模块 '$名称' 缺失或工作树不完整（缺少 $($子模块校验文件[$名称])）"
                $需要克隆 = $true
                break
            }
        }

        if (-not $需要克隆) {
            输出成功 "子模块已就绪，跳过克隆"
        } else {
            # 先尝试标准 git submodule update，限时 30 秒；超时或失败则切换到竞速克隆
            $标准超时秒 = 30
            输出步骤 "尝试标准 git submodule update --init（限时 ${标准超时秒}s）"
            $标准Job = Start-Job -ScriptBlock {
                param($工作目录)
                Set-Location $工作目录
                git submodule update --init --recursive 2>&1
                # 用特殊标记行传递退出码，因为 Job 的 State 不反映进程退出码
                Write-Output "___EXIT_CODE___:$LASTEXITCODE"
            } -ArgumentList $工作区根目录
            $标准完成 = $标准Job | Wait-Job -Timeout $标准超时秒
            $更新退出码 = 1
            if ($标准完成) {
                $标准输出 = Receive-Job $标准Job
                Remove-Job $标准Job -Force
                foreach ($行 in $标准输出) {
                    if ($行 -match '^___EXIT_CODE___:(\d+)$') {
                        $更新退出码 = [int]$Matches[1]
                    } else {
                        Write-Host "  $行"
                    }
                }
            } else {
                输出警告 "标准 submodule update 超时（${标准超时秒}s），终止"
                Stop-Job $标准Job -ErrorAction SilentlyContinue
                Remove-Job $标准Job -Force -ErrorAction SilentlyContinue
            }

            # 验证每个子模块的关键文件是否存在
            $仍需克隆 = $false
            foreach ($名称 in $子模块名称列表) {
                $子目录 = Join-Path $工作区根目录 $名称
                $校验文件 = $子模块校验文件[$名称]
                if (-not ($校验文件 -and (Test-Path (Join-Path $子目录 $校验文件)))) {
                    输出警告 "子模块 '$名称' 工作树不完整（缺少 $校验文件）"
                    $仍需克隆 = $true
                    break
                }
            }

            if ($仍需克隆) {
                输出警告 "标准 submodule update 未能完全恢复，切换到竞速克隆"
                强制清除子模块缓存
                竞速初始化子模块
            } else {
                输出成功 "标准 submodule update 成功"
            }
        }

        # 最终验证
        if (-not (Test-Path (Join-Path $Acode根目录 "package.json"))) {
            输出错误 "Acode 子模块未正确检出"
            exit 1
        }
        if (-not (Test-Path (Join-Path $Acodex根目录 "Cargo.toml"))) {
            输出错误 "acodex-server 子模块未正确检出"
            exit 1
        }
        输出成功 "子模块已就绪"
    } finally {
        Pop-Location
    }
}

# ─── Node.js 依赖安装 ─────────────────────────────────────────────────
function 安装Node依赖 {
    输出步骤 "安装 Node.js 依赖"

    Push-Location $Acode根目录
    try {
        npm install 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            输出错误 "npm install 失败"
            exit 1
        }
        输出成功 "依赖安装完成"

        # 校验关键包完整性：若某个包目录内完全没有 .js/.mjs 源码文件（只剩
        # package.json/README/LICENSE 等元数据），则认为是 npm 部分安装残缺。
        # 注意：不能用 main 字段指向的路径来判断——很多包的 main 字段本身就不准确。
        $残缺包列表 = [System.Collections.Generic.List[string]]::new()
        $依赖包目录 = Join-Path $Acode根目录 "node_modules"
        Get-ChildItem $依赖包目录 -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $包配置路径 = Join-Path $_.FullName "package.json"
            if (Test-Path $包配置路径) {
                # 只对声明了 main 或 exports 的普通 JS 包做检查
                try {
                    $包配置 = Get-Content $包配置路径 -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $有入口声明 = $包配置.main -or $包配置.exports -or $包配置.module
                    if ($有入口声明) {
                        # 递归搜索是否有任何 .js/.mjs/.cjs 源码文件
                        $源码文件数 = (Get-ChildItem $_.FullName -Recurse -Include "*.js","*.mjs","*.cjs" -ErrorAction SilentlyContinue |
                            Where-Object { $_.FullName -notmatch '[\\/]__tests__[\\/]|[\\/]test[\\/]' } |
                            Select-Object -First 1).Count
                        if ($源码文件数 -eq 0) { $残缺包列表.Add($_.Name) }
                    }
                } catch {}
            }
        }
        if ($残缺包列表.Count -gt 0) {
            输出警告 "检测到 $($残缺包列表.Count) 个安装残缺的包（无源码文件）：$($残缺包列表 -join ', ')"
            输出警告 "清空 node_modules 并重新安装..."
            Remove-Item $依赖包目录 -Recurse -Force -ErrorAction SilentlyContinue
            npm install 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                输出错误 "依赖重新安装失败"
                exit 1
            }
            输出成功 "依赖重新安装完成"
        }

        # 专项检查：@rspack/core 的 compiled 子目录（打包于 npm tarball 内）
        # 若该目录缺失则说明 tarball 解压不完整，需单独强制重装该包
        $Rspack核心Compiled = Join-Path $依赖包目录 "@rspack\core\compiled"
        if (-not (Test-Path $Rspack核心Compiled)) {
            输出警告 "@rspack/core 缺少 compiled 目录（npm 解压不完整），正在强制重装..."
            Remove-Item (Join-Path $依赖包目录 "@rspack\core") -Recurse -Force -ErrorAction SilentlyContinue
            npm install @rspack/core 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                输出错误 "@rspack/core 重装失败"
                exit 1
            }
            if (-not (Test-Path $Rspack核心Compiled)) {
                输出错误 "@rspack/core 重装后 compiled 目录依然缺失，npm 缓存可能损坏，尝试清除缓存后重装..."
                npm cache clean --force 2>&1 | ForEach-Object { Write-Host "  $_" }
                Remove-Item (Join-Path $依赖包目录 "@rspack\core") -Recurse -Force -ErrorAction SilentlyContinue
                npm install @rspack/core 2>&1 | ForEach-Object { Write-Host "  $_" }
                if ($LASTEXITCODE -ne 0) {
                    输出错误 "@rspack/core 二次重装失败"
                    exit 1
                }
            }
            输出成功 "@rspack/core 重装完成"
        }
    } finally {
        Pop-Location
    }
}

# ─── Cordova 平台设置 ─────────────────────────────────────────────────
function 设置Cordova平台 {
    输出步骤 "设置 Cordova Android 平台"

    Push-Location $Acode根目录
    try {
        @("www/css/build", "www/js/build") | ForEach-Object {
            $目录 = Join-Path $Acode根目录 $_
            if (-not (Test-Path $目录)) {
                New-Item -ItemType Directory -Path $目录 -Force | Out-Null
            }
        }

        if (-not $env:TMPDIR) { $env:TMPDIR = [System.IO.Path]::GetTempPath() }
        Set-Content (Join-Path $env:TMPDIR "fdroid.bool") -Value "false" -NoNewline
        输出成功 "fdroid.bool=false → targetSdkVersion=35"

        if (-not (Test-Path $平台根目录)) {
            Write-Host "  添加 Android 平台..." -ForegroundColor DarkGray
            npx cordova platform add android 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                输出错误 "cordova platform add android 失败"
                exit 1
            }
            输出成功 "Android 平台已添加"

            $核心插件列表 = @("cordova-plugin-buildinfo", "cordova-plugin-device", "cordova-plugin-file")
            foreach ($插件 in $核心插件列表) {
                Write-Host "  安装插件: $插件" -ForegroundColor DarkGray
                npx cordova plugin add $插件 2>&1 | Out-Null
            }

            $插件目录 = Join-Path $Acode根目录 "src/plugins"
            if (Test-Path $插件目录) {
                Get-ChildItem $插件目录 -Directory | ForEach-Object {
                    if (-not $_.Name.StartsWith('.')) {
                        Write-Host "  安装插件: $($_.Name)" -ForegroundColor DarkGray
                        try {
                            npx cordova plugin add "./src/plugins/$($_.Name)" 2>&1 | Out-Null
                        } catch {
                            输出警告 "插件 $($_.Name) 安装失败（可能已安装），继续..."
                        }
                    }
                }
            }
            输出成功 "插件安装完成"
        } else {
            输出成功 "Android 平台已存在，跳过初始化"
        }

        Write-Host "  Cordova prepare..." -ForegroundColor DarkGray
        npx cordova prepare android 2>&1 | ForEach-Object { Write-Host "  $_" }
        输出成功 "Cordova prepare 完成"

        # ── 向 cdv-gradle-config.json 写入 BUILD_TOOLS_VERSION，绕过动态搜索逻辑 ──
        # cordova.gradle 的 doFindLatestInstalledBuildTools(MIN_BUILD_TOOLS_VERSION) 搜索范围是
        # [minMajor.0.0, (minMajor+1).0.0)，若本机只装了 (minMajor+1).x.x 则搜不到。
        # 直接设置 BUILD_TOOLS_VERSION 后，Groovy 代码中 if (!cordovaConfig.BUILD_TOOLS_VERSION)
        # 分支不会执行，完全绕开该问题。
        if ($script:BuildTools最新版) {
            $Cdv配置文件 = Join-Path $平台根目录 "cdv-gradle-config.json"
            if (Test-Path $Cdv配置文件) {
                $Cdv配置对象 = Get-Content $Cdv配置文件 -Raw -Encoding UTF8 | ConvertFrom-Json
                $Cdv配置对象 | Add-Member -Name "BUILD_TOOLS_VERSION" -Value $script:BuildTools最新版 -MemberType NoteProperty -Force
                $Cdv配置对象 | ConvertTo-Json -Depth 10 | Set-Content $Cdv配置文件 -Encoding UTF8
                输出成功 "cdv-gradle-config.json BUILD_TOOLS_VERSION → $($script:BuildTools最新版)"
            }
        }

        # ── 将 Cordova Scheme 改为 http，允许 ws:// WebSocket 连接 ──
        # 默认 Cordova 使用 https scheme 加载页面（安全上下文），会阻止 ws:// 连接
        $平台ConfigXml = Join-Path $平台根目录 "app\src\main\res\xml\config.xml"
        if (Test-Path $平台ConfigXml) {
            $配置内容 = Get-Content $平台ConfigXml -Raw -Encoding UTF8
            if ($配置内容 -notmatch '<preference name="Scheme" value="http"') {
                $配置内容 = $配置内容 -replace '(?m)^\s*<preference name="Scheme" value="[^"]*"\s*/>\s*\r?\n?', ''
                $配置内容 = $配置内容 -replace '</widget>', "    <preference name=`"Scheme`" value=`"http`" />`n</widget>"
                Set-Content $平台ConfigXml -Value $配置内容 -Encoding UTF8 -NoNewline
                输出成功 "已设置 Cordova Scheme=http（允许 ws:// 连接）"
            }
        }

        # ── 生成 Gradle wrapper（gitignored，需手动生成）──
        if (-not (Test-Path $Gradlew路径)) {
            Write-Host "  生成 Gradle wrapper..." -ForegroundColor DarkGray
            $Gradle配置 = Get-Content (Join-Path $平台根目录 "cdv-gradle-config.json") -Raw | ConvertFrom-Json
            $Gradle版本  = $Gradle配置.GRADLE_VERSION

            # 从 ~/.gradle/wrapper/dists 中找已下载的 Gradle
            $Gradle发行目录 = Join-Path $env:USERPROFILE ".gradle\wrapper\dists"
            $Gradle可执行 = Get-ChildItem $Gradle发行目录 -Recurse -Filter "gradle.bat" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "gradle-$Gradle版本-" } |
                Select-Object -First 1
            if (-not $Gradle可执行) {
                # fallback：用任意可用版本
                $Gradle可执行 = Get-ChildItem $Gradle发行目录 -Recurse -Filter "gradle.bat" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if (-not $Gradle可执行) {
                输出错误 "找不到可用的 Gradle，请安装 Gradle 或确保 ~/.gradle/wrapper/dists 中有已下载的版本"
                exit 1
            }
            输出成功 "使用 Gradle: $($Gradle可执行.FullName)"
            $工具目录 = Join-Path $平台根目录 "tools"
            $原错误策略 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            & $Gradle可执行.FullName -p $工具目录 wrapper --gradle-version $Gradle版本 2>&1 | ForEach-Object { Write-Host "  $_" }
            $ErrorActionPreference = $原错误策略
            # 将 tools/ 下生成的 wrapper 文件复制到平台根目录
            @("gradlew", "gradlew.bat") | ForEach-Object {
                $源文件 = Join-Path $工具目录 $_
                if (Test-Path $源文件) {
                    Copy-Item $源文件 (Join-Path $平台根目录 $_) -Force
                }
            }
            $源Gradle目录 = Join-Path $工具目录 "gradle"
            if (Test-Path $源Gradle目录) {
                Copy-Item $源Gradle目录 (Join-Path $平台根目录 "gradle") -Recurse -Force
            }
            if (Test-Path $Gradlew路径) {
                输出成功 "Gradle wrapper 已生成"
            } else {
                输出错误 "Gradle wrapper 生成失败"
                exit 1
            }
        }
    } finally {
        Pop-Location
    }
}

# ─── 交叉编译 acodex-server ──────────────────────────────────────────
function 编译AcodexServer {
    输出步骤 "交叉编译 acodex-server → aarch64 musl (Alpine proot)"

    Push-Location $Acodex根目录
    try {
        Write-Host "  编译中（首次编译可能需要较长时间）..." -ForegroundColor DarkGray
        cargo zigbuild --target aarch64-unknown-linux-musl --release 2>&1 | ForEach-Object {
            if ($_ -match 'Compiling|Finished|^error|ld\.lld:|warning:') { Write-Host "  $_" }
        }
        if ($LASTEXITCODE -ne 0) {
            输出错误 "acodex-server 编译失败"
            exit 1
        }

        $Axs二进制 = Join-Path $Acodex根目录 "target/aarch64-unknown-linux-musl/release/axs"
        if (-not (Test-Path $Axs二进制)) {
            输出错误 "编译产物不存在: $Axs二进制"
            exit 1
        }
        $大小MB = [math]::Round((Get-Item $Axs二进制).Length / 1MB, 1)
        输出成功 "axs 编译完成 ($大小MB MB)"
    } finally {
        Pop-Location
    }
}

# ─── 同步资产到平台目录 ───────────────────────────────────────────────
function 同步资产 {
    输出步骤 "同步资产到 Android 平台目录"

    if (-not (Test-Path $平台Assets目录)) {
        输出错误 "平台 assets 目录不存在，请先运行: .\构建部署.ps1 -动作 setup"
        exit 1
    }

    $Axs二进制 = Join-Path $Acodex根目录 "target/aarch64-unknown-linux-musl/release/axs"
    if ($构建模式 -eq "release") {
        # Release builds: remove bundled axs to reduce APK size (app downloads latest)
        $嵌入Axs = Join-Path $平台Assets目录 "axs"
        if (Test-Path $嵌入Axs) { Remove-Item $嵌入Axs -Force }
        输出成功 "release 模式：跳过 axs 嵌入（应用将从网络下载）"
    } elseif (Test-Path $Axs二进制) {
        Copy-Item $Axs二进制 (Join-Path $平台Assets目录 "axs") -Force
        $大小MB = [math]::Round((Get-Item $Axs二进制).Length / 1MB, 1)
        输出成功 "axs ($大小MB MB) → assets/axs（debug 嵌入）"
    } else {
        输出警告 "axs 二进制不存在，跳过（请先执行 -动作 build-server）"
    }

    $Shell脚本列表 = @(
        @{ 来源 = "src/plugins/terminal/scripts/init-alpine.sh";  目标文件名 = "init-alpine.sh" },
        @{ 来源 = "src/plugins/terminal/scripts/init-sandbox.sh"; 目标文件名 = "init-sandbox.sh" },
        @{ 来源 = "src/plugins/terminal/scripts/rm-wrapper.sh";   目标文件名 = "rm-wrapper.sh" }
    )
    foreach ($项 in $Shell脚本列表) {
        $来源路径 = Join-Path $Acode根目录 $项.来源
        if (Test-Path $来源路径) {
            Copy-Item $来源路径 (Join-Path $平台Assets目录 $项.目标文件名) -Force
            输出成功 "$($项.目标文件名) → assets/"
        }
    }

    $前端构建源  = Join-Path $Www目录 "build"
    $前端构建目标 = Join-Path $平台AssetsWww "build"
    if (Test-Path $前端构建源) {
        if (-not (Test-Path $前端构建目标)) {
            New-Item -ItemType Directory -Path $前端构建目标 -Force | Out-Null
        }
        Copy-Item -Path "$前端构建源\*" -Destination $前端构建目标 -Recurse -Force
        $文件数 = (Get-ChildItem $前端构建源 -Recurse -File).Count
        输出成功 "www/build → assets/www/build ($文件数 个文件)"
    }

    同步插件资产
}

function 同步插件资产 {
    $Cordova插件Js = Join-Path $平台AssetsWww "cordova_plugins.js"
    if (-not (Test-Path $Cordova插件Js)) {
        输出警告 "cordova_plugins.js 不存在，跳过 JS 插件同步"
        return
    }

    $文件内容 = Get-Content $Cordova插件Js -Raw -Encoding UTF8
    $模块ID映射 = @{}
    $匹配结果 = [regex]::Matches($文件内容, '"id":\s*"([^"]+)"[^}]*?"file":\s*"([^"]+)"')
    foreach ($匹配 in $匹配结果) {
        $模块ID映射[$匹配.Groups[2].Value] = $匹配.Groups[1].Value
    }

    $插件目录到ID = @{
        "terminal"                 = "com.foxdebug.acode.rk.exec.terminal"
        "system"                   = "cordova-plugin-system"
        "custom-tabs"              = "com.foxdebug.acode.rk.customtabs"
        "pluginContext"            = "com.foxdebug.acode.rk.plugin.plugincontext"
        "cordova-plugin-buildinfo" = "cordova-plugin-buildinfo"
        "ftp"                      = "cordova-plugin-ftp"
        "iap"                      = "cordova-plugin-iap"
        "sdcard"                   = "cordova-plugin-sdcard"
        "server"                   = "cordova-plugin-server"
        "sftp"                     = "cordova-plugin-sftp"
        "websocket"                = "cordova-plugin-websocket"
    }

    $JS文件数 = 0
    foreach ($目录名 in $插件目录到ID.Keys) {
        $插件ID      = $插件目录到ID[$目录名]
        $插件Www目录 = Join-Path $Acode根目录 "src/plugins/$目录名/www"
        if (-not (Test-Path $插件Www目录)) { continue }

        Get-ChildItem $插件Www目录 -Filter "*.js" | ForEach-Object {
            $JS文件       = $_
            $平台相对路径 = "plugins/$插件ID/www/$($JS文件.Name)"
            $目标路径     = Join-Path $平台AssetsWww $平台相对路径
            $模块ID       = $模块ID映射[$平台相对路径]
            if (-not $模块ID) { return }

            $目标目录 = Split-Path $目标路径
            if (-not (Test-Path $目标目录)) {
                New-Item -ItemType Directory -Path $目标目录 -Force | Out-Null
            }

            $JS内容  = Get-Content $JS文件.FullName -Raw -Encoding UTF8
            $包装内容 = "cordova.define(""$模块ID"", function(require, exports, module) {`n${JS内容}`n});`n"
            Set-Content $目标路径 -Value $包装内容 -Encoding UTF8 -NoNewline
            $JS文件数++
        }
    }
    if ($JS文件数 -gt 0) {
        输出成功 "JS 插件已同步 ($JS文件数 个，含 cordova.define 包装)"
    }

    $平台Java根目录  = Join-Path $平台根目录 "app/src/main/java"
    $Java文件数      = 0
    $插件源码基目录  = Join-Path $Acode根目录 "src/plugins"
    if (Test-Path $插件源码基目录) {
        Get-ChildItem $插件源码基目录 -Directory | ForEach-Object {
            $Java文件列表 = Get-ChildItem $_.FullName -Filter "*.java" -Recurse -ErrorAction SilentlyContinue
            foreach ($Java文件 in $Java文件列表) {
                $前几行   = Get-Content $Java文件.FullName -TotalCount 10 -Encoding UTF8
                $包名匹配 = $前几行 | Select-String -Pattern '^\s*package\s+([^;]+);' | Select-Object -First 1
                if ($包名匹配) {
                    $包路径   = $包名匹配.Matches[0].Groups[1].Value.Replace('.', '/')
                    $目标目录 = Join-Path $平台Java根目录 $包路径
                    if (Test-Path $目标目录) {
                        Copy-Item $Java文件.FullName (Join-Path $目标目录 $Java文件.Name) -Force
                        $Java文件数++
                    }
                }
            }
        }
    }
    if ($Java文件数 -gt 0) {
        输出成功 "Java 源文件已同步 ($Java文件数 个)"
    }
}

# ─── 注入调试客户端 ───────────────────────────────────────────────────
function 注入调试客户端 {
    $平台IndexHtml = Join-Path $平台AssetsWww "index.html"
    if (-not (Test-Path $平台IndexHtml)) {
        输出警告 "平台 index.html 不存在，跳过调试客户端注入"
        return
    }

    $内容 = Get-Content $平台IndexHtml -Raw -Encoding UTF8

    # 先清理旧注入，避免上一次构建残留到当前产物。
    if ($内容 -match "HDC_DEBUG") {
        $内容 = $内容 -replace '(?s)\s*<!-- HDC_DEBUG -->.*?</script>\s*', "`n"
        [System.IO.File]::WriteAllText($平台IndexHtml, $内容, [System.Text.UTF8Encoding]::new($false))
        输出警告 "已清除旧版调试注入"
    }

    if ($构建模式 -eq "release") {
        输出成功 "release 构建默认不注入调试客户端"
        return
    }

    if (-not $启用调试客户端) {
        输出成功 "未启用调试客户端注入，构建产物不依赖调试服务器"
        return
    }

    # 检测局域网IP（优先 WLAN/以太网等实际物理网卡，排除虚拟网卡和移动热点）
    $候选 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.PrefixOrigin -ne "WellKnown" -and
        $_.IPAddress -notmatch '^169\.254\.' -and
        $_.IPAddress -ne '127.0.0.1' -and
        $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Hyper-V|WSL|VirtualBox|VMware|isatap|Teredo|Bluetooth|本地连接\*'
    }
    # 优先选择 WLAN / Wi-Fi / 以太网等实际物理网卡（DHCP 分配的地址更可靠）
    $内网IP = ($候选 | Where-Object {
        $_.InterfaceAlias -match 'WLAN|Wi-Fi|以太网|Ethernet' -and $_.PrefixOrigin -eq 'Dhcp'
    } | Select-Object -First 1).IPAddress
    if (-not $内网IP) {
        # fallback：任意 DHCP 分配的私有 IP
        $内网IP = ($候选 | Where-Object {
            $_.PrefixOrigin -eq 'Dhcp' -and (
                $_.IPAddress -match '^192\.168\.' -or $_.IPAddress -match '^10\.' -or
                $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.'
            )
        } | Select-Object -First 1).IPAddress
    }
    if (-not $内网IP) {
        $内网IP = ($候选 | Select-Object -First 1).IPAddress
    }
    if (-not $内网IP) { $内网IP = "127.0.0.1" }

    $调试端口 = 8092
    $调试脚本标签 = "    <!-- HDC_DEBUG --><script src=`"http://${内网IP}:${调试端口}/__debug_client.js`"></script>"

    # 在 cordova.js 之前插入
    $内容 = $内容 -replace '(\s*<script src="cordova\.js"></script>)', "`n$调试脚本标签`n`$1"
    [System.IO.File]::WriteAllText($平台IndexHtml, $内容, [System.Text.UTF8Encoding]::new($false))

    输出步骤 "注入调试客户端"
    输出成功 "调试服务器地址: http://${内网IP}:${调试端口}"
    输出成功 "已注入到平台 index.html（仅影响构建产物，不修改源文件）"
}

# ─── 构建前端资源 ─────────────────────────────────────────────────────
function 构建前端 {
    输出步骤 "构建前端资源"

    Push-Location $Acode根目录
    try {
        $配置模式  = if ($构建模式 -eq "release") { "p" } else { "d" }
        $Rspack模式 = if ($构建模式 -eq "release") { "production" } else { "development" }

        Write-Host "  配置: mode=$配置模式 app=$应用类型" -ForegroundColor DarkGray
        node ./utils/config.js $配置模式 $应用类型 2>&1 | ForEach-Object { Write-Host "  $_" }

        Write-Host "  rspack 构建 (mode=$Rspack模式)..." -ForegroundColor DarkGray
        npx rspack --mode $Rspack模式 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            输出错误 "rspack 构建失败"
            exit 1
        }
        输出成功 "前端构建完成"
    } finally {
        Pop-Location
    }
}

# ─── Gradle 构建 APK ──────────────────────────────────────────────────
function 构建APK {
    输出步骤 "Gradle 构建 APK"

    if (-not (Test-Path $Gradlew路径)) {
        输出错误 "找不到 gradlew.bat: $Gradlew路径"
        输出错误 "请先运行: .\构建部署.ps1 -动作 setup"
        exit 1
    }

    $Gradle任务 = if ($构建模式 -eq "release") { "assembleRelease" } else { "assembleDebug" }
    $输出目录   = if ($构建模式 -eq "release") { $发布APK输出目录 } else { $调试APK输出目录 }

    Push-Location (Split-Path $Gradlew路径)
    try {
        # 直接运行，不经过 pipeline——避免 Gradle Daemon 持有管道句柄导致卡死
        & $Gradlew路径 $Gradle任务
        if ($LASTEXITCODE -ne 0) {
            输出错误 "Gradle 构建失败 (exit code: $LASTEXITCODE)"
            exit 1
        }
    } finally {
        Pop-Location
    }

    $应用信息    = 获取应用信息
    $目标文件名  = "$($应用信息.名称)-$($应用信息.版本).apk"
    $源APK路径   = Join-Path $输出目录 "app-${构建模式}.apk"
    $目标APK路径 = Join-Path $输出目录 $目标文件名

    if (Test-Path $源APK路径) {
        Copy-Item $源APK路径 $目标APK路径 -Force
        $大小MB = [math]::Round((Get-Item $目标APK路径).Length / 1MB, 1)
        输出成功 "APK: $目标文件名 ($大小MB MB)"
        输出成功 "路径: $目标APK路径"
        return $目标APK路径
    } else {
        $最新APK = Get-ChildItem "$输出目录/*.apk" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($最新APK) {
            输出成功 "APK: $($最新APK.Name)"
            return $最新APK.FullName
        }
        输出错误 "未找到构建产物"
        exit 1
    }
}

# ─── 设备连接检测 ─────────────────────────────────────────────────────
function 检测设备连接 {
    if ($设备模式 -eq "adb") {
        $有ADB = Get-Command "adb" -ErrorAction SilentlyContinue
        $ADB设备已连接 = $false
        if ($有ADB) {
            $已连接设备 = adb devices 2>&1 | Select-String "device$"
            if ($已连接设备) {
                输出成功 "ADB 设备: $($已连接设备.Line.Trim())"
                $ADB设备已连接 = $true
            }
        }
        if (-not $ADB设备已连接) {
            # ADB 不可用或无设备，自动尝试 HDC
            $HDC可用 = $false
            if (Test-Path $HDC程序路径) {
                $HDC可用 = $true
            } else {
                $已找到HDC = Get-Command hdc -ErrorAction SilentlyContinue
                if ($已找到HDC) {
                    $script:HDC程序路径 = $已找到HDC.Source
                    $HDC可用 = $true
                }
            }
            if ($HDC可用) {
                $设备列表 = & $HDC程序路径 list targets 2>&1
                if ($设备列表 -notmatch "^\[Empty\]$" -and -not [string]::IsNullOrWhiteSpace($设备列表)) {
                    输出警告 "ADB 未检测到设备，自动切换到 HDC"
                    $script:设备模式 = "hdc"
                    输出成功 "HDC 设备: $($设备列表.Trim())"
                    return
                }
            }
            输出错误 "未检测到任何设备（ADB 和 HDC 均无响应），请确认："
            输出错误 "  1. 手机已通过 USB 连接到电脑"
            输出错误 "  2. 手机已开启 USB 调试 / 开发者模式"
            输出错误 "  3. 手机上已授权此电脑的调试"
            exit 1
        }
    } else {
        if (-not (Test-Path $HDC程序路径)) {
            $已找到HDC = Get-Command hdc -ErrorAction SilentlyContinue
            if ($已找到HDC) {
                $script:HDC程序路径 = $已找到HDC.Source
            } else {
                输出错误 "找不到 hdc.exe，请确认华为手机助手已安装"
                exit 1
            }
        }
        $设备列表 = & $HDC程序路径 list targets 2>&1
        if ($设备列表 -match "^\[Empty\]$" -or [string]::IsNullOrWhiteSpace($设备列表)) {
            输出错误 "未检测到 HDC 设备，请确认 USB 连接并开启开发者模式"
            exit 1
        }
        输出成功 "HDC 设备: $($设备列表.Trim())"
    }
}

# ─── 部署 APK 到手机 ──────────────────────────────────────────────────
function 部署APK {
    param([string]$APK路径)

    输出步骤 "部署 APK 到手机 ($设备模式)"
    检测设备连接

    $输出目录 = if ($构建模式 -eq "release") { $发布APK输出目录 } else { $调试APK输出目录 }

    if (-not $APK路径 -or -not (Test-Path $APK路径)) {
        $应用信息  = 获取应用信息
        $带版本APK = Join-Path $输出目录 "$($应用信息.名称)-$($应用信息.版本).apk"
        if (Test-Path $带版本APK) {
            $APK路径 = $带版本APK
        } else {
            $最新APK = Get-ChildItem "$输出目录/*.apk" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $最新APK) {
                输出错误 "未找到 APK 文件，请先执行构建"
                exit 1
            }
            $APK路径 = $最新APK.FullName
        }
    }

    $APK文件项 = Get-Item $APK路径
    $大小MB    = [math]::Round($APK文件项.Length / 1MB, 1)
    Write-Host "  APK: $($APK文件项.Name) ($大小MB MB)" -ForegroundColor DarkGray

    if ($设备模式 -eq "adb") {
        Write-Host "  通过 ADB 安装（替换已有版本）..." -ForegroundColor DarkGray
        adb install -r $APK文件项.FullName 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) {
            输出成功 "安装成功！"
            $包名 = if ($应用类型 -eq "free") { "com.foxdebug.acodefree" } else { "com.foxdebug.acode" }
            Write-Host "  启动应用..." -ForegroundColor DarkGray
            adb shell am start -n "$包名/.MainActivity" 2>&1 | ForEach-Object { Write-Host "  $_" }
            输出成功 "应用已启动"
        } else {
            输出错误 "ADB 安装失败，请检查设备连接和权限"
        }
    } else {
        $远程路径 = "/storage/media/100/local/files/Docs/Download/$($APK文件项.Name)"
        Write-Host "  推送到: $远程路径" -ForegroundColor DarkGray
        & $HDC程序路径 file send $APK文件项.FullName $远程路径 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) {
            输出成功 "推送成功！请在手机文件管理器 → 下载 中点击安装"
        } else {
            输出警告 "推送可能失败，尝试备选路径..."
            $备选路径 = "/data/local/tmp/$($APK文件项.Name)"
            & $HDC程序路径 file send $APK文件项.FullName $备选路径 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -eq 0) {
                输出成功 "已推送到 $备选路径，可能需要手动安装"
            } else {
                输出错误 "推送失败，请检查 HDC 连接和设备权限"
            }
        }
    }
}

# ─── 清理构建产物 ──────────────────────────────────────────────────────
function 清理构建产物 {
    输出步骤 "清理构建产物"

    $清理目标列表 = @(
        @{ 路径 = (Join-Path $Acodex根目录 "target"); 描述 = "acodex-server Rust 编译缓存" },
        @{ 路径 = (Join-Path $Acode根目录 "www/build"); 描述 = "前端构建产物" },
        @{ 路径 = $调试APK输出目录; 描述 = "Debug APK 输出" },
        @{ 路径 = $发布APK输出目录; 描述 = "Release APK 输出" }
    )

    foreach ($目标 in $清理目标列表) {
        if (Test-Path $目标.路径) {
            Remove-Item $目标.路径 -Recurse -Force
            输出成功 "已清理: $($目标.描述)"
        } else {
            Write-Host "  跳过: $($目标.描述)（不存在）" -ForegroundColor DarkGray
        }
    }
}

# ─── 主流程 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  Acode + acodex-server 一键构建部署工具     ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host "  工作区: $工作区根目录" -ForegroundColor DarkGray
Write-Host "  动作: $动作 | 构建: $构建模式 | 应用: $应用类型 | 设备: $设备模式" -ForegroundColor DarkGray

switch ($动作) {
    "setup" {
        初始化构建环境
        初始化子模块
        安装Node依赖
        设置Cordova平台
        Write-Host ""
        Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✓ 环境设置完成！可以执行完整构建了" -ForegroundColor Green
        Write-Host "  下一步: .\构建部署.ps1" -ForegroundColor Green
        Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
    }

    "build-server" {
        初始化构建环境
        编译AcodexServer
    }

    "build-apk" {
        初始化构建环境
        构建前端
        同步资产
        注入调试客户端
        构建APK
    }

    "deploy" {
        部署APK
    }

    "clean" {
        清理构建产物
    }

    "full" {
        初始化构建环境
        初始化子模块
        安装Node依赖
        设置Cordova平台
        编译AcodexServer
        构建前端
        同步资产
        注入调试客户端
        $APK文件 = 构建APK
        部署APK -APK路径 $APK文件

        Write-Host ""
        Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✓ 全部完成！应用已部署到手机" -ForegroundColor Green
        Write-Host "══════════════════════════════════════════════" -ForegroundColor Green
    }
}
