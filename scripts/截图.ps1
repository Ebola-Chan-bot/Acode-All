<#
.SYNOPSIS
  通过 HDC 获取华为手机屏幕截图

.DESCRIPTION
  使用 HDC shell 命令在手机端执行截图，然后拉取到本地。
  默认保存到桌面，文件名包含时间戳。

.PARAMETER 输出目录
  截图保存目录 (默认: 桌面)

.PARAMETER 文件名
  自定义文件名 (不含扩展名)。省略则自动生成带时间戳的名称。

.PARAMETER 打开
  截图完成后自动打开图片

.EXAMPLE
  .\截图.ps1                          # 截图保存到桌面
  .\截图.ps1 -输出目录 "D:\pics"      # 截图保存到指定目录
  .\截图.ps1 -文件名 "bug-repro"      # 自定义文件名
  .\截图.ps1 -打开                    # 截图后自动打开
#>

param(
    [string]$输出目录 = [Environment]::GetFolderPath("Desktop"),
    [string]$文件名,
    [switch]$打开
)

$ErrorActionPreference = "Stop"

# ─── 配置 ─────────────────────────────────────────────────────────────
$HDC程序路径 = "C:\Program Files (x86)\HiSuite\hwtools\hdc.exe"

# ─── 工具函数 ─────────────────────────────────────────────────────────
function 输出步骤($消息) { Write-Host "`n▶ $消息" -ForegroundColor Cyan }
function 输出成功($消息) { Write-Host "  ✓ $消息" -ForegroundColor Green }
function 输出错误($消息) { Write-Host "  ✗ $消息" -ForegroundColor Red }

# ─── 检查 HDC ─────────────────────────────────────────────────────────
if (-not (Test-Path $HDC程序路径)) {
    输出错误 "找不到 hdc.exe: $HDC程序路径"
    Write-Host "  请确认已安装华为手机助手 (HiSuite)" -ForegroundColor Yellow
    exit 1
}

# ─── 检查设备连接 ─────────────────────────────────────────────────────
输出步骤 "检查设备连接"
$设备列表 = & $HDC程序路径 list targets 2>&1
if ($LASTEXITCODE -ne 0 -or $设备列表 -match "Empty" -or [string]::IsNullOrWhiteSpace($设备列表)) {
    输出错误 "未检测到已连接的设备"
    Write-Host "  请确认手机已通过 USB 连接并开启 HDC 调试" -ForegroundColor Yellow
    exit 1
}
输出成功 "已连接设备: $($设备列表.Trim())"

# ─── 截图 ─────────────────────────────────────────────────────────────
输出步骤 "在手机上执行截图"
$命令输出 = & $HDC程序路径 shell snapshot_display 2>&1 | Out-String
if ($命令输出 -match "write to\s+(\S+)") {
    $手机端路径 = $Matches[1]
} else {
    输出错误 "截图失败，无法解析输出:`n$命令输出"
    exit 1
}

# 从远程文件名推断扩展名 (jpeg/png)
$扩展名 = [System.IO.Path]::GetExtension($手机端路径)
if ([string]::IsNullOrWhiteSpace($扩展名)) { $扩展名 = ".jpeg" }

输出成功 "手机端截图: $手机端路径"

# ─── 拉取到本地 ───────────────────────────────────────────────────────
输出步骤 "拉取截图到本地"

if (-not (Test-Path $输出目录)) {
    New-Item -ItemType Directory -Path $输出目录 -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($文件名)) {
    $时间戳 = Get-Date -Format "yyyyMMdd_HHmmss"
    $文件名 = "screenshot_$时间戳"
}

$本地文件路径 = Join-Path $输出目录 "$文件名$扩展名"

& $HDC程序路径 file recv $手机端路径 $本地文件路径 2>&1 | Out-Null
if (-not (Test-Path $本地文件路径)) {
    输出错误 "拉取文件失败，本地文件不存在: $本地文件路径"
    exit 1
}
输出成功 "已保存到: $本地文件路径"

# ─── 清理手机临时文件 ─────────────────────────────────────────────────
& $HDC程序路径 shell rm -f $手机端路径 2>$null | Out-Null

# ─── 显示文件信息 ─────────────────────────────────────────────────────
$文件信息 = Get-Item $本地文件路径
$大小KB = [math]::Round($文件信息.Length / 1KB, 1)
Write-Host "`n  📱 截图完成!" -ForegroundColor Green
Write-Host "  文件: $本地文件路径"
Write-Host "  大小: ${大小KB} KB"

# ─── 复制到剪贴板 ─────────────────────────────────────────────────────
输出步骤 "复制到剪贴板"
Add-Type -AssemblyName System.Windows.Forms
$图片 = [System.Drawing.Image]::FromFile($本地文件路径)
[System.Windows.Forms.Clipboard]::SetImage($图片)
$图片.Dispose()
输出成功 "已复制到剪贴板"

# ─── 自动打开 ─────────────────────────────────────────────────────────
if ($打开) {
    输出步骤 "打开截图"
    Start-Process $本地文件路径
}
