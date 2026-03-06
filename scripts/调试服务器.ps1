<#
.SYNOPSIS
  HDC 远程调试服务器（纯 PowerShell / .NET Socket 实现）
.DESCRIPTION
  使用 TcpListener 直接监听 TCP（不经 HTTP.sys，无需管理员权限）。
  手动解析 HTTP 请求和 WebSocket 帧，与 Node.js 服务器功能完全相同。
  通过局域网接收手机端 Acode 的 console 日志，
  监视 www/build/ 变化并通知热重载，可在浏览器查看日志面板。
.PARAMETER 端口
  监听端口（默认 8092）
.PARAMETER 监视
  监视 www/build/ 变化并推送热重载
.PARAMETER 仅本机
  仅监听 127.0.0.1
#>
param(
    [int]$端口 = 8092,
    [switch]$监视,
    [switch]$仅本机
)

$ErrorActionPreference = "Stop"

# ─── 日志文件 ─────────────────────────────────────────────────────────
$日志目录 = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $日志目录)) { New-Item -ItemType Directory -Path $日志目录 -Force | Out-Null }
$日志文件 = Join-Path $日志目录 "调试服务器.log"
Start-Transcript -Path $日志文件 -Force | Out-Null

# ─── 局域网 IP ───────────────────────────────────────────────────────
function 获取局域网IP {
    $候选 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.PrefixOrigin -ne "WellKnown" -and
        $_.IPAddress -notmatch '^169\.254\.' -and
        $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Hyper-V|WSL|VirtualBox|VMware|isatap|Teredo|Bluetooth'
    }
    $内网 = $候选 | Where-Object {
        $_.IPAddress -match '^192\.168\.' -or $_.IPAddress -match '^10\.' -or
        $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.'
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
                Write-Host "  ⚠ 已终止占用端口 $目标端口 的进程 PID=$进程ID" -ForegroundColor Yellow
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
                Write-Host "  ✓ 已添加防火墙入站规则: TCP/$目标端口" -ForegroundColor Green
            }
        }
    } catch {}
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

# ─── 调试客户端 JS ────────────────────────────────────────────────────
function 生成调试客户端JS([string]$IP, [int]$P) {
    return @"
(function(){
  if(window.__HDC_DEBUG_ACTIVE)return;
  window.__HDC_DEBUG_ACTIVE=true;
  var WS_URL="ws://${IP}:${P}";
  var ws=null,queue=[],reconnectTimer=null;
  function connect(){
    try{ws=new WebSocket(WS_URL)}catch(e){return}
    ws.onopen=function(){while(queue.length)ws.send(queue.shift())};
    ws.onclose=function(){ws=null;if(!reconnectTimer)reconnectTimer=setTimeout(function(){reconnectTimer=null;connect()},3000)};
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
  var _c={};
  ["log","info","warn","error","debug"].forEach(function(l){
    _c[l]=console[l];
    console[l]=function(){
      _c[l].apply(console,arguments);
      var args=[];
      for(var i=0;i<arguments.length;i++){
        try{var v=arguments[i];
          if(v instanceof Error)args.push({message:v.message,stack:v.stack});
          else if(typeof v==="object")args.push(JSON.parse(JSON.stringify(v,function(k,val){
            if(typeof val==="function")return"[Function]";
            if(val instanceof HTMLElement)return val.outerHTML.substring(0,200);
            return val})));
          else args.push(v);
        }catch(e){args.push("[无法序列化]")}
      }
      send({type:"console",level:l,args:args,timestamp:Date.now()});
    };
  });
  window.addEventListener("error",function(e){send({type:"error",message:e.message,filename:e.filename,lineno:e.lineno,colno:e.colno,timestamp:Date.now()})});
  window.addEventListener("unhandledrejection",function(e){send({type:"error",message:"UnhandledRejection: "+(e.reason&&e.reason.message||e.reason),stack:e.reason&&e.reason.stack,timestamp:Date.now()})});
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
var ws=new WebSocket("ws://"+location.host);
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

function 读取HTTP请求([System.Net.Sockets.NetworkStream]$流) {
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

function 发送HTTP响应([System.Net.Sockets.NetworkStream]$流, [string]$状态, [string]$内容类型, [byte[]]$正文) {
    $头 = "HTTP/1.1 $状态`r`nContent-Type: $内容类型`r`nContent-Length: $($正文.Length)`r`nAccess-Control-Allow-Origin: *`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
    $头字节 = [System.Text.Encoding]::ASCII.GetBytes($头)
    $流.Write($头字节, 0, $头字节.Length)
    if ($正文.Length -gt 0) { $流.Write($正文, 0, $正文.Length) }
    $流.Flush()
}

# ─── WebSocket 协议 ──────────────────────────────────────────────────
function WS握手([string]$头部, [System.Net.Sockets.NetworkStream]$流) {
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

function 发送WS文本帧([System.Net.Sockets.NetworkStream]$流, [string]$文本) {
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

function 发送WS关闭帧([System.Net.Sockets.NetworkStream]$流) {
    try { $流.Write([byte[]]@(0x88, 0x00), 0, 2); $流.Flush() } catch {}
}

function 发送WSpong帧([System.Net.Sockets.NetworkStream]$流, [byte[]]$载荷) {
    $帧头 = [System.Collections.Generic.List[byte]]::new()
    $帧头.Add(0x8A)  # FIN + Pong
    $帧头.Add([byte]$载荷.Length)
    $输出 = [byte[]]::new($帧头.Count + $载荷.Length)
    $帧头.CopyTo($输出)
    if ($载荷.Length -gt 0) { [System.Array]::Copy($载荷, 0, $输出, $帧头.Count, $载荷.Length) }
    $流.Write($输出, 0, $输出.Length)
    $流.Flush()
}

function 读取WS帧([System.Net.Sockets.NetworkStream]$流) {
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

# ─── 应用逻辑 ────────────────────────────────────────────────────────
$script:WS客户端列表 = [System.Collections.Generic.List[hashtable]]::new()

function 广播([string]$数据) {
    for ($i = $script:WS客户端列表.Count - 1; $i -ge 0; $i--) {
        try {
            发送WS文本帧 $script:WS客户端列表[$i].流 $数据
        } catch {
            try { $script:WS客户端列表[$i].TCP.Close() } catch {}
            Write-Host "[断开] $($script:WS客户端列表[$i].来源)" -ForegroundColor Yellow
            $script:WS客户端列表.RemoveAt($i)
        }
    }
}

function 处理消息([string]$原始文本) {
    try { $消息 = $原始文本 | ConvertFrom-Json } catch {
        Write-Host "  [原始] $原始文本" -ForegroundColor DarkGray; return
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
            Write-Host "$时间 " -ForegroundColor DarkGray -NoNewline
            Write-Host "[$($级别.ToUpper())] " -ForegroundColor $颜色 -NoNewline
            Write-Host $参数列表
            广播 $原始文本
        }
        "error" {
            $时间 = if ($消息.timestamp) {
                [DateTimeOffset]::FromUnixTimeMilliseconds([long]$消息.timestamp).LocalDateTime.ToString("HH:mm:ss")
            } else { (Get-Date).ToString("HH:mm:ss") }
            Write-Host "$时间 " -ForegroundColor DarkGray -NoNewline
            Write-Host "[未捕获错误] " -ForegroundColor Red -NoNewline
            Write-Host $消息.message
            if ($消息.stack) { Write-Host $消息.stack -ForegroundColor DarkGray }
            广播 $原始文本
        }
        "ping" {}
        default {
            Write-Host "  [未知] $原始文本" -ForegroundColor DarkGray
            广播 $原始文本
        }
    }
}

function 处理新连接([System.Net.Sockets.TcpClient]$tcp客户端) {
    $流 = $tcp客户端.GetStream()
    $流.ReadTimeout = 5000

    $头部 = 读取HTTP请求 $流
    if (-not $头部) { $tcp客户端.Close(); return }

    $路径 = if ($头部 -match '^\w+\s+(\S+)') { $Matches[1] } else { "/" }

    # WebSocket 升级
    if ($头部 -match '(?i)Upgrade:\s*websocket') {
        if (WS握手 $头部 $流) {
            $来源 = $tcp客户端.Client.RemoteEndPoint.ToString()
            Write-Host "[连接] $来源" -ForegroundColor Green
            $流.ReadTimeout = 200
            $script:WS客户端列表.Add(@{ 流 = $流; TCP = $tcp客户端; 来源 = $来源 })
        } else { $tcp客户端.Close() }
        return
    }

    # HTTP 路由
    try {
        switch ($路径) {
            "/__debug_client.js" {
                $正文 = [System.Text.Encoding]::UTF8.GetBytes((生成调试客户端JS $局域网IP $端口))
                发送HTTP响应 $流 "200 OK" "application/javascript; charset=utf-8" $正文
            }
            "/__logs" {
                $正文 = [System.Text.Encoding]::UTF8.GetBytes((生成日志查看器HTML))
                发送HTTP响应 $流 "200 OK" "text/html; charset=utf-8" $正文
            }
            default {
                $相对路径 = if ($路径 -eq "/") { "index.html" } else { $路径.TrimStart("/") }
                $文件路径 = Join-Path $Www目录 ($相对路径.Replace("/", "\"))
                $规范路径 = [System.IO.Path]::GetFullPath($文件路径)
                if (-not $规范路径.StartsWith($Www目录, [System.StringComparison]::OrdinalIgnoreCase)) {
                    发送HTTP响应 $流 "403 Forbidden" "text/plain" ([byte[]]@())
                } elseif (-not (Test-Path $规范路径 -PathType Leaf)) {
                    发送HTTP响应 $流 "404 Not Found" "text/plain" ([byte[]]@())
                } else {
                    $扩展名 = [System.IO.Path]::GetExtension($规范路径)
                    $类型 = if ($MIME类型[$扩展名]) { $MIME类型[$扩展名] } else { "application/octet-stream" }
                    发送HTTP响应 $流 "200 OK" $类型 ([System.IO.File]::ReadAllBytes($规范路径))
                }
            }
        }
    } finally { $tcp客户端.Close() }
}

# ─── 主流程 ──────────────────────────────────────────────────────────
$局域网IP = if ($仅本机) { "127.0.0.1" } else { 获取局域网IP }
$Www目录 = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "Acode\www"

清理端口占用 $端口
配置防火墙 $端口

$绑定地址 = if ($仅本机) { [System.Net.IPAddress]::Loopback } else { [System.Net.IPAddress]::Any }
$tcp监听器 = [System.Net.Sockets.TcpListener]::new($绑定地址, $端口)
$tcp监听器.Start()

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     HDC 远程调试服务器已启动                ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║ 局域网: " -ForegroundColor Green -NoNewline
Write-Host "http://${局域网IP}:${端口}" -ForegroundColor Cyan -NoNewline
Write-Host "               ║" -ForegroundColor Green
Write-Host "║ 日志:   " -ForegroundColor Green -NoNewline
Write-Host "http://${局域网IP}:${端口}/__logs" -ForegroundColor Cyan -NoNewline
Write-Host "        ║" -ForegroundColor Green
Write-Host "║ 监视:   " -ForegroundColor Green -NoNewline
if ($监视) { Write-Host "已开启" -ForegroundColor Green -NoNewline } else { Write-Host "未开启" -ForegroundColor DarkGray -NoNewline }
Write-Host "                              ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "提示: 确保手机和电脑在同一局域网" -ForegroundColor DarkGray
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
                if ($ws.流.DataAvailable) {
                    $帧 = 读取WS帧 $ws.流
                    if (-not $帧 -or $帧.类型 -eq "关闭") {
                        发送WS关闭帧 $ws.流
                        $死链.Add($i); continue
                    }
                    if ($帧.类型 -eq "文本" -and $帧.数据.Length -gt 0) { 处理消息 $帧.数据 }
                }
            } catch { $死链.Add($i) }
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
