<#!
.SYNOPSIS
    HDC 远程调试服务器（纯 PowerShell / .NET Socket + TLS 实现）
.DESCRIPTION
    使用 TcpListener + SslStream 直接监听 HTTPS/WSS（不经 HTTP.sys，无需管理员权限）。
    自动生成并复用局域网调试证书，供构建脚本注入到 Android WebView 调试信任列表。
    额外提供 AXS 二进制下载端点，供 debug 构建保持与 release 一致的在线下载安装流程。
    通过局域网接收手机端 Acode 的 console 日志，
    监视 www/build/ 变化并通知热重载，可在浏览器查看日志面板。
.PARAMETER 端口
    调试服务器端口固定为仓库常量；传入非固定值会直接失败
.PARAMETER 监视
  监视 www/build/ 变化并推送热重载
.PARAMETER 仅本机
  仅监听 127.0.0.1
.PARAMETER 前台
  前台运行服务器（默认行为为启动后台子进程并立即返回）
#>
param(
    [int]$端口 = 0,
    [switch]$监视,
    [switch]$仅本机,
    [switch]$前台,
    [switch]$内部后台进程
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "仓库常量.ps1")
$仓库固定调试服务器端口 = 获取仓库固定调试服务器端口
if ($PSBoundParameters.ContainsKey('端口')) {
    断言仓库固定调试服务器端口 -目标端口 $端口 -来源 'scripts/调试服务器.ps1 param'
}
$端口 = $仓库固定调试服务器端口

$脚本路径 = $MyInvocation.MyCommand.Path
$脚本目录 = Split-Path -Parent $脚本路径
$日志目录 = Join-Path $脚本目录 "logs"
if (-not (Test-Path $日志目录)) { New-Item -ItemType Directory -Path $日志目录 -Force | Out-Null }
$后台启动日志 = Join-Path $日志目录 "调试服务器-启动器.log"

function 写启动器日志([string]$消息) {
    $时间戳 = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    [System.IO.File]::AppendAllText(
        $后台启动日志,
        "$时间戳 $消息`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}

function 测试端口可连接([string]$主机, [int]$目标端口, [int]$超时毫秒 = 1000) {
    $客户端 = $null
    try {
        $客户端 = [System.Net.Sockets.TcpClient]::new()
        $异步结果 = $客户端.BeginConnect($主机, $目标端口, $null, $null)
        if (-not $异步结果.AsyncWaitHandle.WaitOne($超时毫秒, $false)) {
            return $false
        }
        $客户端.EndConnect($异步结果)
        return $true
    } catch {
        return $false
    } finally {
        if ($客户端) { $客户端.Dispose() }
    }
}

function 清理启动器残留端口([int]$目标端口) {
    $占用连接列表 = @(Get-NetTCPConnection -LocalPort $目标端口 -ErrorAction SilentlyContinue)
    $占用进程ID列表 = @($占用连接列表 | Select-Object -ExpandProperty OwningProcess -Unique)

    foreach ($占用进程ID in $占用进程ID列表) {
        try {
            # 默认后台模式必须在拉起新子进程前清掉残留监听；否则旧调试服务器会让后面的端口探测直接命中旧进程，启动器误判“新实例已就绪”，结果 metadata 保持旧地址，后续构建继续注入过期下载源。这里用独立前置清理逻辑，避免再依赖后文函数定义顺序。 仅调试用
            $占用进程 = [System.Diagnostics.Process]::GetProcessById([int]$占用进程ID)
            写启动器日志 "启动前清理残留端口占用: 端口=$目标端口 PID=$占用进程ID 进程=$($占用进程.ProcessName)"
            $占用进程.Kill()
            $占用进程.WaitForExit()
        } catch {
            写启动器日志 "启动前清理残留端口占用失败: 端口=$目标端口 PID=$占用进程ID 错误=$($_.Exception.Message)"
            throw
        }
    }
}

function 启动调试服务器后台子进程 {
    if (Test-Path $后台启动日志) { Remove-Item $后台启动日志 -Force -ErrorAction SilentlyContinue }
    写启动器日志 "准备启动后台调试服务器: 端口=$端口 监视=$([bool]$监视) 仅本机=$([bool]$仅本机)"

    清理启动器残留端口 $端口

    $参数列表 = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $脚本路径 + '"'),
        "-端口", [string]$端口,
        "-内部后台进程"
    )

    if ($监视) { $参数列表 += "-监视" }
    if ($仅本机) { $参数列表 += "-仅本机" }

    $启动进程 = Start-Process -FilePath "powershell.exe" -ArgumentList $参数列表 -WindowStyle Hidden -PassThru
    写启动器日志 "后台子进程已创建: PID=$($启动进程.Id)"
    $目标主机 = if ($仅本机) { "127.0.0.1" } else { "127.0.0.1" }

    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if ($启动进程.HasExited) {
            写启动器日志 "后台子进程启动失败: PID=$($启动进程.Id) ExitCode=$($启动进程.ExitCode)"
            throw "调试服务器后台进程启动后立即退出，退出码: $($启动进程.ExitCode)"
        }
        if (测试端口可连接 -主机 $目标主机 -目标端口 $端口 -超时毫秒 200) {
            写启动器日志 "后台调试服务器已就绪: PID=$($启动进程.Id) 端口=$端口"
            Write-Host "调试服务器已转入后台运行，PID=$($启动进程.Id)，端口=$端口" -ForegroundColor Green
            Write-Host "运行日志: $后台启动日志" -ForegroundColor DarkGray
            return
        }
    }

    写启动器日志 "后台调试服务器启动超时: PID=$($启动进程.Id) 端口=$端口"
    throw "调试服务器后台进程已启动，但在限定时间内未监听端口 $端口"
}

if (-not $前台 -and -not $内部后台进程) {
    启动调试服务器后台子进程
    return
}

# ─── 日志文件 ─────────────────────────────────────────────────────────
$证书目录 = Join-Path $PSScriptRoot "certs"
if (-not (Test-Path $证书目录)) { New-Item -ItemType Directory -Path $证书目录 -Force | Out-Null }
$日志文件 = Join-Path $日志目录 "调试服务器-运行时.log"
$调试证书Pfx路径 = Join-Path $证书目录 "调试服务器.pfx"
$调试证书Cer路径 = Join-Path $证书目录 "调试服务器.cer"
$调试证书元数据路径 = Join-Path $日志目录 "调试服务器-metadata.json"
$调试证书密码明文 = "Acode-Debug-Tls"
if (Test-Path $日志文件) { Remove-Item $日志文件 -Force -ErrorAction SilentlyContinue }

function 追加调试日志 {
    param(
        [string]$消息
    )

    $时间戳 = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    [System.IO.File]::AppendAllText(
        $日志文件,
        "$时间戳 $消息`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}

function 写调试日志 {
    param(
        [string]$消息,
        [string]$颜色 = "White",
        [switch]$不换行
    )

    追加调试日志 $消息
    if ($不换行) {
        Write-Host $消息 -ForegroundColor $颜色 -NoNewline
    } else {
        Write-Host $消息 -ForegroundColor $颜色
    }
}

# ─── 局域网 IP ───────────────────────────────────────────────────────
function 获取局域网IP {
    $候选 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.PrefixOrigin -ne "WellKnown" -and
        $_.IPAddress -notmatch '^169\.254\.' -and
        $_.IPAddress -ne '127.0.0.1' -and
        $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Hyper-V|WSL|VirtualBox|VMware|isatap|Teredo|Bluetooth|本地连接\*'
    }
    # 优先 WLAN/Wi-Fi/以太网等实际物理网卡（DHCP 分配的地址）
    $内网 = $候选 | Where-Object {
        $_.InterfaceAlias -match 'WLAN|Wi-Fi|以太网|Ethernet' -and $_.PrefixOrigin -eq 'Dhcp'
    } | Select-Object -First 1
    if ($内网) { return $内网.IPAddress }
    # fallback：任意 DHCP 私有 IP
    $内网 = $候选 | Where-Object {
        $_.PrefixOrigin -eq 'Dhcp' -and (
            $_.IPAddress -match '^192\.168\.' -or $_.IPAddress -match '^10\.' -or
            $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.'
        )
    } | Select-Object -First 1
    if ($内网) { return $内网.IPAddress }
    $任意 = $候选 | Select-Object -First 1
    if ($任意) { return $任意.IPAddress }
    return "127.0.0.1"
}

# ─── 清理端口占用 ────────────────────────────────────────────────────
function 清理端口占用([int]$目标端口) {
    $连接 = Get-NetTCPConnection -LocalPort $目标端口 -ErrorAction SilentlyContinue
    if (-not $连接) { return }
    foreach ($进程ID in ($连接 | Select-Object -ExpandProperty OwningProcess -Unique)) {
        if ($进程ID -and $进程ID -gt 4 -and $进程ID -ne $PID) {
            try {
                Stop-Process -Id $进程ID -Force -ErrorAction Stop
                写调试日志 "  ⚠ 已终止占用端口 $目标端口 的进程 PID=$进程ID" Yellow
            } catch {}
        }
    }
}

# ─── 防火墙 ──────────────────────────────────────────────────────────
function 配置防火墙([int]$目标端口) {
    $规则名 = "Acode-调试-$目标端口"
    try {
        $输出 = & netsh advfirewall firewall show rule name="$规则名" 2>&1
        if (($输出 -join "`n") -match "No rules match|没有与指定条件匹配的规则") {
            & netsh advfirewall firewall add rule name="$规则名" dir=in action=allow protocol=TCP localport=$目标端口 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                写调试日志 "  ✓ 已添加防火墙入站规则: TCP/$目标端口" Green
            }
        }
    } catch {}
}

function 获取调试证书元数据 {
    if (-not (Test-Path $调试证书元数据路径)) {
        return $null
    }

    try {
        return Get-Content $调试证书元数据路径 -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function 加载调试服务器证书 {
    if (-not (Test-Path $调试证书Pfx路径)) {
        return $null
    }

    $标志 = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $调试证书Pfx路径,
        $调试证书密码明文,
        $标志
    )
}

function 生成调试服务器证书([string]$主机IP) {
    if (Test-Path $调试证书Pfx路径) { Remove-Item $调试证书Pfx路径 -Force }
    if (Test-Path $调试证书Cer路径) { Remove-Item $调试证书Cer路径 -Force }

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $请求 = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=Acode Debug Server",
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )

        $SAN = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $SAN.AddDnsName("localhost")
        $SAN.AddIpAddress([System.Net.IPAddress]::Parse("127.0.0.1"))
        $SAN.AddIpAddress([System.Net.IPAddress]::Parse($主机IP))

        $请求.CertificateExtensions.Add($SAN.Build())
        $请求.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $false)
        )
        $请求.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature,
                $false
            )
        )

        $服务器身份 = [System.Security.Cryptography.OidCollection]::new()
        $服务器身份.Add([System.Security.Cryptography.Oid]::new("1.3.6.1.5.5.7.3.1")) | Out-Null
        $请求.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($服务器身份, $false)
        )

        $证书 = $请求.CreateSelfSigned(
            [System.DateTimeOffset]::Now.AddMinutes(-5),
            [System.DateTimeOffset]::Now.AddYears(1)
        )

        [System.IO.File]::WriteAllBytes(
            $调试证书Pfx路径,
            $证书.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $调试证书密码明文)
        )
        [System.IO.File]::WriteAllBytes(
            $调试证书Cer路径,
            $证书.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        )
    } finally {
        if ($rsa) { $rsa.Dispose() }
        if ($证书) { $证书.Dispose() }
    }

    return 加载调试服务器证书
}

function 确保调试服务器证书([string]$主机IP, [int]$目标端口) {
    $元数据 = 获取调试证书元数据
    $复用 = $null
    if ($元数据 -and
        $元数据.host -eq $主机IP -and
        [int]$元数据.port -eq $目标端口 -and
        (Test-Path $调试证书Pfx路径) -and
        (Test-Path $调试证书Cer路径)) {
        try {
            $复用 = 加载调试服务器证书
            if ($复用.NotAfter -le (Get-Date).AddDays(7)) {
                $复用 = $null
            }
        } catch {
            $复用 = $null
        }
    }

    if ($复用) {
        return $复用
    }

    return 生成调试服务器证书 $主机IP
}

function 写入调试证书元数据([string]$主机IP, [int]$目标端口) {
    $axsBaseUrl = "https://${主机IP}:${目标端口}/__axs"
    $axs版本 = 获取Axs资源版本映射
    $元数据 = [ordered]@{
        host = $主机IP
        port = $目标端口
        scheme = "https"
        wsScheme = "wss"
        scriptUrl = "https://${主机IP}:${目标端口}/__debug_client.js"
        logsUrl = "https://${主机IP}:${目标端口}/__logs"
        axsBaseUrl = $axsBaseUrl
        axsVersions = $axs版本
        axsUrls = [ordered]@{
            # Terminal.refreshAxs 只拿下载 URL 写入 .download-manifest；之前局域网调试一直复用固定 /__axs 路径，导致 acodex-server/axs 二进制更新后手机仍命中旧 manifest，继续跑旧 axs，看不到最新后端日志。这里把 URL 绑定到当前二进制指纹，让内容变化时 manifest 必然失效并强制重新下载。 仅调试用
            arm64 = "$axsBaseUrl/axs-musl-android-arm64?v=$($axs版本.arm64)"
            armv7 = "$axsBaseUrl/axs-musl-android-armv7?v=$($axs版本.armv7)"
            x64 = "$axsBaseUrl/axs-musl-android-x86_64?v=$($axs版本.x64)"
        }
        certificatePath = $调试证书Cer路径
        generatedAt = (Get-Date).ToString("o")
    }

    [System.IO.File]::WriteAllText(
        $调试证书元数据路径,
        ($元数据 | ConvertTo-Json -Depth 4),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $元数据
}

# ─── 常量 ────────────────────────────────────────────────────────────
$MIME类型 = @{
    ".html"="text/html; charset=utf-8"; ".js"="application/javascript; charset=utf-8"
    ".mjs"="application/javascript; charset=utf-8"; ".css"="text/css; charset=utf-8"
    ".json"="application/json; charset=utf-8"; ".svg"="image/svg+xml"
    ".png"="image/png"; ".jpg"="image/jpeg"; ".woff"="font/woff"
    ".woff2"="font/woff2"; ".ttf"="font/ttf"; ".ico"="image/x-icon"
}
$日志级别颜色 = @{ "log"="White"; "info"="Cyan"; "warn"="Yellow"; "error"="Red"; "debug"="Magenta" }
$script:Axs下载映射 = [ordered]@{
    "axs-musl-android-arm64" = Join-Path $PSScriptRoot "..\acodex-server\target\aarch64-unknown-linux-musl\release\axs"
    "axs-musl-android-armv7" = Join-Path $PSScriptRoot "..\acodex-server\target\armv7-unknown-linux-musleabihf\release\axs"
    "axs-musl-android-x86_64" = Join-Path $PSScriptRoot "..\acodex-server\target\x86_64-unknown-linux-musl\release\axs"
}

function 获取Axs资源版本映射 {
    $版本映射 = [ordered]@{}

    foreach ($文件名 in $script:Axs下载映射.Keys) {
        $文件路径 = [System.IO.Path]::GetFullPath($script:Axs下载映射[$文件名])
        if (-not (Test-Path $文件路径 -PathType Leaf)) {
            # 局域网调试只要求当前设备架构可用，不能因为未构建的其他架构产物缺失就让整个调试服务器起不来；否则 metadata 不会刷新，arm64 设备仍会继续复用旧 axs。缺失架构保留稳定占位值，真正请求该资源时再由下载端点按现有逻辑返回 503。 仅调试用
            $版本映射[$文件名.Replace("axs-musl-android-", "").Replace("x86_64", "x64")] = "missing"
            continue
        }

        # 这里必须基于文件内容生成稳定指纹，而不能只看时间戳；局域网调试复现里真正的问题是 URL 长期不变导致 .download-manifest 不失效，手机继续复用旧 axs。只有内容指纹进 URL，才能确保每次换二进制都强制刷新。同时这里改成纯 .NET SHA256，避免默认后台子进程在某些 PowerShell 宿主里拿不到 Get-FileHash 时直接起不来。 仅调试用
        $文件流 = [System.IO.File]::OpenRead($文件路径)
        try {
            $哈希器 = [System.Security.Cryptography.SHA256]::Create()
            try {
                $哈希字节 = $哈希器.ComputeHash($文件流)
            } finally {
                $哈希器.Dispose()
            }
        } finally {
            $文件流.Dispose()
        }

        $哈希 = ([System.BitConverter]::ToString($哈希字节)).Replace("-", "").ToLowerInvariant()
        $版本映射[$文件名.Replace("axs-musl-android-", "").Replace("x86_64", "x64")] = $哈希.Substring(0, 16)
    }

    return $版本映射
}

function 获取Axs下载响应 {
    param(
        [string]$路径
    )

    if ($路径.Contains('?')) {
        $路径 = $路径.Split('?', 2)[0]
    }

    $文件名 = $路径.Substring("/__axs/".Length)
    if ([string]::IsNullOrWhiteSpace($文件名)) {
        return @{ 状态 = "404 Not Found"; 类型 = "text/plain; charset=utf-8"; 正文 = [System.Text.Encoding]::UTF8.GetBytes("missing asset name") }
    }

    if (-not $script:Axs下载映射.Contains($文件名)) {
        return @{ 状态 = "404 Not Found"; 类型 = "text/plain; charset=utf-8"; 正文 = [System.Text.Encoding]::UTF8.GetBytes("unknown axs asset") }
    }

    $文件路径 = [System.IO.Path]::GetFullPath($script:Axs下载映射[$文件名])
    if (-not (Test-Path $文件路径 -PathType Leaf)) {
        return @{ 状态 = "503 Service Unavailable"; 类型 = "text/plain; charset=utf-8"; 正文 = [System.Text.Encoding]::UTF8.GetBytes("axs artifact unavailable: $文件名") }
    }

    return @{ 状态 = "200 OK"; 类型 = "application/octet-stream"; 正文 = [System.IO.File]::ReadAllBytes($文件路径) }
}

# ─── 调试客户端 JS ────────────────────────────────────────────────────
function 生成调试客户端JS([string]$IP, [int]$P) {
    return @"
(function(){
  if(window.__HDC_DEBUG_ACTIVE)return;
  window.__HDC_DEBUG_ACTIVE=true;
    var WS_URL="wss://${IP}:${P}";
    var ws=null,queue=[],reconnectTimer=null;
    function safeText(value){
        if(value===undefined)return "undefined";
        if(value===null)return "null";
        if(typeof value==="string")return value;
        if(value instanceof Error)return (value.message||String(value))+(value.stack?"\n"+value.stack:"");
        try{return JSON.stringify(value,function(k,val){
            if(typeof val==="function")return "[Function]";
            if(typeof HTMLElement!=="undefined"&&val instanceof HTMLElement)return val.outerHTML.substring(0,200);
            return val;
        })}catch(e){return "[无法序列化]"}
    }
  function connect(){
        try{ws=new WebSocket(WS_URL)}catch(e){return}
        ws.onopen=function(){
            while(queue.length)ws.send(queue.shift())
        };
        ws.onclose=function(){
            ws=null;
            if(!reconnectTimer)reconnectTimer=setTimeout(function(){reconnectTimer=null;connect()},3000)
        };
        ws.onerror=function(){};
    ws.onmessage=function(evt){
      try{var msg=JSON.parse(evt.data);
                if(msg.type==="reload")location.reload();
                else if(msg.type==="eval"){try{eval(msg.code)}catch(e){send({type:"error",message:e.message,stack:e.stack})}}
      }catch(e){}
    };
  }
  function send(obj){
    var data=JSON.stringify(obj);
    if(ws&&ws.readyState===1)ws.send(data);
    else if(queue.length<200)queue.push(data);
  }
    function safeClassName(value){
        try{return Object.prototype.toString.call(value)}catch(e){return "[class-error]"}
    }
        var debugBuildId=typeof window.__HDC_DEBUG_BUILD_ID==="string"?window.__HDC_DEBUG_BUILD_ID:"";
        var debugScriptUrl=typeof window.__HDC_DEBUG_SCRIPT_URL==="string"?window.__HDC_DEBUG_SCRIPT_URL:"";
    window.__HDC_DEBUG_PUSH=function(payload){
        if(!payload||typeof payload!=="object")return;
        if(!payload.timestamp)payload.timestamp=Date.now();
        send(payload);
    };
    function hookScriptLifecycle(){
        document.addEventListener("load",function(event){
            var target=event&&event.target;
            if(!target||target.tagName!=="SCRIPT")return;
            send({type:"console",level:"debug",args:["[script-load]",target.src||"[inline]"],timestamp:Date.now()});
        },true);
        document.addEventListener("error",function(event){
            var target=event&&event.target;
            if(!target||target.tagName!=="SCRIPT")return;
            send({type:"error",message:"Script load failed: "+(target.src||"[inline]"),timestamp:Date.now()});
        },true);
    }
    function hookFetchApi(){
        if(typeof window.fetch!=="function")return false;
        if(window.fetch.__hdcWrapped)return true;
        var originalFetch=window.fetch;
        function tryParseJson(text){
            if(typeof text!=="string")return text;
            try{return JSON.parse(text)}catch(e){return text}
        }
        function getRectSnapshot(element){
            if(!element||typeof element.getBoundingClientRect!=="function")return null;
            try{
                var rect=element.getBoundingClientRect();
                return {
                    width:Math.round(rect.width),
                    height:Math.round(rect.height),
                    top:Math.round(rect.top),
                    left:Math.round(rect.left)
                };
            }catch(e){
                return null;
            }
        }
        function getStyleSnapshot(element,keys){
            if(!element||!keys||!keys.length)return null;
            try{
                var computed=window.getComputedStyle(element);
                var snapshot={};
                for(var i=0;i<keys.length;i++)snapshot[keys[i]]=computed?computed[keys[i]]:null;
                return snapshot;
            }catch(e){
                return null;
            }
        }
        function getCanvasSnapshot(canvas){
            if(!canvas)return null;
            var contextType=null;
            try{
                if(typeof canvas.getContext==="function"){
                    if(canvas.getContext("webgl2"))contextType="webgl2";
                    else if(canvas.getContext("webgl"))contextType="webgl";
                    else if(canvas.getContext("2d"))contextType="2d";
                }
            }catch(e){}
            return {
                width:typeof canvas.width==="number"?canvas.width:null,
                height:typeof canvas.height==="number"?canvas.height:null,
                clientWidth:typeof canvas.clientWidth==="number"?canvas.clientWidth:null,
                clientHeight:typeof canvas.clientHeight==="number"?canvas.clientHeight:null,
                rect:getRectSnapshot(canvas),
                contextType:contextType,
                style:getStyleSnapshot(canvas,["display","visibility","opacity"])
            };
        }
        function getTextSample(element,maxLength){
            if(!element)return null;
            try{
                var text=String(element.textContent||"").replace(/\s+/g," ").trim();
                if(text.length>maxLength)return text.slice(0,maxLength);
                return text;
            }catch(e){
                return null;
            }
        }
        function collectTerminalLayoutSnapshot(){
            var activeTab=null;
            try{
                var activeTabElement=document.querySelector(".open-file-list li.active .text");
                activeTab=activeTabElement?String(activeTabElement.textContent||"").trim():null;
            }catch(e){}
            var visualViewport=null;
            try{
                if(window.visualViewport){
                    visualViewport={
                        width:Math.round(window.visualViewport.width),
                        height:Math.round(window.visualViewport.height),
                        offsetTop:Math.round(window.visualViewport.offsetTop),
                        offsetLeft:Math.round(window.visualViewport.offsetLeft),
                        pageTop:Math.round(window.visualViewport.pageTop||0)
                    };
                }
            }catch(e){}
            var terminals=[];
            try{
                var terminalNodes=document.querySelectorAll(".terminal-content");
                for(var i=0;i<terminalNodes.length;i++){
                    var node=terminalNodes[i];
                    var computed=null;
                    try{computed=window.getComputedStyle(node)}catch(e){}
                    var viewport=node.querySelector?node.querySelector(".xterm-viewport"):null;
                    var xterm=node.querySelector?node.querySelector(".xterm"):null;
                    var screen=node.querySelector?node.querySelector(".xterm-screen"):null;
                    var rows=node.querySelector?node.querySelector(".xterm-rows"):null;
                    var helper=node.querySelector?node.querySelector(".xterm-helpers"):null;
                    var accessibility=node.querySelector?node.querySelector(".xterm-accessibility, .xterm-accessibility-tree"):null;
                    var canvases=[];
                    try{
                        var canvasNodes=node.querySelectorAll?node.querySelectorAll(".xterm canvas"):[];
                        for(var j=0;j<canvasNodes.length;j++)canvases.push(getCanvasSnapshot(canvasNodes[j]));
                    }catch(e){}
                    var rowCount=0;
                    var nonEmptyRowCount=0;
                    try{
                        var rowNodes=rows&&rows.children?rows.children:[];
                        rowCount=rowNodes.length||0;
                        for(var k=0;k<rowNodes.length;k++){
                            if(String(rowNodes[k].textContent||"").trim())nonEmptyRowCount++;
                        }
                    }catch(e){}
                    terminals.push({
                        index:i,
                        id:node.id||null,
                        className:node.className||null,
                        connected:!!node.isConnected,
                        hasOffsetParent:!!node.offsetParent,
                        display:computed?computed.display:null,
                        visibility:computed?computed.visibility:null,
                        rect:getRectSnapshot(node),
                        xtermRect:getRectSnapshot(xterm),
                        xtermStyle:getStyleSnapshot(xterm,["display","visibility","opacity"]),
                        screenRect:getRectSnapshot(screen),
                        screenStyle:getStyleSnapshot(screen,["display","visibility","opacity"]),
                        rowsRect:getRectSnapshot(rows),
                        rowsStyle:getStyleSnapshot(rows,["display","visibility","opacity"]),
                        rowCount:rowCount,
                        nonEmptyRowCount:nonEmptyRowCount,
                        rowTextLength:rows&&typeof rows.textContent==="string"?rows.textContent.length:null,
                        rowTextSample:getTextSample(rows,120),
                        helperRect:getRectSnapshot(helper),
                        accessibilityRect:getRectSnapshot(accessibility),
                        accessibilityTextSample:getTextSample(accessibility,120),
                        canvasCount:canvases.length,
                        canvases:canvases,
                        viewportRect:getRectSnapshot(viewport),
                        viewportScrollTop:viewport&&typeof viewport.scrollTop==="number"?viewport.scrollTop:null,
                        viewportScrollHeight:viewport&&typeof viewport.scrollHeight==="number"?viewport.scrollHeight:null,
                        viewportClientHeight:viewport&&typeof viewport.clientHeight==="number"?viewport.clientHeight:null
                    });
                }
            }catch(e){}
            return {
                visibilityState:document.visibilityState||null,
                activeTab:activeTab,
                innerWidth:window.innerWidth,
                innerHeight:window.innerHeight,
                visualViewport:visualViewport,
                terminals:terminals
            };
        }
        function emitTerminalLayout(reason,extra,level){
            send({
                type:"console",
                level:level||"debug",
                args:["[terminal-layout]",reason,extra||{},collectTerminalLayoutSnapshot()],
                timestamp:Date.now()
            });
        }
        function hookTerminalLayoutDiagnostics(){
            if(window.__hdcTerminalLayoutHooked)return;
            window.__hdcTerminalLayoutHooked=true;

            var lastActiveTab="";
            function getActiveTabName(){
                try{
                    var activeTabElement=document.querySelector(".open-file-list li.active .text");
                    return activeTabElement?String(activeTabElement.textContent||"").trim():"";
                }catch(e){
                    return "";
                }
            }
            function emitIfActiveTabChanged(reason){
                var activeTabName=getActiveTabName();
                if(activeTabName===lastActiveTab)return;
                lastActiveTab=activeTabName;
                emitTerminalLayout(reason,{activeTab:activeTabName},"info");
            }

            emitIfActiveTabChanged("initial");

            try{
                var openFileList=document.querySelector(".open-file-list");
                if(openFileList&&typeof MutationObserver==="function"){
                    var observer=new MutationObserver(function(){
                        emitIfActiveTabChanged("mutation");
                    });
                    observer.observe(openFileList,{subtree:true,attributes:true,attributeFilter:["class"]});
                }
            }catch(e){}

            document.addEventListener("click",function(event){
                var tab=event&&event.target&&event.target.closest?event.target.closest(".open-file-list li"):null;
                if(!tab)return;
                emitTerminalLayout("tab-click",{text:safeText(tab.textContent||"")},"info");
                setTimeout(function(){emitIfActiveTabChanged("tab-click-post")},0);
                setTimeout(function(){emitTerminalLayout("tab-click-settled",{text:safeText(tab.textContent||"")},"info")},80);
            },true);

            document.addEventListener("touchstart",function(event){
                var target=event&&event.target;
                if(!target||!target.closest)return;
                var viewport=target.closest(".xterm-viewport");
                if(viewport){
                    emitTerminalLayout("viewport-touchstart",{
                        scrollTop:typeof viewport.scrollTop==="number"?viewport.scrollTop:null,
                        scrollHeight:typeof viewport.scrollHeight==="number"?viewport.scrollHeight:null,
                        clientHeight:typeof viewport.clientHeight==="number"?viewport.clientHeight:null
                    });
                    return;
                }
                var terminalContent=target.closest(".terminal-content");
                if(terminalContent){
                    emitTerminalLayout("terminal-touchstart",{id:terminalContent.id||null});
                }
            },true);

            var lastScrollEmitTs=0;
            document.addEventListener("scroll",function(event){
                var target=event&&event.target;
                if(!target||!target.classList||!target.classList.contains("xterm-viewport"))return;
                var now=Date.now();
                if(now-lastScrollEmitTs<2000)return;
                lastScrollEmitTs=now;
                emitTerminalLayout("viewport-scroll",{
                    scrollTop:typeof target.scrollTop==="number"?target.scrollTop:null,
                    scrollHeight:typeof target.scrollHeight==="number"?target.scrollHeight:null,
                    clientHeight:typeof target.clientHeight==="number"?target.clientHeight:null
                });
            },true);

            if(window.visualViewport&&typeof window.visualViewport.addEventListener==="function"){
                window.visualViewport.addEventListener("resize",function(){
                    emitTerminalLayout("visualViewport-resize",{},"info");
                },true);
            }

            document.addEventListener("visibilitychange",function(){
                emitTerminalLayout("visibilitychange",{state:document.visibilityState||null},"info");
            },true);
        }
        function shouldTraceFetch(resource){
            var url="";
            try{
                if(typeof resource==="string")url=resource;
                else if(resource&&typeof resource.url==="string")url=resource.url;
            }catch(e){}
            return url.indexOf("http://localhost:8767/")===0;
        }
        window.fetch=function(resource,options){
            var trace=shouldTraceFetch(resource);
            var method=(options&&options.method)||"GET";
            var url="";
            try{
                if(typeof resource==="string")url=resource;
                else if(resource&&typeof resource.url==="string")url=resource.url;
            }catch(e){}
            var startedAt=Date.now();
            if(trace){
                var body=null;
                try{
                    body=options&&typeof options.body==="string"?tryParseJson(options.body):safeText(options&&options.body);
                }catch(e){
                    body="[body-read-failed] "+safeText(e);
                }
                send({
                    type:"console",
                    level:"debug",
                    args:["[fetch]",method,url,"begin",{body:body}],
                    timestamp:startedAt
                });
            }
            var result;
            try{
                result=originalFetch.apply(this,arguments);
            }catch(error){
                if(trace){
                    send({type:"error",message:"fetch threw: "+method+" "+url+" "+safeText(error),stack:error&&error.stack,timestamp:Date.now()});
                }
                throw error;
            }
            if(!result||typeof result.then!=="function")return result;
            return result.then(function(response){
                if(trace){
                    send({
                        type:"console",
                        level:"debug",
                        args:["[fetch]",method,url,"resolved","status="+response.status,"ok="+(!!response.ok),"elapsedMs="+(Date.now()-startedAt)],
                        timestamp:Date.now()
                    });
                }
                return response;
            }).catch(function(error){
                if(trace){
                    send({type:"error",message:"fetch rejected: "+method+" "+url+" "+safeText(error),stack:error&&error.stack,timestamp:Date.now()});
                }
                throw error;
            });
        };
        window.fetch.__hdcWrapped=true;
        send({type:"console",level:"info",args:["[fetch-api] hooked"],timestamp:Date.now()});
        hookTerminalLayoutDiagnostics();
        return true;
    }
    function hookCordovaModuleApi(){
        if(!window.cordova||typeof window.cordova.require!=="function")return false;
        if(window.cordova.require.__hdcWrapped)return true;
        var originalRequire=window.cordova.require;
        var originalDefine=typeof window.cordova.define==="function"?window.cordova.define:null;
        window.cordova.require=function(id){
            try{return originalRequire.apply(this,arguments)}catch(error){
                send({type:"error",message:"cordova.require failed: "+id,stack:error&&error.stack,timestamp:Date.now()});
                throw error;
            }
        };
        window.cordova.require.__hdcWrapped=true;
        if(originalDefine&&!originalDefine.__hdcWrapped){
            window.cordova.define=function(id,factory){
                send({type:"console",level:"debug",args:["[cordova-define]",id],timestamp:Date.now()});
                return originalDefine.apply(this,arguments);
            };
            window.cordova.define.__hdcWrapped=true;
        }
        send({type:"console",level:"info",args:["[cordova-api] hooked"],timestamp:Date.now()});
        return true;
    }
    var terminalMirrorWindowStartedAt=Date.now();
    var terminalMirrorCharsInWindow=0;
    var terminalMirrorDropped=0;
    function resetTerminalMirrorBudgetIfNeeded(){
        var now=Date.now();
        if(now-terminalMirrorWindowStartedAt<1000)return;
        if(terminalMirrorDropped>0){
            send({type:"console",level:"warn",args:["[terminal-mirror] dropped frames",String(terminalMirrorDropped)],timestamp:now});
            terminalMirrorDropped=0;
        }
        terminalMirrorWindowStartedAt=now;
        terminalMirrorCharsInWindow=0;
    }
    function sanitizeTerminalText(text){
        return String(text||"")
            .replace(/\u001b\][^\u0007]*(?:\u0007|\u001b\\)/g,"")
            .replace(/\r/g,"")
            .replace(/\u0000/g,"");
    }
    function emitTerminalMirror(url,text){
        resetTerminalMirrorBudgetIfNeeded();
        var cleaned=sanitizeTerminalText(text);
        if(!cleaned.trim())return;
        if(terminalMirrorCharsInWindow>=32768){
            terminalMirrorDropped++;
            return;
        }
        if(cleaned.length>2048)cleaned=cleaned.slice(0,2048)+"\n...[truncated]";
        terminalMirrorCharsInWindow+=cleaned.length;
        send({type:"console",level:"debug",args:["[terminal]",url,cleaned],timestamp:Date.now()});
    }
    function decodeTerminalPayload(data){
        if(typeof data==="string")return Promise.resolve(data);
        if(typeof ArrayBuffer!=="undefined"&&data instanceof ArrayBuffer){
            return Promise.resolve(new TextDecoder("utf-8",{fatal:false}).decode(new Uint8Array(data)));
        }
        if(typeof Blob!=="undefined"&&data instanceof Blob){
            return data.text();
        }
        return Promise.resolve("");
    }
    function hookTerminalSocket(socket,url){
        if(typeof url!=="string")return socket;
        if(url.indexOf("ws://localhost:")!==0||url.indexOf("/terminals/")===-1)return socket;
        send({type:"console",level:"info",args:["[terminal-mirror] hooked",url],timestamp:Date.now()});
        socket.addEventListener("message",function(evt){
            decodeTerminalPayload(evt.data).then(function(text){
                emitTerminalMirror(url,text);
            }).catch(function(err){
                send({type:"console",level:"warn",args:["[terminal-mirror] decode failed",safeText(err)],timestamp:Date.now()});
            });
        });
        return socket;
    }
    var NativeWebSocket=window.WebSocket;
    function PatchedWebSocket(url,protocols){
        var socket=arguments.length>1?new NativeWebSocket(url,protocols):new NativeWebSocket(url);
        return hookTerminalSocket(socket,String(url||""));
    }
    PatchedWebSocket.prototype=NativeWebSocket.prototype;
    try{
        ["CONNECTING","OPEN","CLOSING","CLOSED"].forEach(function(key){
            Object.defineProperty(PatchedWebSocket,key,{value:NativeWebSocket[key]});
        });
    }catch(e){}
    window.WebSocket=PatchedWebSocket;
    function wrapTerminalMethod(target,name,wrapperTag){
        if(!target||typeof target[name]!=="function")return false;
        var original=target[name];
        if(original.__hdcWrapped)return true;
        function wrapTerminalCallback(methodName,callbackIndex,callback,label){
            if(typeof callback!=="function")return callback;
            if(callback.__hdcWrappedCallback)return callback;
            var wrappedCallback=function(){
                var callbackArgs=[];
                for(var j=0;j<arguments.length;j++)callbackArgs.push(arguments[j]);
                send({type:"console",level:label,args:["[terminal-api-stream]",methodName,"callback#"+callbackIndex,safeText(callbackArgs)],timestamp:Date.now()});
                return callback.apply(this,arguments);
            };
            wrappedCallback.__hdcWrappedCallback=true;
            return wrappedCallback;
        }
        var wrapped=function(){
            var args=[];
            for(var i=0;i<arguments.length;i++)args.push(arguments[i]);
            send({type:"console",level:"info",args:[wrapperTag,name,"begin",safeText(args)],timestamp:Date.now()});
            if(name==="install"||name==="startAxs"){
                for(var k=0;k<args.length;k++){
                    if(typeof args[k]!=="function")continue;
                    var callbackLevel=(k===0&&name==="install")||(k===1&&name==="startAxs")?"info":"error";
                    args[k]=wrapTerminalCallback(name,k,args[k],callbackLevel);
                }
            }
            try{
                var result=original.apply(this,args);
                if(result&&typeof result.then==="function"){
                    return result.then(function(value){
                        send({type:"console",level:"info",args:[wrapperTag,name,"resolved",safeText(value)],timestamp:Date.now()});
                        return value;
                    }).catch(function(error){
                        send({type:"console",level:"error",args:[wrapperTag,name,"rejected",safeText(error)],timestamp:Date.now()});
                        throw error;
                    });
                }
                send({type:"console",level:"info",args:[wrapperTag,name,"returned",safeText(result)],timestamp:Date.now()});
                return result;
            }catch(error){
                send({type:"console",level:"error",args:[wrapperTag,name,"threw",safeText(error)],timestamp:Date.now()});
                throw error;
            }
        };
        wrapped.__hdcWrapped=true;
        target[name]=wrapped;
        return true;
    }
    function hookTerminalApi(){
        var terminal=window.Terminal;
        if(!terminal||typeof terminal!=="object")return false;
        var hooked=false;
        ["isInstalled","install","startAxs","stopAxs","isAxsRunning"].forEach(function(name){
            if(wrapTerminalMethod(terminal,name,"[terminal-api]"))hooked=true;
        });
        return hooked;
    }
    (function waitTerminalApi(attempt){
        if(hookTerminalApi()){
            send({type:"console",level:"info",args:["[terminal-api] hooked"],timestamp:Date.now()});
            return;
        }
        if(attempt>=120)return;
        setTimeout(function(){waitTerminalApi(attempt+1)},250);
    })(0);
    (function waitCordovaApi(attempt){
        if(hookCordovaModuleApi())return;
        if(attempt>=120)return;
        setTimeout(function(){waitCordovaApi(attempt+1)},250);
    })(0);
    hookFetchApi();
    hookScriptLifecycle();
        if(debugBuildId){
                send({type:"console",level:"info",args:["[debug-build]","buildId="+debugBuildId,"scriptUrl="+debugScriptUrl,"href="+location.href],timestamp:Date.now()});
        }
    send({type:"console",level:"info",args:["[env]","userAgent="+navigator.userAgent,"processType="+typeof window.process,"processClass="+safeClassName(window.process),"hasCordova="+(!!window.cordova)],timestamp:Date.now()});
  var _c={};
  ["log","info","warn","error","debug"].forEach(function(l){
    _c[l]=console[l];
    console[l]=function(){
      _c[l].apply(console,arguments);
            var args=[];
            for(var i=0;i<arguments.length;i++)args.push(safeText(arguments[i]));
      send({type:"console",level:l,args:args,timestamp:Date.now()});
    };
  });
    window.addEventListener("error",function(e){
        var parts=[e.message];
        if(e.filename)parts.push("@"+e.filename+":"+e.lineno+":"+e.colno);
        send({type:"error",message:parts.join(" "),filename:e.filename,lineno:e.lineno,colno:e.colno,stack:e.error&&e.error.stack,timestamp:Date.now()})
    });
    window.addEventListener("unhandledrejection",function(e){
        send({type:"error",message:"UnhandledRejection: "+(e.reason&&e.reason.message||e.reason),stack:e.reason&&e.reason.stack,timestamp:Date.now()})
    });
  setInterval(function(){send({type:"ping"})},30000);
  connect();
})();
"@
}

# ─── 日志查看器 HTML ──────────────────────────────────────────────────
function 生成日志查看器HTML {
    return @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>HDC 调试日志</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font:13px/1.4 'Cascadia Code','Consolas',monospace;background:#1e1e2e;color:#cdd6f4}
#toolbar{position:fixed;top:0;left:0;right:0;height:40px;background:#181825;display:flex;align-items:center;padding:0 12px;gap:8px;z-index:10;border-bottom:1px solid #313244}
#toolbar button{background:#313244;color:#cdd6f4;border:none;padding:4px 12px;border-radius:4px;cursor:pointer;font-size:12px}
#toolbar button:hover{background:#45475a}
#filter{background:#313244;color:#cdd6f4;border:1px solid #45475a;padding:4px 8px;border-radius:4px;flex:1;max-width:300px;font-size:12px}
#logs{padding:48px 12px 12px}
.entry{padding:3px 0;border-bottom:1px solid #21212e;white-space:pre-wrap;word-break:break-all}
.entry .time{color:#6c7086;margin-right:8px}
.entry.log .level{color:#a6adc8} .entry.info .level{color:#89b4fa}
.entry.warn .level{color:#f9e2af} .entry.warn{background:#f9e2af08}
.entry.error .level{color:#f38ba8} .entry.error{background:#f38ba808}
.entry.debug .level{color:#cba6f7}
.count{background:#45475a;color:#cdd6f4;border-radius:8px;padding:0 6px;font-size:11px;margin-left:4px}
</style></head><body>
<div id="toolbar">
  <strong style="color:#89b4fa">HDC 调试</strong>
  <input id="filter" placeholder="过滤日志...">
  <button onclick="document.getElementById('logs').innerHTML='';n=0;cnt.textContent='0'">清空</button>
  <span id="status" style="color:#a6e3a1">&#9679;</span>
  <span class="count" id="cnt">0</span>
</div>
<div id="logs"></div>
<script>
var logs=document.getElementById('logs'),cnt=document.getElementById('cnt'),status=document.getElementById('status'),filter=document.getElementById('filter'),n=0;
var ws=new WebSocket("wss://"+location.host);
ws.onopen=function(){status.style.color='#a6e3a1'};
ws.onclose=function(){status.style.color='#f38ba8';setTimeout(function(){location.reload()},3000)};
ws.onmessage=function(e){try{var m=JSON.parse(e.data);if(m.type==='console'||m.type==='error'){
  var level=m.level||'error',text=(m.args||[m.message]).map(function(a){return typeof a==='string'?a:JSON.stringify(a,null,2)}).join(' ');
  if(m.stack)text+='\n'+m.stack;var f=filter.value,div=document.createElement('div');
  div.className='entry '+level;
  div.innerHTML='<span class="time">'+(new Date(m.timestamp)).toLocaleTimeString()+'</span><span class="level">['+level.toUpperCase()+']</span> '+esc(text);
  if(f&&text.toLowerCase().indexOf(f.toLowerCase())===-1)div.style.display='none';
  logs.appendChild(div);n++;cnt.textContent=n;if(n>2000){logs.removeChild(logs.firstChild);n--}logs.scrollTop=logs.scrollHeight;
}}catch(ex){}};
filter.oninput=function(){var f=filter.value.toLowerCase(),es=logs.getElementsByClassName('entry');for(var i=0;i<es.length;i++)es[i].style.display=(!f||es[i].textContent.toLowerCase().indexOf(f)!==-1)?'':'none'};
function esc(t){var d=document.createElement('div');d.textContent=t;return d.innerHTML}
</script></body></html>
'@
}

# ─── TCP 流操作 ───────────────────────────────────────────────────────
function 读满([System.IO.Stream]$流, [byte[]]$缓冲, [int]$长度) {
    $已读 = 0
    while ($已读 -lt $长度) {
        $n = $流.Read($缓冲, $已读, $长度 - $已读)
        if ($n -eq 0) { return $false }
        $已读 += $n
    }
    return $true
}

function 读取HTTP请求([System.IO.Stream]$流) {
    $缓冲 = [byte[]]::new(8192)
    $已读 = 0
    while ($已读 -lt 8192) {
        $n = $流.Read($缓冲, $已读, 8192 - $已读)
        if ($n -eq 0) { return $null }
        $已读 += $n
        for ($i = [Math]::Max(0, $已读 - $n - 3); $i -le $已读 - 4; $i++) {
            if ($缓冲[$i] -eq 13 -and $缓冲[$i+1] -eq 10 -and $缓冲[$i+2] -eq 13 -and $缓冲[$i+3] -eq 10) {
                return [System.Text.Encoding]::ASCII.GetString($缓冲, 0, $i + 4)
            }
        }
    }
    return $null
}

function 发送HTTP响应([System.IO.Stream]$流, [string]$状态, [string]$内容类型, [byte[]]$正文) {
    $头 = "HTTP/1.1 $状态`r`nContent-Type: $内容类型`r`nContent-Length: $($正文.Length)`r`nAccess-Control-Allow-Origin: *`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
    $头字节 = [System.Text.Encoding]::ASCII.GetBytes($头)
    $流.Write($头字节, 0, $头字节.Length)
    if ($正文.Length -gt 0) { $流.Write($正文, 0, $正文.Length) }
    $流.Flush()
}

# ─── WebSocket 协议 ──────────────────────────────────────────────────
function WS握手([string]$头部, [System.IO.Stream]$流) {
    if ($头部 -notmatch 'Sec-WebSocket-Key:\s*(\S+)') { return $false }
    $密钥 = $Matches[1]
    $哈希 = [System.Security.Cryptography.SHA1]::Create().ComputeHash(
        [System.Text.Encoding]::ASCII.GetBytes($密钥 + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    $接受值 = [System.Convert]::ToBase64String($哈希)
    $响应 = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Accept: $接受值`r`n`r`n"
    $字节 = [System.Text.Encoding]::ASCII.GetBytes($响应)
    $流.Write($字节, 0, $字节.Length)
    $流.Flush()
    return $true
}

function 发送WS文本帧([System.IO.Stream]$流, [string]$文本) {
    $载荷 = [System.Text.Encoding]::UTF8.GetBytes($文本)
    $帧头 = [System.Collections.Generic.List[byte]]::new()
    $帧头.Add(0x81)  # FIN + Text
    if ($载荷.Length -lt 126) {
        $帧头.Add([byte]$载荷.Length)
    } elseif ($载荷.Length -lt 65536) {
        $帧头.Add(126)
        $帧头.Add([byte](($载荷.Length -shr 8) -band 0xFF))
        $帧头.Add([byte]($载荷.Length -band 0xFF))
    } else {
        $帧头.Add(127)
        for ($i = 7; $i -ge 0; $i--) { $帧头.Add([byte](($载荷.Length -shr ($i * 8)) -band 0xFF)) }
    }
    $输出 = [byte[]]::new($帧头.Count + $载荷.Length)
    $帧头.CopyTo($输出)
    [System.Array]::Copy($载荷, 0, $输出, $帧头.Count, $载荷.Length)
    $流.Write($输出, 0, $输出.Length)
    $流.Flush()
}

function 发送WS关闭帧([System.IO.Stream]$流) {
    try { $流.Write([byte[]]@(0x88, 0x00), 0, 2); $流.Flush() } catch {}
}

function 发送WSpong帧([System.IO.Stream]$流, [byte[]]$载荷) {
    $帧头 = [System.Collections.Generic.List[byte]]::new()
    $帧头.Add(0x8A)  # FIN + Pong
    $帧头.Add([byte]$载荷.Length)
    $输出 = [byte[]]::new($帧头.Count + $载荷.Length)
    $帧头.CopyTo($输出)
    if ($载荷.Length -gt 0) { [System.Array]::Copy($载荷, 0, $输出, $帧头.Count, $载荷.Length) }
    $流.Write($输出, 0, $输出.Length)
    $流.Flush()
}

function 读取WS帧([System.IO.Stream]$流) {
    $头 = [byte[]]::new(2)
    if (-not (读满 $流 $头 2)) { return $null }

    $opcode = $头[0] -band 0x0F
    $有掩码 = ($头[1] -band 0x80) -ne 0
    [long]$长度 = $头[1] -band 0x7F

    if ($长度 -eq 126) {
        $扩展 = [byte[]]::new(2)
        if (-not (读满 $流 $扩展 2)) { return $null }
        $长度 = ([long]$扩展[0] -shl 8) -bor [long]$扩展[1]
    } elseif ($长度 -eq 127) {
        $扩展 = [byte[]]::new(8)
        if (-not (读满 $流 $扩展 8)) { return $null }
        $长度 = 0L
        for ($i = 0; $i -lt 8; $i++) { $长度 = ($长度 -shl 8) -bor [long]$扩展[$i] }
    }

    if ($长度 -gt 1048576) { return $null }  # 上限 1MB

    $掩码 = $null
    if ($有掩码) {
        $掩码 = [byte[]]::new(4)
        if (-not (读满 $流 $掩码 4)) { return $null }
    }

    $载荷 = [byte[]]::new($长度)
    if ($长度 -gt 0 -and -not (读满 $流 $载荷 ([int]$长度))) { return $null }

    if ($有掩码) {
        for ($i = 0; $i -lt $长度; $i++) { $载荷[$i] = $载荷[$i] -bxor $掩码[$i % 4] }
    }

    switch ($opcode) {
        1 { return @{ 类型 = "文本"; 数据 = [System.Text.Encoding]::UTF8.GetString($载荷) } }
        8 { return @{ 类型 = "关闭" } }
        9 { 发送WSpong帧 $流 $载荷; return @{ 类型 = "ping" } }
        default { return @{ 类型 = "其他" } }
    }
}

$script:WS客户端列表 = [System.Collections.Generic.List[hashtable]]::new()

function 广播([string]$数据) {
    for ($i = $script:WS客户端列表.Count - 1; $i -ge 0; $i--) {
        try {
            发送WS文本帧 $script:WS客户端列表[$i].流 $数据
        } catch {
            try { $script:WS客户端列表[$i].TCP.Close() } catch {}
            写调试日志 "[断开] $($script:WS客户端列表[$i].来源)" Yellow
            $script:WS客户端列表.RemoveAt($i)
        }
    }
}

function 处理消息([string]$原始文本) {
    try { $消息 = $原始文本 | ConvertFrom-Json } catch {
        写调试日志 "  [原始] $原始文本" DarkGray; return
    }
    switch ($消息.type) {
        "console" {
            $级别 = if ($消息.level) { $消息.level } else { "log" }
            $颜色 = if ($日志级别颜色[$级别]) { $日志级别颜色[$级别] } else { "White" }
            $时间 = if ($消息.timestamp) {
                [DateTimeOffset]::FromUnixTimeMilliseconds([long]$消息.timestamp).LocalDateTime.ToString("HH:mm:ss")
            } else { (Get-Date).ToString("HH:mm:ss") }
            $参数列表 = ($消息.args | ForEach-Object {
                if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 4 -Compress }
            }) -join " "
            追加调试日志 "$时间 [$($级别.ToUpper())] $参数列表"
            Write-Host "$时间 " -ForegroundColor DarkGray -NoNewline
            Write-Host "[$($级别.ToUpper())] " -ForegroundColor $颜色 -NoNewline
            Write-Host $参数列表
            广播 $原始文本
        }
        "error" {
            $时间 = if ($消息.timestamp) {
                [DateTimeOffset]::FromUnixTimeMilliseconds([long]$消息.timestamp).LocalDateTime.ToString("HH:mm:ss")
            } else { (Get-Date).ToString("HH:mm:ss") }
            $定位 = if ($消息.filename) { " ($($消息.filename):$($消息.lineno):$($消息.colno))" } else { "" }
            追加调试日志 "$时间 [未捕获错误] $($消息.message)$定位"
            Write-Host "$时间 " -ForegroundColor DarkGray -NoNewline
            Write-Host "[未捕获错误] " -ForegroundColor Red -NoNewline
            Write-Host ($消息.message + $定位)
            if ($消息.stack) {
                追加调试日志 $消息.stack
                Write-Host $消息.stack -ForegroundColor DarkGray
            }
            广播 $原始文本
        }
        "ping" {}
        default {
            写调试日志 "  [未知] $原始文本" DarkGray
            广播 $原始文本
        }
    }
}

function 处理新连接([System.Net.Sockets.TcpClient]$tcp客户端) {
    $原始流 = $tcp客户端.GetStream()
    $流 = [System.Net.Security.SslStream]::new($原始流, $false)
    $来源 = try { $tcp客户端.Client.RemoteEndPoint.ToString() } catch { "unknown" }

    try {
        $流.AuthenticateAsServer(
            $script:调试服务器证书,
            $false,
            [System.Security.Authentication.SslProtocols]::Tls12,
            $false
        )
    } catch {
        写调试日志 "[TLS失败] $来源 $($_.Exception.Message)" Red
        try { $流.Dispose() } catch {}
        $tcp客户端.Close()
        return
    }

    $流.ReadTimeout = 5000
    $流.WriteTimeout = 5000

    $头部 = 读取HTTP请求 $流
    if (-not $头部) {
        写调试日志 "[HTTP失败] $来源 未读取到完整请求头" Yellow
        try { $流.Dispose() } catch {}
        $tcp客户端.Close()
        return
    }

    $路径 = if ($头部 -match '^\w+\s+(\S+)') { $Matches[1] } else { "/" }
    $方法 = if ($头部 -match '^(\w+)\s+') { $Matches[1] } else { "UNKNOWN" }

    # WebSocket 升级
    if ($头部 -match '(?i)Upgrade:\s*websocket') {
        if (WS握手 $头部 $流) {
            写调试日志 "[WS连接] $来源 $路径" Green
            $流.ReadTimeout = 5000
            $script:WS客户端列表.Add(@{ 流 = $流; TCP = $tcp客户端; 来源 = $来源 })
        } else {
            写调试日志 "[WS失败] $来源 $路径 握手失败" Yellow
            try { $流.Dispose() } catch {}
            $tcp客户端.Close()
        }
        return
    }

    # HTTP 路由
    $响应状态 = "500 Internal Server Error"
    try {
        switch ($路径) {
            "/__debug_client.js" {
                $正文 = [System.Text.Encoding]::UTF8.GetBytes((生成调试客户端JS $局域网IP $端口))
                $响应状态 = "200 OK"
                发送HTTP响应 $流 $响应状态 "application/javascript; charset=utf-8" $正文
            }
            "/__logs" {
                $正文 = [System.Text.Encoding]::UTF8.GetBytes((生成日志查看器HTML))
                $响应状态 = "200 OK"
                发送HTTP响应 $流 $响应状态 "text/html; charset=utf-8" $正文
            }
            default {
                if ($路径.StartsWith("/__axs/", [System.StringComparison]::Ordinal)) {
                    $响应 = 获取Axs下载响应 -路径 $路径
                    $响应状态 = $响应.状态
                    发送HTTP响应 $流 $响应状态 $响应.类型 $响应.正文
                } else {
                    $相对路径 = if ($路径 -eq "/") { "index.html" } else { $路径.TrimStart("/") }
                    $文件路径 = Join-Path $Www目录 ($相对路径.Replace("/", [System.IO.Path]::DirectorySeparatorChar))
                    $规范路径 = [System.IO.Path]::GetFullPath($文件路径)
                    if (-not $规范路径.StartsWith($Www目录, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $响应状态 = "403 Forbidden"
                        发送HTTP响应 $流 $响应状态 "text/plain" ([byte[]]@())
                    } elseif (-not (Test-Path $规范路径 -PathType Leaf)) {
                        $响应状态 = "404 Not Found"
                        发送HTTP响应 $流 $响应状态 "text/plain" ([byte[]]@())
                    } else {
                        $扩展名 = [System.IO.Path]::GetExtension($规范路径)
                        $类型 = if ($MIME类型[$扩展名]) { $MIME类型[$扩展名] } else { "application/octet-stream" }
                        $响应状态 = "200 OK"
                        发送HTTP响应 $流 $响应状态 $类型 ([System.IO.File]::ReadAllBytes($规范路径))
                    }
                }
            }
        }
        写调试日志 "[HTTP] $来源 $方法 $路径 -> $响应状态" Cyan
    } catch {
        写调试日志 "[HTTP异常] $来源 $方法 $路径 $($_.Exception.Message)" Red
        throw
    } finally {
        try { $流.Dispose() } catch {}
        $tcp客户端.Close()
    }
}

# ─── 主流程 ──────────────────────────────────────────────────────────
$局域网IP = if ($仅本机) { "127.0.0.1" } else { 获取局域网IP }
$Www目录 = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "Acode\www"
$script:调试服务器证书 = 确保调试服务器证书 -主机IP $局域网IP -目标端口 $端口
$调试服务器元数据 = 写入调试证书元数据 -主机IP $局域网IP -目标端口 $端口

清理端口占用 $端口
配置防火墙 $端口

$绑定地址 = if ($仅本机) { [System.Net.IPAddress]::Loopback } else { [System.Net.IPAddress]::Any }
$tcp监听器 = [System.Net.Sockets.TcpListener]::new($绑定地址, $端口)
$tcp监听器.Start()

Write-Host ""
写调试日志 "╔══════════════════════════════════════════════╗" Green
写调试日志 "║     HDC 远程调试服务器已启动                ║" Green
写调试日志 "╠══════════════════════════════════════════════╣" Green
Write-Host "║ 局域网: " -ForegroundColor Green -NoNewline
Write-Host "https://${局域网IP}:${端口}" -ForegroundColor Cyan -NoNewline
Write-Host "               ║" -ForegroundColor Green
追加调试日志 "║ 局域网: https://${局域网IP}:${端口}               ║"
Write-Host "║ 日志:   " -ForegroundColor Green -NoNewline
Write-Host "https://${局域网IP}:${端口}/__logs" -ForegroundColor Cyan -NoNewline
Write-Host "        ║" -ForegroundColor Green
追加调试日志 "║ 日志:   https://${局域网IP}:${端口}/__logs        ║"
Write-Host "║ AXS:    " -ForegroundColor Green -NoNewline
Write-Host $调试服务器元数据.axsUrls.arm64 -ForegroundColor Cyan -NoNewline
Write-Host " ║" -ForegroundColor Green
追加调试日志 "║ AXS:    $($调试服务器元数据.axsUrls.arm64) ║"
Write-Host "║ 监视:   " -ForegroundColor Green -NoNewline
if ($监视) { Write-Host "已开启" -ForegroundColor Green -NoNewline } else { Write-Host "未开启" -ForegroundColor DarkGray -NoNewline }
Write-Host "                              ║" -ForegroundColor Green
追加调试日志 "║ 监视:   $(if ($监视) { '已开启' } else { '未开启' })                              ║"
写调试日志 "╚══════════════════════════════════════════════╝" Green
Write-Host ""
写调试日志 "提示: 确保手机和电脑在同一局域网" DarkGray
写调试日志 "证书: $调试证书Cer路径" DarkGray
写调试日志 "元数据: $调试证书元数据路径" DarkGray
Write-Host ""

# ─── 文件监视（独立 Runspace，不依赖 PS 事件队列）─────────────────────
$共享 = [hashtable]::Synchronized(@{ 变化时间 = 0L; 文件名 = "" })
$监视PS = $null
if ($监视) {
    $构建目录 = Join-Path $Www目录 "build"
    if (Test-Path $构建目录) {
        $监视PS = [powershell]::Create()
        $监视PS.Runspace = [runspacefactory]::CreateRunspace()
        $监视PS.Runspace.Open()
        $监视PS.AddScript({
            param($目录, $共享)
            $w = [System.IO.FileSystemWatcher]::new($目录)
            $w.IncludeSubdirectories = $true
            while ($true) {
                $r = $w.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
                if (-not $r.TimedOut) {
                    $共享.变化时间 = [System.DateTimeOffset]::Now.ToUnixTimeMilliseconds()
                    $共享.文件名 = $r.Name
                }
            }
        }).AddArgument($构建目录).AddArgument($共享) | Out-Null
        $监视PS.BeginInvoke() | Out-Null
        Write-Host "[监视] 正在监视 www/build/ 的变化..." -ForegroundColor Blue
    } else {
        Write-Host "⚠ www/build/ 不存在，跳过监视" -ForegroundColor Yellow
    }
}

# ─── 事件循环 ─────────────────────────────────────────────────────────
try {
    while ($true) {
        # 接受新连接
        while ($tcp监听器.Pending()) {
            try { 处理新连接 ($tcp监听器.AcceptTcpClient()) }
            catch { Write-Host "[错误] $_" -ForegroundColor Red }
        }

        # 轮询 WS 客户端
        $死链 = [System.Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $script:WS客户端列表.Count; $i++) {
            $ws = $script:WS客户端列表[$i]
            if (-not $ws.TCP.Connected) { $死链.Add($i); continue }
            try {
                if ($ws.TCP.Available -gt 0) {
                    $帧 = 读取WS帧 $ws.流
                    if (-not $帧 -or $帧.类型 -eq "关闭") {
                        发送WS关闭帧 $ws.流
                        $死链.Add($i); continue
                    }
                    if ($帧.类型 -eq "文本" -and $帧.数据.Length -gt 0) { 处理消息 $帧.数据 }
                }
            } catch [System.IO.IOException] {
                if ($_.Exception.InnerException -is [System.Net.Sockets.SocketException] -and $_.Exception.InnerException.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                    continue
                }
                $死链.Add($i)
            } catch {
                $死链.Add($i)
            }
        }
        for ($j = $死链.Count - 1; $j -ge 0; $j--) {
            $ws = $script:WS客户端列表[$死链[$j]]
            try { $ws.TCP.Close() } catch {}
            $script:WS客户端列表.RemoveAt($死链[$j])
            Write-Host "[断开] $($ws.来源)" -ForegroundColor Yellow
        }

        # 热重载防抖（变化后等 500ms 再触发）
        if ($共享.变化时间 -gt 0) {
            $已过 = [System.DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $共享.变化时间
            if ($已过 -ge 500) {
                $文件名 = $共享.文件名
                $共享.变化时间 = 0L
                Write-Host "[热重载] 检测到变化: $文件名" -ForegroundColor Blue
                $重载消息 = @{ type = "reload"; file = $文件名 } | ConvertTo-Json -Compress
                广播 $重载消息
            }
        }

        [System.Threading.Thread]::Sleep(50)
    }
} finally {
    if ($监视PS) { $监视PS.Stop(); $监视PS.Runspace.Close(); $监视PS.Dispose() }
    $tcp监听器.Stop()
    foreach ($ws in $script:WS客户端列表) { try { $ws.TCP.Close() } catch {} }
    Write-Host "`n调试服务器已关闭" -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch {}
}
