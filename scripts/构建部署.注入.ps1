function 获取调试日志注入片段 {
    param(
        [pscustomobject]$调试服务器元数据,
        [string]$调试构建标识
    )

    $脚本标签 = @(
        "    <!-- HDC_DEBUG --><script>window.__HDC_DEBUG_BUILD_ID = '$调试构建标识'; window.__HDC_DEBUG_SCRIPT_URL = '$($调试服务器元数据.scriptUrl)';</script>",
        '    <!-- HDC_DEBUG --><script src="' + $调试服务器元数据.scriptUrl + '"></script>'
    ) -join "`n"

    return $脚本标签
}

function 设置平台文件文本替换 {
    param(
        [string]$文件路径,
        [string]$查找文本,
        [string]$替换文本,
        [switch]$允许缺失
    )

    if (-not (Test-Path $文件路径)) {
        输出错误 "找不到目标文件: $文件路径"
        exit 1
    }

    $内容 = Get-Content $文件路径 -Raw -Encoding UTF8
    $原内容 = $内容
    $查找模式 = [regex]::Escape($查找文本)
    $查找模式 = $查找模式.Replace("`r`n", "\r?\n")
    $查找模式 = $查找模式.Replace("`n", "\r?\n")

    if (-not [regex]::IsMatch($内容, $查找模式)) {
        if ($允许缺失) {
            return $false
        }
        输出错误 "目标文件缺少预期文本: $文件路径"
        exit 1
    }

    $内容 = [regex]::Replace($内容, $查找模式, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $替换文本 }, 1)
    if ($内容 -eq $原内容) {
        return $false
    }

    [System.IO.File]::WriteAllText($文件路径, $内容, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function 清理平台调试客户端注入 {
    $平台IndexHtml = Join-Path $平台AssetsWww "index.html"

    $内容 = Get-Content $平台IndexHtml -Raw -Encoding UTF8
    if ($内容 -notmatch "HDC_DEBUG") {
        return $false
    }

    $内容 = $内容 -replace '(?s)\s*<!-- HDC_DEBUG -->.*?</script>\s*', "`n"
    [System.IO.File]::WriteAllText($平台IndexHtml, $内容, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function 设置平台终端调试日志注入 {
    param(
        [bool]$启用
    )

    if (-not $启用) {
        return $false
    }

    $initSandbox路径 = Join-Path $平台Assets目录 "init-sandbox.sh"
    $initAlpine路径 = Join-Path $平台Assets目录 "init-alpine.sh"
    $已注入 = $false

    $sandbox查找 = @'
ARGS="$ARGS -L"

$PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@"
'@
    $sandbox替换 = @'
ARGS="$ARGS -L"

echo "[sandbox] proot=$PROOT"
echo "[sandbox] args=$ARGS"
$PROOT $ARGS /bin/sh $PREFIX/init-alpine.sh "$@"
PROOT_EXIT=$?
echo "[sandbox] proot exit=$PROOT_EXIT"
exit $PROOT_EXIT
'@
    if (设置平台文件文本替换 -文件路径 $initSandbox路径 -查找文本 $sandbox查找 -替换文本 $sandbox替换 -允许缺失) {
        $已注入 = $true
    }

    if (-not (Test-Path $initAlpine路径)) {
        输出错误 "找不到平台终端启动脚本: $initAlpine路径"
        exit 1
    }

    $initAlpine内容 = Get-Content $initAlpine路径 -Raw -Encoding UTF8
    $initAlpine内容 = $initAlpine内容 -replace "`r`n", "`n"
    $原始InitAlpine内容 = $initAlpine内容
    Write-Host "  [diag-inject] init-alpine path: $initAlpine路径" -ForegroundColor DarkGray
    ($initAlpine内容 -split "`r?`n" | Select-Object -First 24) | ForEach-Object {
        Write-Host "  [diag-inject] file> $_" -ForegroundColor DarkGray
    }

    $执行替换 = {
        param(
            [string]$内容,
            [string]$查找文本,
            [string]$替换文本,
            [string]$标签
        )

        $规范查找文本 = $查找文本 -replace "`r`n", "`n"
        $规范替换文本 = $替换文本 -replace "`r`n", "`n"
        $已匹配 = $内容.Contains($规范查找文本)
        $新内容 = $内容.Replace($规范查找文本, $规范替换文本)
        Write-Host "  [diag-inject] ${标签}: matched=$已匹配 changed=$($新内容 -ne $内容)" -ForegroundColor DarkGray
        return $新内容
    }

    $repo查找 = @'
APK_MAIN_REPO="https://dl-cdn.alpinelinux.org/alpine/v3.21/main"
APK_COMMUNITY_REPO="https://dl-cdn.alpinelinux.org/alpine/v3.21/community"
APK_MIRROR_MAIN_REPO="https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main"
APK_MIRROR_COMMUNITY_REPO="https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/community"
'@
    $repo替换 = @'
APK_MAIN_REPO="https://dl-cdn.alpinelinux.org/alpine/v3.21/main"
APK_COMMUNITY_REPO="https://dl-cdn.alpinelinux.org/alpine/v3.21/community"
APK_MIRROR_MAIN_REPO="https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main"
APK_MIRROR_COMMUNITY_REPO="https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/community"

diag_log() {
    echo "[diag] $*"
}

diag_summary() {
    echo "[diag-summary] $*"
}

dump_env_state() {
    diag_log "env-state PATH=${PATH}"
}

dump_command_state() {
    local command_name="$1"
    local command_path
    command_path="$(command -v "$command_name" 2>/dev/null || true)"
    if [ -n "$command_path" ]; then
        diag_log "command-state name=${command_name} path=${command_path}"
        ls -l "$command_path" 2>/dev/null || true
    else
        diag_log "command-state name=${command_name} path=<missing>"
    fi
}

dump_path_state() {
    local path="$1"
    if [ -e "$path" ]; then
        diag_log "path-state path=${path} exists=true"
        ls -ld "$path" 2>/dev/null || true
    else
        diag_log "path-state path=${path} exists=false"
    fi
}

dump_package_state() {
    local package_name="$1"
    if is_apk_installed "$package_name"; then
        diag_log "package-state name=${package_name} installed=true"
    else
        diag_log "package-state name=${package_name} installed=false"
    fi
}

dump_requested_package_state() {
    local package_name
    dump_env_state

    for package_name in "$@"; do
        [ -z "$package_name" ] && continue
        dump_package_state "$package_name"
    done

    dump_command_state add-shell
    dump_command_state sh
    dump_command_state ash
    dump_command_state bash
    dump_command_state busybox
    dump_command_state wget
    dump_command_state sed
    dump_command_state tar
    dump_command_state readlink
    dump_command_state depmod

    dump_path_state /bin
    dump_path_state /bin/bbsuid
    dump_path_state /bin/busybox-extras
    dump_path_state /bin/sh
    dump_path_state /bin/ash
    dump_path_state /bin/bash
    dump_path_state /usr/bin
    dump_path_state /usr/bin/wget
    dump_path_state /usr/sbin
    dump_path_state /usr/sbin/add-shell
    dump_path_state /usr/share/zoneinfo/UTC
    dump_path_state /usr/libexec/command-not-found
    dump_path_state /etc/shells
    dump_path_state /lib/apk/db/installed
    dump_path_state /lib/apk/db/scripts.tar
}

dump_motd_state() {
    local label="$1"
    local path="$2"

    if [ -e "$path" ]; then
        local size="0"
        size="$(wc -c < "$path" 2>/dev/null || echo 0)"
        diag_log "motd-state label=${label} path=${path} exists=true size=${size}"
        sed -n '1,12p' "$path" 2>/dev/null | while IFS= read -r motd_line; do
            diag_log "motd-body label=${label} | ${motd_line}"
        done
    else
        diag_log "motd-state label=${label} path=${path} exists=false"
    fi
}

extract_shebang_interpreter() {
    local shebang_line="$1"
    local shebang_body

    case "$shebang_line" in
        '#!'*)
            shebang_body=${shebang_line#\#!}
            ;;
        *)
            return 1
            ;;
    esac

    set -- $shebang_body
    [ $# -eq 0 ] && return 1
    printf '%s\n' "$1"
}

dump_apk_script_details() {
    local package_name="$1"
    local script_entries

    if [ ! -f /lib/apk/db/scripts.tar ]; then
        diag_log "apk-script package=${package_name} scripts.tar missing"
        return
    fi

    script_entries="$(tar -tf /lib/apk/db/scripts.tar 2>/dev/null | grep "^${package_name}-" || true)"
    if [ -z "$script_entries" ]; then
        diag_log "apk-script package=${package_name} entries=<none>"
        return
    fi

    printf '%s\n' "$script_entries" | while IFS= read -r script_entry; do
        local first_line
        local interpreter

        [ -z "$script_entry" ] && continue
        diag_log "apk-script package=${package_name} entry=${script_entry}"

        first_line="$(tar -xOf /lib/apk/db/scripts.tar "$script_entry" 2>/dev/null | sed -n '1p')"
        if [ -n "$first_line" ]; then
            diag_log "apk-script entry=${script_entry} first-line=${first_line}"
            interpreter="$(extract_shebang_interpreter "$first_line" 2>/dev/null || true)"
            if [ -n "$interpreter" ]; then
                if [ -x "$interpreter" ]; then
                    diag_log "apk-script entry=${script_entry} interpreter=${interpreter} executable=true"
                else
                    diag_log "apk-script entry=${script_entry} interpreter=${interpreter} executable=false"
                fi
            fi
        else
            diag_log "apk-script entry=${script_entry} first-line=<empty>"
        fi

        tar -xOf /lib/apk/db/scripts.tar "$script_entry" 2>/dev/null | sed -n '1,40p' | while IFS= read -r script_line; do
            diag_log "apk-script-body entry=${script_entry} | ${script_line}"
        done
    done
}

dump_all_apk_script_entries() {
    if [ ! -f /lib/apk/db/scripts.tar ]; then
        diag_log "apk-script entries scripts.tar missing"
        return
    fi

    tar -tf /lib/apk/db/scripts.tar 2>/dev/null | sed -n '1,200p' | while IFS= read -r script_entry; do
        [ -z "$script_entry" ] && continue
        diag_log "apk-script entry=${script_entry}"
    done
}

dump_apk_trigger_state() {
    local trigger_path
    for trigger_path in /lib/apk/db/triggers /lib/apk/db/triggers.*; do
        [ -e "$trigger_path" ] || continue
        diag_log "apk-trigger path=${trigger_path}"
        ls -l "$trigger_path" 2>/dev/null || true
        sed -n '1,120p' "$trigger_path" 2>/dev/null | while IFS= read -r trigger_line; do
            diag_log "apk-trigger-body path=${trigger_path} | ${trigger_line}"
        done
    done
}

dump_interpreter_candidates() {
    local candidate
    for candidate in /bin/sh /bin/ash /bin/bash /bin/busybox /usr/bin/env /usr/bin/bash; do
        if [ -e "$candidate" ]; then
            diag_log "interpreter-state path=${candidate} exists=true"
            ls -l "$candidate" 2>/dev/null || true
        else
            diag_log "interpreter-state path=${candidate} exists=false"
        fi
    done
}

dump_busybox_applet_state() {
    local applet_name

    if [ ! -x /bin/busybox ]; then
        diag_log "busybox-state executable=false"
        return
    fi

    diag_log "busybox-state executable=true"
    /bin/busybox --help 2>/dev/null | sed -n '1,4p' | while IFS= read -r busybox_line; do
        diag_log "busybox-help | ${busybox_line}"
    done

    /bin/busybox --list 2>/dev/null | sed -n '1,200p' | while IFS= read -r applet_line; do
        case "$applet_line" in
            add-shell|remove-shell|depmod|addgroup|adduser|busybox)
                diag_log "busybox-applet listed=${applet_line}"
                ;;
        esac
    done

    for applet_name in add-shell remove-shell depmod addgroup adduser; do
        if /bin/busybox "$applet_name" --help >/dev/null 2>&1; then
            diag_log "busybox-applet runnable=${applet_name} ok=true"
        else
            diag_log "busybox-applet runnable=${applet_name} ok=false exit=$?"
        fi
    done
}

run_runtime_shell_probe() {
    local label="$1"
    shift

    local probe_log="/tmp/runtime-shell-probe-${label}-$$.log"
    diag_log "runtime-shell-probe label=${label} command=$*"
    "$@" >"$probe_log" 2>&1
    local exit_code=$?
    if [ -f "$probe_log" ]; then
        while IFS= read -r probe_line; do
            diag_log "runtime-shell-probe label=${label} | ${probe_line}"
        done < "$probe_log"
        rm -f "$probe_log"
    fi
    diag_log "runtime-shell-probe label=${label} exit=${exit_code}"
    return $exit_code
}

dump_runtime_shell_state() {
    diag_summary "runtime shell diagnostics begin"
    dump_env_state
    dump_command_state bash
    dump_command_state sh
    dump_path_state /initrc
    dump_path_state /bin/bash
    dump_path_state /etc/profile
    dump_path_state /etc/bash/bashrc

    if [ -f /initrc ]; then
        sed -n '1,160p' /initrc 2>/dev/null | while IFS= read -r initrc_line; do
            diag_log "initrc-body | ${initrc_line}"
        done
    fi

    run_runtime_shell_probe "bash-version" bash --version
    run_runtime_shell_probe "bash-login-c" bash -lc 'printf "runtime shell probe bash -lc ok\\n"'
    run_runtime_shell_probe "bash-rcfile-c" bash --rcfile /initrc -lc 'printf "runtime shell probe bash --rcfile ok\\n"'
    run_runtime_shell_probe "bash-rcfile-interactive-c" bash --rcfile /initrc -ic 'printf "runtime shell probe bash --rcfile -i ok\\n"'
    diag_summary "runtime shell diagnostics end"
}

dump_apk_failure_context() {
    local repo_mode="$1"
    local step_name="$2"
    shift 2

    diag_summary "apk failure step=${step_name} source=${repo_mode} requested=$*"
    dump_requested_package_state "$@"

    local package_name
    for package_name in "$@"; do
        [ -z "$package_name" ] && continue
        dump_apk_script_details "$package_name"
    done

    dump_apk_script_details busybox
    dump_apk_script_details busybox-binsh
    dump_apk_script_details alpine-baselayout
    dump_all_apk_script_entries
    dump_apk_trigger_state
    dump_interpreter_candidates
    dump_busybox_applet_state
}

dump_apk_lock_state() {
    diag_log "apk-lock shell-pid=$$ ppid=$PPID uid=$(id -u 2>/dev/null)"
    ls -ld /lib/apk/db 2>/dev/null || true
    ls -l /lib/apk/db/lock 2>/dev/null || echo "[diag] /lib/apk/db/lock missing"
    ps 2>/dev/null | grep -E 'apk|proot|axs|sh' | grep -v grep || true
}
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $repo查找 $repo替换 "repo"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $runStep查找 = @'
run_apk_step() {
    shift
    shift
    "$@"
    return $?
}
'@
    $runStep替换 = @'
run_apk_step() {
    local step_name="$1"
    local repo_mode="$2"
    shift
    shift
    local log_file="/tmp/apk-step-$$.log"

    diag_log "running ${step_name} source=${repo_mode} command=$*"
    "$@" >"$log_file" 2>&1
    local exit_code=$?
    if [ -f "$log_file" ]; then
        while IFS= read -r line; do
            diag_log "${step_name} | ${line}"
        done < "$log_file"
        rm -f "$log_file"
    else
        diag_log "${step_name} produced no output"
    fi
    diag_log "${step_name} exit=${exit_code}"
    if [ $exit_code -ne 0 ]; then
        dump_apk_lock_state
    fi
    return $exit_code
}
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $runStep查找 $runStep替换 "runStep"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $install查找 = @'
if [ -n "$missing_packages" ]; then
    echo -e "\e[34;1m[*] \e[0mInstalling packages:$missing_packages\e[0m"

    install_succeeded="false"
'@
    $install替换 = @'
if [ -n "$missing_packages" ]; then
    echo -e "\e[34;1m[*] \e[0mInstalling packages:$missing_packages\e[0m"
    diag_log "installing shell-pid=$$ ppid=$PPID missing_packages=$missing_packages"
    dump_apk_lock_state

    package_list=""
    for package_name in $missing_packages; do
        package_list="$package_list $package_name"
    done

    install_succeeded="false"
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $install查找 $install替换 "install"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $updateFail查找 = @'
        run_apk_step "apk update package-index" "$repo_mode" apk update
        if [ $? -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mapk update failed with ${repo_mode} repositories\e[0m"
            continue
        fi

        run_apk_step "apk add required-packages" "$repo_mode" apk add $missing_packages
        if [ $? -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mapk add failed with ${repo_mode} repositories\e[0m"
            continue
        fi
'@
    $updateFail替换 = @'
        run_apk_step "apk update package-index" "$repo_mode" apk update
        if [ $? -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mapk update failed with ${repo_mode} repositories\e[0m"
            diag_summary "apk failure step=apk update package-index source=${repo_mode}"
            dump_apk_lock_state
            continue
        fi

        run_apk_step "apk add required-packages" "$repo_mode" apk add $missing_packages
        if [ $? -ne 0 ]; then
            echo -e "\e[33;1m[!] \e[0mapk add failed with ${repo_mode} repositories\e[0m"
            dump_apk_failure_context "$repo_mode" "apk add required-packages" $package_list
            continue
        fi
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $updateFail查找 $updateFail替换 "updateFail"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $verify查找 = @'
    # Verify
    [ -z "$bash_path" ] && echo -e "\e[31;1m[!] \e[0mbash still missing\e[0m"
'@
    $verify替换 = @'
    # Verify
    dump_apk_lock_state
    [ -z "$bash_path" ] && echo -e "\e[31;1m[!] \e[0mbash still missing\e[0m"
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $verify查找 $verify替换 "verify"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $motdCreate查找 = @'
if [ "$#" -eq 0 ]; then
    echo "$$" > "$PREFIX/pid"
    chmod +x "$PREFIX/axs"

    if [ ! -e "$PREFIX/alpine/etc/acode_motd" ]; then
'@
    $motdCreate替换 = @'
if [ "$#" -eq 0 ]; then
    echo "$$" > "$PREFIX/pid"
    chmod +x "$PREFIX/axs"

    dump_motd_state host-before-create "$PREFIX/alpine/etc/acode_motd"

    if [ ! -e "$PREFIX/alpine/etc/acode_motd" ]; then
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $motdCreate查找 $motdCreate替换 "motdCreate"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $axsLaunch查找 = @'
#actual source
#everytime a terminal is started initrc will run
"$PREFIX/axs" -c "bash --rcfile /initrc -i"
'@
    $axsLaunch替换 = @'
#actual source
#everytime a terminal is started initrc will run
diag_summary "axs launch begin"
dump_runtime_shell_state
diag_log "axs launch command=$PREFIX/axs -c bash --rcfile /initrc -i"
"$PREFIX/axs" -c "bash --rcfile /initrc -i"
axs_exit=$?
diag_summary "axs process exited exit=${axs_exit}"
exit $axs_exit
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $axsLaunch查找 $axsLaunch替换 "axsLaunch"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    $axsLaunchAllowAnyOrigin查找 = @'
#actual source
#everytime a terminal is started initrc will run
"$PREFIX/axs" --allow-any-origin -c "bash --rcfile /initrc -i"
'@
    $axsLaunchAllowAnyOrigin替换 = @'
#actual source
#everytime a terminal is started initrc will run
diag_summary "axs launch begin"
dump_runtime_shell_state
diag_log "axs launch command=$PREFIX/axs --allow-any-origin -c bash --rcfile /initrc -i"
"$PREFIX/axs" --allow-any-origin -c "bash --rcfile /initrc -i"
axs_exit=$?
diag_summary "axs process exited exit=${axs_exit}"
exit $axs_exit
'@
    $替换后内容 = & $执行替换 $initAlpine内容 $axsLaunchAllowAnyOrigin查找 $axsLaunchAllowAnyOrigin替换 "axsLaunchAllowAnyOrigin"
    if ($替换后内容 -ne $initAlpine内容) {
        $initAlpine内容 = $替换后内容
        $已注入 = $true
    }

    if ($initAlpine内容 -ne $原始InitAlpine内容) {
        [System.IO.File]::WriteAllText($initAlpine路径, $initAlpine内容, [System.Text.UTF8Encoding]::new($false))
    }

    return $已注入
}

function 设置平台终端Axs启动参数 {
    param(
        [bool]$启用AllowAnyOrigin
    )

    $平台终端启动脚本 = Join-Path $平台Assets目录 "init-alpine.sh"

    if (-not (Test-Path $平台终端启动脚本)) {
        输出错误 "找不到平台终端启动脚本: $平台终端启动脚本"
        exit 1
    }

    $内容 = Get-Content $平台终端启动脚本 -Raw -Encoding UTF8
    $原内容 = $内容
    $内容 = $内容 -replace '"\$PREFIX/axs"\s+--allow-any-origin\s+-c\s+"bash --rcfile /initrc -i"', '"$PREFIX/axs" -c "bash --rcfile /initrc -i"'

    if ($启用AllowAnyOrigin) {
        $内容 = $内容 -replace '"\$PREFIX/axs" -c "bash --rcfile /initrc -i"', '"$PREFIX/axs" --allow-any-origin -c "bash --rcfile /initrc -i"'
    }

    if ($内容 -eq $原内容) {
        return $false
    }

    [System.IO.File]::WriteAllText($平台终端启动脚本, $内容, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function 设置平台调试Scheme {
    param(
        [string]$Scheme值
    )

    $平台ConfigXml = Join-Path $平台根目录 "app/src/main/res/xml/config.xml"

    $配置内容 = Get-Content $平台ConfigXml -Raw -Encoding UTF8
    $原配置内容 = $配置内容
    $配置内容 = $配置内容 -replace '(?m)^\s*<preference name="Scheme" value="[^"]*"\s*/>\s*\r?\n?', ''

    if (-not [string]::IsNullOrWhiteSpace($Scheme值)) {
        $配置内容 = $配置内容 -replace '</widget>', "    <preference name=""Scheme"" value=""$Scheme值"" />`n</widget>"
    }

    if ($配置内容 -eq $原配置内容) {
        return $false
    }

    [System.IO.File]::WriteAllText($平台ConfigXml, $配置内容, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function 测试调试服务器可达 {
    param(
        [string]$主机,
        [int]$端口,
        [int]$超时毫秒 = 2000
    )

    try {
        $客户端 = [System.Net.Sockets.TcpClient]::new()
        $异步结果 = $客户端.BeginConnect($主机, $端口, $null, $null)
        if (-not $异步结果.AsyncWaitHandle.WaitOne($超时毫秒, $false)) {
            $客户端.Dispose()
            return $false
        }
        $客户端.EndConnect($异步结果)
        $客户端.Dispose()
        return $true
    } catch {
        return $false
    }
}

function 获取调试服务器TLS元数据 {
    $元数据路径 = Join-Path $工作区根目录 "scripts/logs/调试服务器-metadata.json"
    if (-not (Test-Path $元数据路径)) {
        return $null
    }

    try {
        return Get-Content $元数据路径 -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        输出错误 "调试服务器元数据解析失败: $元数据路径"
        exit 1
    }
}

function 获取调试服务器Axs下载地址 {
    param(
        [pscustomobject]$调试服务器元数据
    )

    return [ordered]@{
        arm64 = $调试服务器元数据.axsUrls.arm64
        armv7 = $调试服务器元数据.axsUrls.armv7
        x64 = $调试服务器元数据.axsUrls.x64
    }
}

function 重置平台终端Axs下载注入 {
    $平台基线终端脚本 = Join-Path $平台根目录 "platform_www/plugins/com.foxdebug.acode.rk.exec.terminal/www/Terminal.js"
    $平台终端脚本 = Join-Path $平台AssetsWww "plugins/com.foxdebug.acode.rk.exec.terminal/www/Terminal.js"

    if (-not (Test-Path $平台基线终端脚本)) {
        输出错误 "找不到平台终端插件基线脚本: $平台基线终端脚本"
        exit 1
    }
    if (-not (Test-Path $平台终端脚本)) {
        输出错误 "找不到平台终端插件脚本: $平台终端脚本"
        exit 1
    }

    $平台基线内容 = Get-Content $平台基线终端脚本 -Raw -Encoding UTF8
    if ($平台基线内容 -notmatch '^cordova\.define\("com\.foxdebug\.acode\.rk\.exec\.terminal\.Terminal"') {
        输出错误 "平台终端插件基线不是 Cordova 模块包装版本: $平台基线终端脚本"
        exit 1
    }

    Copy-Item $平台基线终端脚本 $平台终端脚本 -Force
    return $true
}

function 设置平台终端Axs下载源 {
    param(
        [pscustomobject]$调试服务器元数据
    )

    $平台终端脚本 = Join-Path $平台AssetsWww "plugins/com.foxdebug.acode.rk.exec.terminal/www/Terminal.js"
    if (-not (Test-Path $平台终端脚本)) {
        输出错误 "找不到平台终端插件脚本: $平台终端脚本"
        exit 1
    }

    $下载地址 = 获取调试服务器Axs下载地址 -调试服务器元数据 $调试服务器元数据
    $内容 = Get-Content $平台终端脚本 -Raw -Encoding UTF8
    $原内容 = $内容

    $替换映射 = [ordered]@{
        'https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-arm64' = $下载地址.arm64
        'https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-armv7' = $下载地址.armv7
        'https://github.com/bajrangCoder/acodex_server/releases/latest/download/axs-musl-android-x86_64' = $下载地址.x64
    }

    foreach ($原地址 in $替换映射.Keys) {
        if (-not $内容.Contains($原地址)) {
            输出错误 "平台终端脚本缺少预期的 AXS 下载地址: $原地址"
            exit 1
        }
        $内容 = $内容.Replace($原地址, $替换映射[$原地址])
    }

    if ($内容 -eq $原内容) {
        return $false
    }

    [System.IO.File]::WriteAllText($平台终端脚本, $内容, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function 清理平台调试证书信任 {
    $调试资源根目录 = Join-Path $平台根目录 "app/src/debug/res"
    $调试证书路径 = Join-Path $调试资源根目录 "raw/acode_debug_server_cert.cer"
    $调试配置路径 = Join-Path $调试资源根目录 "xml/network_security_config.xml"
    $已清理 = $false

    if (Test-Path $调试证书路径) {
        Remove-Item $调试证书路径 -Force
        $已清理 = $true
    }
    if (Test-Path $调试配置路径) {
        Remove-Item $调试配置路径 -Force
        $已清理 = $true
    }

    return $已清理
}

function 设置平台调试证书信任 {
    param(
        [pscustomobject]$调试服务器元数据
    )

    $主配置路径 = Join-Path $平台根目录 "app/src/main/res/xml/network_security_config.xml"
    if (-not (Test-Path $主配置路径)) {
        输出错误 "找不到平台主网络安全配置: $主配置路径"
        exit 1
    }

    $调试资源根目录 = Join-Path $平台根目录 "app/src/debug/res"
    $调试Raw目录 = Join-Path $调试资源根目录 "raw"
    $调试Xml目录 = Join-Path $调试资源根目录 "xml"
    $调试证书路径 = Join-Path $调试Raw目录 "acode_debug_server_cert.cer"
    $调试配置路径 = Join-Path $调试Xml目录 "network_security_config.xml"

    New-Item -ItemType Directory -Path $调试Raw目录 -Force | Out-Null
    New-Item -ItemType Directory -Path $调试Xml目录 -Force | Out-Null

    Copy-Item $调试服务器元数据.certificatePath $调试证书路径 -Force

    $配置内容 = Get-Content $主配置路径 -Raw -Encoding UTF8
    $配置内容 = $配置内容 -replace '\s*<certificates src="@raw/acode_debug_server_cert"\s*/>\s*', "`n"

    if ($配置内容 -match '<certificates src="system"\s*/>') {
        $配置内容 = $配置内容 -replace '<certificates src="system"\s*/>', "<certificates src=""system"" />`n      <certificates src=""@raw/acode_debug_server_cert"" />"
    } elseif ($配置内容 -match '<trust-anchors>') {
        $配置内容 = $配置内容 -replace '<trust-anchors>', "<trust-anchors>`n      <certificates src=""@raw/acode_debug_server_cert"" />"
    } else {
        输出错误 "平台网络安全配置缺少 trust-anchors，无法注入调试证书。"
        exit 1
    }

    [System.IO.File]::WriteAllText($调试配置路径, $配置内容, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function 注入Debug改动 {
    if (-not (Test-Path $平台Assets目录)) {
        输出错误 "平台 assets 目录不存在，请先运行: .\构建部署.ps1 -动作 setup"
        exit 1
    }

    $需要调试服务器 = ($Axs下载源 -eq "debug-server") -or $注入调试日志

    if (重置平台终端Axs下载注入) {
        输出成功 "已恢复平台终端插件为源码基线"
    }
    if (设置平台调试Scheme -Scheme值 $null) {
        输出成功 "已清理平台产物中的调试 Scheme 注入"
    }
    if (设置平台终端Axs启动参数 -启用AllowAnyOrigin $false) {
        输出成功 "已清理平台终端 AXS 的调试启动参数注入"
    }
    $已清理旧注入 = 清理平台调试客户端注入
    if (清理平台调试证书信任) {
        输出成功 "已清理平台产物中的调试证书信任注入"
    }

    if (-not $需要调试服务器) {
        if ($已清理旧注入) {
            输出成功 "已清理平台产物中的旧调试注入"
        }
        输出成功 "当前构建不需要任何调试注入"
        return
    }

    输出步骤 "应用构建期注入"

    $调试服务器元数据 = 获取调试服务器TLS元数据
    if (-not $调试服务器元数据) {
        输出错误 "当前构建配置需要调试服务器，但找不到调试服务器元数据。"
        输出错误 "请先启动 scripts/调试服务器.ps1，再重新构建。"
        exit 1
    }

    if (-not (测试调试服务器可达 -主机 $调试服务器元数据.host -端口 ([int]$调试服务器元数据.port))) {
        输出错误 "当前构建配置需要调试服务器，但调试服务器不可达: $($调试服务器元数据.host):$($调试服务器元数据.port)"
        输出错误 "请先启动 scripts/调试服务器.ps1，再重新构建。"
        exit 1
    }

    if ($Axs下载源 -eq "debug-server") {
        if (设置平台终端Axs下载源 -调试服务器元数据 $调试服务器元数据) {
            $下载地址 = 获取调试服务器Axs下载地址 -调试服务器元数据 $调试服务器元数据
            输出成功 "已将 AXS 下载源改为调试服务器"
            输出成功 "AXS 下载地址: $($下载地址.arm64)"
        }
    } else {
        输出成功 "AXS 下载源保持默认 release 地址"
    }

    if (设置平台调试证书信任 -调试服务器元数据 $调试服务器元数据) {
        输出成功 "已注入调试服务器证书信任"
    }

    if ($注入调试日志) {
        $null = 设置平台终端调试日志注入 -启用 $true
        $平台终端启动脚本 = Join-Path $平台Assets目录 "init-alpine.sh"
        $平台终端脚本内容 = Get-Content $平台终端启动脚本 -Raw -Encoding UTF8
        if ($平台终端脚本内容 -match '\[diag\]' -and $平台终端脚本内容 -match 'dump_apk_failure_context') {
            输出成功 "已向终端脚本注入调试日志诊断"
        } else {
            输出错误 "终端脚本调试日志注入失败：平台脚本未命中预期锚点。"
            exit 1
        }

        $平台IndexHtml = Join-Path $平台AssetsWww "index.html"
        $调试构建标识 = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $内容 = Get-Content $平台IndexHtml -Raw -Encoding UTF8
        $调试脚本标签 = 获取调试日志注入片段 -调试服务器元数据 $调试服务器元数据 -调试构建标识 $调试构建标识
        $内容 = $内容 -replace '(\s*<script src="cordova\.js"></script>)', "`n$调试脚本标签`n`$1"
        [System.IO.File]::WriteAllText($平台IndexHtml, $内容, [System.Text.UTF8Encoding]::new($false))

        输出成功 "调试服务器地址: $($调试服务器元数据.scriptUrl)"
        输出成功 "调试构建标识: $调试构建标识"
        输出成功 "已注入调试日志客户端到平台 index.html"
    }
}