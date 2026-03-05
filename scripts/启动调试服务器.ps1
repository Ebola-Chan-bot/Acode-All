# 启动调试服务器.ps1
# 作用：启动 Acode 官方 hdc-debug 调试服务器（HTTP + WebSocket），通过局域网接收调试信息。
# 注意：hdc rport/logcat 不可用，仅通过局域网方式调试。

param(
  [int]$端口 = 8092,
  [switch]$前台,
  [switch]$仅本机
)

$ErrorActionPreference = "Stop"

function 输出步骤([string]$消息) { Write-Host "`n▶ $消息" -ForegroundColor Cyan }
function 输出成功([string]$消息) { Write-Host "  ✓ $消息" -ForegroundColor Green }
function 输出警告([string]$消息) { Write-Host "  ⚠ $消息" -ForegroundColor Yellow }
function 输出错误([string]$消息) { Write-Host "  ✗ $消息" -ForegroundColor Red }

function 获取局域网IP {
  $候选 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.PrefixOrigin -ne "WellKnown" -and
    $_.IPAddress -notmatch '^169\.254\.' -and
    $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Hyper-V|WSL|VirtualBox|VMware|isatap|Teredo|Bluetooth'
  }
  $内网优先 = $候选 | Where-Object {
    $_.IPAddress -match '^192\.168\.' -or
    $_.IPAddress -match '^10\.' -or
    $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.'
  } | Select-Object -First 1

  if ($内网优先) { return $内网优先.IPAddress }
  $任意 = $候选 | Select-Object -First 1
  if ($任意) { return $任意.IPAddress }
  return "127.0.0.1"
}

function 等待HTTP就绪([string]$URL, [int]$超时秒 = 10) {
  $截止时间 = (Get-Date).AddSeconds($超时秒)
  while ((Get-Date) -lt $截止时间) {
    try {
      $响应 = Invoke-WebRequest -Uri $URL -UseBasicParsing -TimeoutSec 2
      if ($响应.StatusCode -ge 200 -and $响应.StatusCode -lt 400) {
        return $true
      }
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  return $false
}

function 检查Node {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    输出错误 "未检测到 Node.js，请先安装后重试。"
    exit 1
  }
  输出成功 "Node.js 已就绪"
}

function 清理端口占用([int]$目标端口) {
  $连接 = Get-NetTCPConnection -LocalPort $目标端口 -ErrorAction SilentlyContinue
  if (-not $连接) { return }

  $进程ID列表 = $连接 | Select-Object -ExpandProperty OwningProcess -Unique
  foreach ($进程ID in $进程ID列表) {
    if ($进程ID -and $进程ID -ne 0 -and $进程ID -ne $PID) {
      try {
        Stop-Process -Id $进程ID -Force -ErrorAction Stop
        输出警告 "已终止占用端口 $目标端口 的进程 PID=$进程ID"
      } catch {
        输出警告 "终止占用进程失败 PID=$进程ID：$($_.Exception.Message)"
      }
    }
  }
}

function 配置防火墙入站规则([int]$目标端口) {
  $规则名 = "Acode-HDC-调试-$目标端口"
  try {
    $检查输出 = & netsh advfirewall firewall show rule name="$规则名" 2>&1
    if (($检查输出 -join "`n") -match "No rules match" -or ($检查输出 -join "`n") -match "没有与指定条件匹配的规则") {
      & netsh advfirewall firewall add rule name="$规则名" dir=in action=allow protocol=TCP localport=$目标端口 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        输出成功 "已添加防火墙入站规则: TCP/$目标端口"
      } else {
        输出警告 "添加防火墙规则失败，可能需要管理员权限"
      }
    } else {
      输出成功 "防火墙规则已存在: TCP/$目标端口"
    }
  } catch {
    输出警告 "配置防火墙失败：$($_.Exception.Message)"
  }
}



输出步骤 "准备路径与依赖"
检查Node

$仓库根目录 = Resolve-Path (Join-Path $PSScriptRoot "..")
$项目目录 = Join-Path $仓库根目录 "Acode"
$服务器脚本 = Join-Path $项目目录 "scripts/hdc-debug/server.mjs"
$日志目录 = Join-Path $PSScriptRoot "logs"

if (-not (Test-Path $服务器脚本)) {
  输出错误 "找不到服务器脚本: $服务器脚本"
  exit 1
}

if (-not (Test-Path $日志目录)) {
  New-Item -ItemType Directory -Path $日志目录 -Force | Out-Null
}

输出步骤 "检查 ws 依赖"
$ws目录 = Join-Path $项目目录 "node_modules/ws"
if (-not (Test-Path $ws目录)) {
  Push-Location $项目目录
  try {
    npm install ws --save-dev
    if ($LASTEXITCODE -ne 0) {
      输出错误 "ws 安装失败"
      exit 1
    }
  } finally {
    Pop-Location
  }
  输出成功 "ws 安装完成"
} else {
  输出成功 "ws 已安装"
}

输出步骤 "清理端口占用"
清理端口占用 -目标端口 $端口

输出步骤 "配置防火墙"
配置防火墙入站规则 -目标端口 $端口

$服务器参数 = @($服务器脚本, "--port", $端口)
if (-not $仅本机) {
  $服务器参数 += "--watch"
} else {
  $服务器参数 += "--localhost"
}

$局域网IP = 获取局域网IP
$HTTP地址 = if ($仅本机) { "http://127.0.0.1:$端口/__debug_client.js" } else { "http://${局域网IP}:$端口/__debug_client.js" }
$WS地址 = if ($仅本机) { "ws://127.0.0.1:$端口" } else { "ws://${局域网IP}:$端口" }

if ($前台) {
  输出步骤 "前台启动调试服务器"
  Write-Host "  HTTP: $HTTP地址" -ForegroundColor DarkGray
  Write-Host "  WS:   $WS地址" -ForegroundColor DarkGray
  Push-Location $项目目录
  try {
    node @服务器参数
  } finally {
    Pop-Location
  }
  exit $LASTEXITCODE
}

输出步骤 "后台启动调试服务器"
$时间戳 = Get-Date -Format "yyyyMMdd-HHmmss"
$标准输出日志 = Join-Path $日志目录 "调试服务器-$时间戳.out.log"
$错误输出日志 = Join-Path $日志目录 "调试服务器-$时间戳.err.log"

$进程 = Start-Process -FilePath "node" `
  -ArgumentList $服务器参数 `
  -WorkingDirectory $项目目录 `
  -WindowStyle Hidden `
  -PassThru `
  -RedirectStandardOutput $标准输出日志 `
  -RedirectStandardError $错误输出日志

if (-not $进程) {
  输出错误 "后台启动失败"
  exit 1
}

Start-Sleep -Milliseconds 700
if ($进程.HasExited) {
  输出错误 "服务器进程已退出，查看日志: $错误输出日志"
  exit 1
}

输出步骤 "连通性自检"
$本机探测地址 = "http://127.0.0.1:$端口/__debug_client.js"
if (等待HTTP就绪 -URL $本机探测地址 -超时秒 12) {
  输出成功 "HTTP 探测成功: $本机探测地址"
  输出成功 "后台进程 PID: $($进程.Id)"
  Write-Host "  局域网 HTTP: $HTTP地址" -ForegroundColor Green
  Write-Host "  局域网 WS:   $WS地址" -ForegroundColor Green
  Write-Host "  日志文件:    $标准输出日志" -ForegroundColor DarkGray
} else {
  输出错误 "HTTP 探测失败: $本机探测地址"
  输出错误 "请查看日志: $错误输出日志"
  try { Stop-Process -Id $进程.Id -Force -ErrorAction SilentlyContinue } catch {}
  exit 1
}
