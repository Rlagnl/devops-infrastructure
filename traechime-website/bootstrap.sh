#!/usr/bin/env bash
# TraeChime Website 服务器初始化脚本(静态站点, 无 Node/pnpm 环境)
# 参考 packages/devops-infrastructure/howleft-website/bootstrap.sh(静态站点 nginx + runner)与
#       packages/devops-infrastructure/langgraph-aui-app/bootstrap.sh(DNS-01 HTTPS)
#
# 职责(在目标服务器上以 root 运行一次):
#   1. 安装基础工具: git / rsync / jq / curl
#   2. 配置 nginx 静态站点: root ${NGINX_ROOT}(默认 /opt/traechime), 监听 80
#   3. 通过 Let's Encrypt DNS-01(阿里云 DNS)为 ${SERVER_NAME}(默认 chime.rlagnl.top)签发证书,
#      并改写 nginx 为 80 端口 301 跳转 + 443 端口 SSL 终结静态站点
#   4. 安装并注册 Self-hosted Runner(label: production, 目标仓库 Rlagnl/traechime)
# 说明: 静态产物在 GitHub 托管 runner 上构建, 本脚本无需安装 Node/pnpm/nrm
#
# 选择 DNS-01 而非 HTTP-01 的原因: 80 端口可能被上游(如云厂商/运营商)拦截或域名尚未解析,
# DNS-01 通过 DNS TXT 记录验证, 不依赖 80 端口 HTTP 回源, 证书照常签发。
#
# GITHUB_USER / GITHUB_PAT 支持三种传入方式:
#   1) 命令行参数: sudo ./bootstrap.sh -u <user> -t <token>
#   2) 环境变量:   sudo GITHUB_USER=... GITHUB_PAT=... ./bootstrap.sh
#   3) 交互式输入: 不传任何参数, 脚本运行后用 gum/read 提示输入
#
# ALIYUN_ACCESS_KEY_ID / ALIYUN_ACCESS_KEY_SECRET 同样支持三种传入方式(DNS-01 签发证书):
#   1) 命令行参数: sudo ./bootstrap.sh -k <AccessKeyID> -s <AccessKeySecret>
#   2) 环境变量:   sudo ALIYUN_ACCESS_KEY_ID=... ALIYUN_ACCESS_KEY_SECRET=... ./bootstrap.sh
#   3) 交互式输入: 不传时脚本运行后提示输入

set -euo pipefail  # 未定义变量报错, 管道失败传递, 命令失败由 ERR trap 统一处理并退出
set -E             # errtrace: 让 ERR trap 传播进 step_* 函数内部

# ============ 颜色定义(非交互终端自动关闭颜色) ============
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' NC=''
fi

# ============ root 权限检查 ============
# 脚本包含 apt/systemctl/useradd 等操作, 必须以 root 身份运行
if [[ $EUID -ne 0 ]]; then
    printf '%s错误: 本脚本必须以 root 权限执行。%s\n' "$RED" "$NC" >&2
    printf '请使用 sudo 重新运行, 例如:%s\n' "$NC" >&2
    printf '  sudo %s%s%s\n' "$0" "${*:+ }" "$*" >&2
    exit 1
fi

# 保存原始 stdout/stderr 到 fd 3/4, 供 on_error 绕过 run_step 里的 tee 直接写终端
exec 3>&1 4>&2

# ============ 步骤状态上下文 ============
STEP_NUM=0        # 当前步骤序号
STEP_DESC=""      # 当前步骤描述
STEP_LOG=""       # 当前步骤输出日志临时文件路径(用于失败时提取错误信息)

# ============ 错误处理: 任意命令失败时触发 ============
on_error() {
    local code=$?
    if [[ -n "$STEP_DESC" ]]; then
        exec 1>&3 2>&4
        printf '\n%s========================================%s\n' "$RED" "$NC"
        printf '%s[失败] 步骤 %s: %s (退出码: %s)%s\n' "$RED" "$STEP_NUM" "$STEP_DESC" "$code" "$NC"
        if [[ -n "$STEP_LOG" && -f "$STEP_LOG" ]]; then
            sleep 0.1
            printf '%s最近输出(错误信息):%s\n' "$RED" "$NC"
            tail -n 20 "$STEP_LOG" | sed 's/^/    /'
        fi
        printf '%s========================================%s\n' "$RED" "$NC"
        printf '%s脚本因步骤 %s 失败而终止。%s\n' "$RED" "$STEP_NUM" "$NC"
    fi
    [[ -n "$STEP_LOG" && -f "$STEP_LOG" ]] && rm -f "$STEP_LOG"
    exit "$code"
}
trap on_error ERR

# ============ gum 自动检测 + 静默回退 ============
GUM_BIN=""

ensure_gum() {
    if command -v gum >/dev/null 2>&1; then
        GUM_BIN="$(command -v gum)"
        return 0
    fi

    printf '%s[gum]%s 未检测到 gum, 尝试通过 apt 安装...\n' "$YELLOW" "$NC" >/dev/tty

    export DEBIAN_FRONTEND=noninteractive
    local apt_log
    apt_log="$(mktemp)"

    # gum 不在 Ubuntu/Debian 默认源中, 需先添加 charmbracelet apt 源(幂等)
    if [[ ! -f /etc/apt/sources.list.d/charm.list ]]; then
        echo "deb [trusted=yes] https://repo.charm.sh/apt/ /" > /etc/apt/sources.list.d/charm.list
    fi

    if apt-get update -qq >"$apt_log" 2>&1 \
        && apt-get install -y -qq gum >>"$apt_log" 2>&1; then
        if command -v gum >/dev/null 2>&1; then
            GUM_BIN="$(command -v gum)"
            printf '%s[gum]%s 安装成功, 将使用 TUI 交互模式\n' "$GREEN" "$NC" >/dev/tty
            rm -f "$apt_log"
            return 0
        fi
    fi

    printf '%s[gum]%s apt 安装失败, 回退到普通 read 交互模式\n' "$YELLOW" "$NC" >/dev/tty
    if [[ -s "$apt_log" ]]; then
        printf '%s[gum]%s apt 日志(最后 10 行):\n%s\n' "$YELLOW" "$NC" \
            "$(tail -n 10 "$apt_log")" >/dev/tty
    fi
    rm -f "$apt_log"
    return 0
}

prompt_input() {
    local prompt="$1"
    local value
    if [[ -n "$GUM_BIN" ]]; then
        if value="$("$GUM_BIN" input --header "$prompt" --prompt "> " --width 50 \
                        </dev/tty 2>/dev/tty)"; then
            printf '%s' "$value"
            return 0
        fi
    fi
    read -r -p "$prompt" value </dev/tty
    printf '%s' "$value"
}

prompt_password() {
    local prompt="$1"
    local value
    if [[ -n "$GUM_BIN" ]]; then
        if value="$("$GUM_BIN" input --password --header "$prompt" --prompt "> " --width 50 \
                        </dev/tty 2>/dev/tty)"; then
            printf '%s' "$value"
            return 0
        fi
    fi
    read -rs -p "$prompt" value </dev/tty
    echo > /dev/tty
    printf '%s' "$value"
}

# ============ 参数解析与默认配置 ============
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
RUNNER_REPO="${RUNNER_REPO:-traechime}"                 # Self-hosted Runner 注册的目标仓库
NGINX_ROOT="${NGINX_ROOT:-/opt/traechime}"              # nginx 静态站点根目录
SERVER_NAME="${SERVER_NAME:-chime.rlagnl.top}"          # 对外域名(证书签发对象)
CERTBOT_EMAIL="${CERTBOT_EMAIL:-250989770@qq.com}"      # Let's Encrypt 通知邮箱(证书过期提醒)
ENABLE_HTTPS="${ENABLE_HTTPS:-1}"                       # 是否启用 HTTPS(1 启用, 0 跳过)
ALIYUN_ACCESS_KEY_ID="${ALIYUN_ACCESS_KEY_ID:-}"        # 阿里云 RAM AccessKey ID(DNS-01 签发证书)
ALIYUN_ACCESS_KEY_SECRET="${ALIYUN_ACCESS_KEY_SECRET:-}" # 阿里云 RAM AccessKey Secret(DNS-01 签发证书)

usage() {
    cat >&2 <<EOF
用法: sudo $0 [-u GitHub用户名] [-t GitHubToken] [-d 域名] [-k AccessKeyID] [-s AccessKeySecret]
  -u  GitHub 用户名 (也可用环境变量 GITHUB_USER 或交互输入)
  -t  GitHub Personal Access Token (需 repo 权限, 用于注册 self-hosted runner)
  -r  Self-hosted Runner 注册的目标仓库 (默认 traechime, 也可用环境变量 RUNNER_REPO)
  -d  HTTPS 域名 (默认 chime.rlagnl.top, 也可用环境变量 SERVER_NAME)
  -k  阿里云 AccessKey ID (DNS-01 签发证书, 需 AliyunDNSFullAccess 权限, 也可用环境变量 ALIYUN_ACCESS_KEY_ID)
  -s  阿里云 AccessKey Secret (也可用环境变量 ALIYUN_ACCESS_KEY_SECRET)
  -h  显示帮助
EOF
    exit 1
}

while getopts "u:t:r:d:k:s:h" opt; do
    case "$opt" in
        u) GITHUB_USER="$OPTARG" ;;
        t) GITHUB_PAT="$OPTARG" ;;
        r) RUNNER_REPO="$OPTARG" ;;
        d) SERVER_NAME="$OPTARG" ;;
        k) ALIYUN_ACCESS_KEY_ID="$OPTARG" ;;
        s) ALIYUN_ACCESS_KEY_SECRET="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

ensure_gum

# ============ 步骤执行器 ============
run_step() {
    local desc="$1"
    local func="$2"
    STEP_NUM=$((STEP_NUM + 1))
    STEP_DESC="$desc"
    STEP_LOG="$(mktemp)"

    printf '\n%s========================================%s\n' "$BLUE" "$NC"
    printf '%s步骤 %s: %s%s\n' "$BLUE" "$STEP_NUM" "$desc" "$NC"
    printf '%s[状态] 开始执行...%s\n' "$YELLOW" "$NC"
    printf '%s----------------------------------------%s\n' "$BLUE" "$NC"

    local start_time=$SECONDS
    "$func" > >(tee "$STEP_LOG") 2>&1
    local duration=$((SECONDS - start_time))
    sleep 0.1

    printf '%s----------------------------------------%s\n' "$GREEN" "$NC"
    printf '%s[状态] 步骤 %s [成功] - %s (耗时 %ss)%s\n' "$GREEN" "$STEP_NUM" "$desc" "$duration" "$NC"

    rm -f "$STEP_LOG"
    STEP_DESC=""
}

# ============ 0. 收集 GitHub 与阿里云凭证 ============
step_0_collect_credentials() {
    if [[ -z "$GITHUB_USER" ]]; then
        while true; do
            GITHUB_USER="$(prompt_input "请输入 GitHub 用户名:")"
            [[ -n "$GITHUB_USER" ]] && break
            echo "用户名不能为空, 请重新输入"
        done
    else
        echo "已通过参数/环境变量获取 GitHub 用户名: $GITHUB_USER"
    fi

    if [[ -z "$GITHUB_PAT" ]]; then
        echo "Token 需要权限: repo (注册 self-hosted runner)"
        while true; do
            GITHUB_PAT="$(prompt_password "请输入 GitHub Personal Access Token:")"
            [[ -n "$GITHUB_PAT" ]] && break
            echo "Token 不能为空, 请重新输入"
        done
    else
        echo "已通过参数/环境变量获取 GitHub Token (隐藏显示)"
    fi
    echo "Self-hosted Runner 将注册到: ${GITHUB_USER}/${RUNNER_REPO}"

    # 收集阿里云 RAM AccessKey(DNS-01 签发证书需要, 仅当启用 HTTPS 时)
    if [[ "${ENABLE_HTTPS:-1}" == "1" ]]; then
        if [[ -z "$ALIYUN_ACCESS_KEY_ID" ]]; then
            while true; do
                ALIYUN_ACCESS_KEY_ID="$(prompt_input "请输入阿里云 AccessKey ID (需 AliyunDNSFullAccess 权限):")"
                [[ -n "$ALIYUN_ACCESS_KEY_ID" ]] && break
                echo "AccessKey ID 不能为空, 请重新输入"
            done
        else
            echo "已通过参数/环境变量获取阿里云 AccessKey ID: $ALIYUN_ACCESS_KEY_ID"
        fi

        if [[ -z "$ALIYUN_ACCESS_KEY_SECRET" ]]; then
            while true; do
                ALIYUN_ACCESS_KEY_SECRET="$(prompt_password "请输入阿里云 AccessKey Secret:")"
                [[ -n "$ALIYUN_ACCESS_KEY_SECRET" ]] && break
                echo "AccessKey Secret 不能为空, 请重新输入"
            done
        else
            echo "已通过参数/环境变量获取阿里云 AccessKey Secret (隐藏显示)"
        fi
    fi
}

# ============ 1. 安装基础工具 ============
step_1_install_base_tools() {
    apt-get update -qq
    # rsync: deploy job 同步静态产物到 webroot; jq: 解析 runner registration token; curl: 下载 runner; git: 通用依赖
    apt-get install -y -qq git rsync jq curl
}

# ============ 2. 配置 nginx 静态站点 ============
step_2_setup_nginx() {
    # 幂等: 未安装才安装
    if ! command -v nginx >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq nginx
    fi
    systemctl enable nginx
    systemctl start nginx

    # 先建 webroot, 避免 nginx 启动时 root 目录不存在
    mkdir -p "$NGINX_ROOT"

    # 'NGINX' 加引号: $uri 等 nginx 变量不被 shell 展开; __DOMAIN__/__ROOT__ 由 sed 替换
    tee /etc/nginx/sites-available/traechime-website > /dev/null <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    root __ROOT__;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
    sed -i "s/__DOMAIN__/${SERVER_NAME}/g" /etc/nginx/sites-available/traechime-website
    sed -i "s#__ROOT__#${NGINX_ROOT}#g" /etc/nginx/sites-available/traechime-website

    # 移除默认站点(避免 80 端口显示 "Welcome to nginx")
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/traechime-website /etc/nginx/sites-enabled/traechime-website
    nginx -t
    systemctl reload nginx
}

# ============ 3. 配置 HTTPS (Let's Encrypt DNS-01) ============
# 使用 DNS-01 验证(阿里云 DNS), 绕开 80 端口的 HTTP-01 验证
# 原因: 80 端口可能被上游拦截或域名尚未解析, HTTP-01 校验不稳定
#       DNS-01 通过 DNS TXT 记录验证, 不依赖 nginx 配置, 证书照常签发
step_3_setup_https() {
    # 可通过 ENABLE_HTTPS=0 显式关闭(例如域名尚未解析到本机时)
    if [[ "${ENABLE_HTTPS:-1}" != "1" ]]; then
        echo "已设置 ENABLE_HTTPS=0, 跳过 HTTPS 配置"
        return 0
    fi

    # 幂等: 证书已签发则跳过, 仅尝试续期
    if [[ -d "/etc/letsencrypt/live/${SERVER_NAME}" ]]; then
        echo "证书已存在: /etc/letsencrypt/live/${SERVER_NAME}, 跳过签发"
        certbot renew --quiet || true
        systemctl reload nginx || true
        return 0
    fi

    # 安装 certbot 本体(apt 源)
    if ! command -v certbot >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq certbot
    fi

    # 安装 certbot-dns-aliyun 第三方插件(阿里云 DNS 验证, 官方未内置)
    # 先确保 pip3 存在; 插件通过 pip 安装, 用阿里云 PyPI 镜像加速
    if ! python3 -c "import certbot_dns_aliyun" >/dev/null 2>&1; then
        command -v pip3 >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3-pip; }
        # Ubuntu 24.04(PEP 668)禁止 pip 装到系统环境, 需 --break-system-packages; 旧版无此参数则走普通安装
        pip3 install -i https://mirrors.aliyun.com/pypi/simple/ certbot-dns-aliyun \
            || pip3 install --break-system-packages -i https://mirrors.aliyun.com/pypi/simple/ certbot-dns-aliyun
    fi

    # 写阿里云 RAM 凭证文件(供 dns-aliyun 插件调用 API 添加 TXT 记录)
    mkdir -p /etc/letsencrypt
    cat > /etc/letsencrypt/aliyun-credentials.ini <<EOF
dns_aliyun_access_key = ${ALIYUN_ACCESS_KEY_ID}
dns_aliyun_access_key_secret = ${ALIYUN_ACCESS_KEY_SECRET}
EOF
    chmod 600 /etc/letsencrypt/aliyun-credentials.ini

    echo "通过 DNS-01 验证签发证书(阿里云 DNS, 不依赖 80 端口)..."
    # --deploy-hook: 签发/续期成功后自动 reload nginx, 后续自动续期无需手动干预
    certbot certonly \
        --authenticator dns-aliyun \
        --dns-aliyun-credentials /etc/letsencrypt/aliyun-credentials.ini \
        -d "$SERVER_NAME" \
        --non-interactive --agree-tos \
        -m "$CERTBOT_EMAIL" \
        --keep-until-expiring \
        --deploy-hook "systemctl reload nginx"

    # 证书签出后重新生成站点配置: 80 端口 301 跳转 HTTPS, 443 端口 SSL 终结 + 静态站点
    # 'NGINX' 加引号: $host/$uri 等 nginx 变量不被 shell 展开; __DOMAIN__/__ROOT__ 由 sed 替换
    tee /etc/nginx/sites-available/traechime-website > /dev/null <<'NGINX'
# HTTP → HTTPS 跳转
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    return 301 https://$host$request_uri;
}

# HTTPS 服务
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name __DOMAIN__;

    ssl_certificate /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;

    root __ROOT__;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
    sed -i "s/__DOMAIN__/${SERVER_NAME}/g" /etc/nginx/sites-available/traechime-website
    sed -i "s#__ROOT__#${NGINX_ROOT}#g" /etc/nginx/sites-available/traechime-website

    nginx -t
    systemctl reload nginx
}

# ============ 4. 安装注册 Self-hosted Runner ============
step_4_setup_runner() {
    echo "确保 jq 已安装(解析 GitHub API 返回的 JSON)..."
    command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq; }

    echo "创建 github-runner 用户(不以 root 跑 runner)..."
    if ! id github-runner >/dev/null 2>&1; then
        useradd -m -s /bin/bash github-runner
    fi

    # CI 的 deploy job 以 github-runner 用户运行, 需要能 rsync 到 webroot
    chown -R github-runner:github-runner "$NGINX_ROOT"

    # 每个仓库使用独立的 runner 目录, 避免与服务器上已有的其他仓库 runner 冲突
    local runner_dir="/home/github-runner/actions-runner-${RUNNER_REPO}"
    # 幂等: 已存在 config.sh 则跳过下载(支持脚本重复执行)
    if [[ ! -f "$runner_dir/config.sh" ]]; then
        mkdir -p "$runner_dir"
        chown github-runner:github-runner "$runner_dir"

        echo "获取最新 runner 版本号(公共 API, 免鉴权)..."
        local ver
        ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
                | jq -r '.tag_name' | sed 's/^v//')"

        echo "下载 runner 二进制(约 150MB, 优先国内镜像加速)..."
        local runner_url="https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-x64-${ver}.tar.gz"
        local mirrors=(
            "https://gh-proxy.com/"
            "https://ghfast.top/"
            "https://ghproxy.net/"
            "https://mirror.ghproxy.com/"
            ""
        )
        local downloaded=0
        for m in "${mirrors[@]}"; do
            echo "尝试下载: ${m:+$m(镜像)}${m:-直连 github.com}"
            if curl -fL# --connect-timeout 10 "${m}${runner_url}" \
                | sudo -u github-runner tar xz -C "$runner_dir" 2>/dev/null; then
                downloaded=1
                break
            fi
            echo "该源失败, 尝试下一个..."
        done
        if [[ "$downloaded" -eq 0 ]]; then
            echo "错误: 所有源下载 runner 二进制均失败"
            return 1
        fi
    else
        echo "runner 二进制已存在, 跳过下载"
    fi
    cd "$runner_dir"

    # 幂等: runner 已配置且 systemd 服务已安装时, 直接复用, 不重新注册
    if [[ -f .runner ]] && systemctl list-unit-files --type=service 'actions.runner.*' --no-legend --no-pager 2>/dev/null | grep -q 'actions.runner'; then
        echo "Runner 已配置且 systemd 服务已安装, 跳过注册, 直接复用现有 runner"
        ./svc.sh start 2>/dev/null || true
        echo "Runner 服务状态:"
        ./svc.sh status 2>/dev/null || systemctl status 'actions.runner.*' --no-pager || true
        return 0
    fi

    echo "获取 runner registration token(用 GITHUB_PAT 调 API, 一次性 ~1h 过期)..."
    local reg_token
    reg_token="$(curl -fsSL -X POST \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_USER}/${RUNNER_REPO}/actions/runners/registration-token" \
        | jq -r '.token')"
    if [[ -z "$reg_token" || "$reg_token" == "null" ]]; then
        echo "错误: 获取 runner registration token 失败, 请检查 PAT 是否有 repo 权限"
        return 1
    fi

    echo "注册 runner(--unattended 免交互, --replace 支持重跑, --labels production)..."
    # 处理 .runner 存在但 systemd 服务未安装的情况(上次注册后 svc.sh install 失败)
    if [[ -f .runner ]]; then
        echo "检测到旧配置残留(.runner 存在但服务未安装), 先移除..."
        sudo -u github-runner ./config.sh remove --token "$reg_token" || {
            echo "移除旧配置失败(可能已在 GitHub 侧注销), 清理本地残留文件..."
            rm -f .runner .credentials .credentials_rsaparams
        }
    fi
    sudo -u github-runner ./config.sh --unattended \
        --url "https://github.com/${GITHUB_USER}/${RUNNER_REPO}" \
        --token "$reg_token" \
        --labels "production" \
        --replace

    echo "安装并启动 systemd 服务(开机自启)..."
    ./svc.sh install github-runner
    ./svc.sh start

    echo "Runner 服务状态:"
    ./svc.sh status 2>/dev/null || systemctl status 'actions.runner.*' --no-pager || true
}

# ============ 5. 验证部署准备 ============
step_5_verify() {
    echo "=== 基础设施验证 ==="

    if [[ -d "$NGINX_ROOT" ]]; then
        echo "[OK] webroot 已创建: $NGINX_ROOT"
    else
        echo "[FAIL] webroot 不存在: $NGINX_ROOT"
    fi

    if nginx -t 2>&1; then
        echo "[OK] nginx 配置语法正确"
    else
        echo "[FAIL] nginx 配置语法错误"
    fi

    local runner_status
    runner_status="$(systemctl is-active 'actions.runner.*' 2>/dev/null || echo unknown)"
    echo "Self-hosted Runner 服务状态: $runner_status"

    echo ""
    echo "=== 后续步骤 ==="
    echo "1. 确认仓库 Settings > Actions > Runners 里出现带 production 标签的 runner"
    echo "2. 确认仓库 Settings > Actions > General 的 Workflow permissions 设为 Read and write"
    echo "3. push 到 develop 分支触发 CI(或手动 workflow_dispatch)"
    echo "4. 部署完成后访问: https://${SERVER_NAME}"
}

# ============ 执行所有步骤 ============
run_step "收集 GitHub 与阿里云凭证"     step_0_collect_credentials
run_step "安装基础工具"                 step_1_install_base_tools
run_step "配置 nginx 静态站点"          step_2_setup_nginx
run_step "配置 HTTPS 证书"              step_3_setup_https
run_step "安装注册 Self-hosted Runner"  step_4_setup_runner
run_step "验证部署准备"                 step_5_verify

printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%s服务器初始化完成!%s\n' "$GREEN" "$NC"
printf 'webroot: %s\n' "$NGINX_ROOT"
printf '访问域名: %s\n' "$SERVER_NAME"
printf 'runner 目标仓库: %s\n' "${GITHUB_USER}/${RUNNER_REPO}"
printf '\n下一步: 确认 runner 上线后, push 到 develop 触发部署\n'
printf '部署完成后访问: https://%s\n' "$SERVER_NAME"
printf '%s========================================%s\n' "$GREEN" "$NC"
