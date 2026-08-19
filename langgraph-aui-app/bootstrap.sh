#!/usr/bin/env bash
# Docker 部署引导脚本: 安装 Docker, 创建 compose 配置, 登录 ACR, 配置 nginx, 安装注册 Self-hosted Runner
# 参考 packages/devops-infrastructure/ts-langchain-server/bootstrap.sh 结构
#
# 与 ts-langchain-server 的主要差异:
#   1. docker-compose.yml 仅单个服务(langgraph-aui-app),无 postgres/redis
#   2. 端口映射 127.0.0.1:3001:3000(Next.js standalone 监听 3000)
#   3. nginx 监听 8080,proxy_pass 127.0.0.1:3001
#   4. 不创建 .env(由 CI deploy job 从 GitHub Variables 写入,仅 LANGGRAPH_API_URL 一个非敏感变量)
#   5. 不执行 docker compose up -d(缺 .env 时容器无法获取 LANGGRAPH_API_URL,首次启动交由 CI)
#
# GITHUB_USER / GITHUB_PAT 支持三种传入方式:
#   1) 命令行参数: sudo ./bootstrap.sh -u <user> -t <token>
#   2) 环境变量:   sudo GITHUB_USER=... GITHUB_PAT=... ./bootstrap.sh
#   3) 交互式输入: 不传任何参数, 脚本运行后用 gum/read 提示输入
#
# 镜像拉取自 ghcr.io, 使用 GITHUB_PAT 认证

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
# 脚本包含 apt/systemctl/docker 等操作, 必须以 root 身份运行
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

    # gum 不在 Ubuntu/Debian 默认源中, 需先添加 charmbracelet apt 源
    # 幂等: 源文件已存在则跳过
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

# ============ 参数解析 ============
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
RUNNER_REPO="${RUNNER_REPO:-ai-chat-demo-app}"

usage() {
    cat >&2 <<EOF
用法: sudo $0 [-u GitHub用户名] [-t GitHubToken]
  -u  GitHub 用户名 (也可用环境变量 GITHUB_USER 或交互输入)
  -t  GitHub Personal Access Token (需 repo + write:packages + read:packages 权限)
      repo: 注册 self-hosted runner; write:packages/read:packages: 推拉 ghcr 镜像
  -r  Self-hosted Runner 注册的目标仓库 (默认 ai-chat-demo-app, 也可用环境变量 RUNNER_REPO)
  -h  显示帮助
EOF
    exit 1
}

while getopts "u:t:r:h" opt; do
    case "$opt" in
        u) GITHUB_USER="$OPTARG" ;;
        t) GITHUB_PAT="$OPTARG" ;;
        r) RUNNER_REPO="$OPTARG" ;;
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

# ============ 0. 收集 GitHub 凭证 ============
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
        echo "Token 需要权限: repo (注册 runner) + write:packages + read:packages (推拉 ghcr 镜像)"
        while true; do
            GITHUB_PAT="$(prompt_password "请输入 GitHub Personal Access Token:")"
            [[ -n "$GITHUB_PAT" ]] && break
            echo "Token 不能为空, 请重新输入"
        done
    else
        echo "已通过参数/环境变量获取 GitHub Token (隐藏显示)"
    fi
    echo "Self-hosted Runner 将注册到: ${GITHUB_USER}/${RUNNER_REPO}"
}

# ============ 1. 安装 Docker ============
step_1_install_docker() {
    # 幂等: 已安装则跳过
    if command -v docker >/dev/null 2>&1; then
        echo "Docker 已安装, 跳过安装步骤"
    else
        curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    fi
    systemctl enable docker
    systemctl start docker

    # 配置 Docker Hub 镜像加速器(幂等: daemon.json 已存在则跳过)
    mkdir -p /etc/docker
    if [[ ! -f /etc/docker/daemon.json ]]; then
        tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
    "registry-mirrors": [
        "https://docker.1ms.run",
        "https://docker.xuanyuan.me",
        "https://docker.1panel.live"
    ],
    "live-restore": true
}
EOF
        systemctl daemon-reload
        systemctl restart docker
    else
        echo "daemon.json 已存在, 跳过镜像加速器配置"
    fi
    echo "Docker 镜像加速器配置:"
    docker info 2>/dev/null | grep -A5 "Registry Mirrors" || cat /etc/docker/daemon.json
}

# ============ 2. 创建 compose 配置 ============
# 单服务 compose: langgraph-aui-app,env_file: .env(由 CI 写入)
# 不创建 .env, 不执行 docker compose up -d(缺 .env 时首次启动交由 CI)
# networks: app-network 外部网络, 与 ts-langchain-server 共享, 用容器名通信
step_2_create_compose() {
    mkdir -p /opt/langgraph-aui-app
    cd /opt/langgraph-aui-app

    # EOF 不加引号: ${GITHUB_USER} 需要被 shell 展开写入镜像地址
    # ${GITHUB_USER,,} 把用户名转小写: ACR 命名空间即 GitHub 用户名小写
    cat > docker-compose.yml << EOF
services:
  langgraph-aui-app:
    image: ghcr.io/${GITHUB_USER,,}/langgraph-aui-app:latest
    container_name: langgraph-aui-app
    env_file: .env
    ports:
      - "127.0.0.1:3001:3000"
    networks:
      - app-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s

networks:
  app-network:
    external: true
EOF
    echo "docker-compose.yml 已生成:"
    cat docker-compose.yml
}

# ============ 3. 登录 ghcr.io ============
# 仅登录, 不执行 docker compose pull/up -d
# .env 文件由 CI deploy job 首次部署时从 GitHub Variables 写入
step_3_login_ghcr() {
    cd /opt/langgraph-aui-app
    # password-stdin: 避免 token 出现在命令行参数/进程列表中
    echo "$GITHUB_PAT" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
    echo "ghcr.io 登录成功, 首次镜像拉取将由 CI deploy job 执行"
}

# ============ 4. 配置 nginx 反向代理 ============
step_4_setup_nginx() {
    # 幂等: 未安装才安装
    if ! command -v nginx >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq nginx
    fi
    systemctl enable nginx
    systemctl start nginx

    # 'NGINX' 加引号: $host 等 nginx 变量不被 shell 展开
    # proxy_buffering off + proxy_cache off: 支持 SSE 流式响应(LangGraph stream 端点)
    # proxy_read_timeout 86400s: SSE 长连接超时设为 24 小时
    tee /etc/nginx/sites-available/langgraph-aui-app > /dev/null <<'NGINX'
server {
    listen 8080;
    server_name _;

    # 关闭缓冲, 支持 SSE 流式响应
    proxy_buffering off;
    proxy_cache off;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        # 用 $http_host 保留客户端原始 Host(含端口, 如 8.130.30.183:8080),
        # 避免 Next.js Server Actions 校验 x-forwarded-host 与 origin 不匹配
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE 长连接支持
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX
    # 移除 nginx 默认站点(遵循工作区规则: 避免 80 端口显示 "Welcome to nginx")
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/langgraph-aui-app /etc/nginx/sites-enabled/langgraph-aui-app
    nginx -t
    systemctl reload nginx
}

# ============ 5. 安装注册 Self-hosted Runner ============
# build 留在 GitHub 托管 runner, 本机 runner 仅执行轻量的 docker compose pull && up -d
step_5_setup_runner() {
    echo "确保 jq 已安装(解析 GitHub API 返回的 JSON)..."
    command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq; }

    echo "创建 github-runner 用户并加入 docker 组(不以 root 跑 runner)..."
    if ! id github-runner >/dev/null 2>&1; then
        useradd -m -s /bin/bash github-runner
    fi
    usermod -aG docker github-runner

    # deploy job 以 github-runner 用户运行, 需要对项目目录有写权限(写 .env、执行 docker compose)
    chown -R github-runner:github-runner /opt/langgraph-aui-app

    local runner_dir="/home/github-runner/actions-runner"
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
    # 避免每次重跑脚本都在 GitHub 上产生重复的 Offline runner 记录
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

# ============ 6. 验证部署准备 ============
# 注意: 服务尚未启动(.env 由 CI 写入), 仅验证基础设施配置
step_6_verify() {
    echo "=== 基础设施验证 ==="

    # 检查 docker-compose.yml
    if [[ -f /opt/langgraph-aui-app/docker-compose.yml ]]; then
        echo "[OK] docker-compose.yml 已生成"
    else
        echo "[FAIL] docker-compose.yml 不存在"
    fi

    # 检查 nginx 配置
    if nginx -t 2>&1; then
        echo "[OK] nginx 配置语法正确"
    else
        echo "[FAIL] nginx 配置语法错误"
    fi

    # 检查 Runner 服务
    local runner_status
    runner_status="$(systemctl is-active 'actions.runner.*' 2>/dev/null || echo unknown)"
    echo "Self-hosted Runner 服务状态: $runner_status"

    echo ""
    echo "=== 后续步骤 ==="
    echo "1. 在 GitHub 仓库配置 2 个 Variables(非敏感, 日志可见):"
    echo "   - LANGGRAPH_API_URL=http://ts-langchain-server:8000"
    echo "   - NEXT_PUBLIC_LANGGRAPH_ASSISTANT_ID=agent"
    echo "2. 确认仓库 Workflow permissions 设为 Read and write"
    echo "3. 提交代码 push 到 develop 分支触发 CI(或手动 workflow_dispatch)"
    echo "4. CI deploy job 会自动写入 .env 并执行 docker compose up -d"
    echo "5. 部署完成后访问: http://<服务器IP>:8080"
}

# ============ 执行所有步骤 ============
run_step "收集 GitHub 凭证"          step_0_collect_credentials
run_step "安装 Docker"               step_1_install_docker
run_step "创建 compose 配置"         step_2_create_compose
run_step "登录 ghcr.io"              step_3_login_ghcr
run_step "配置 nginx 反向代理"        step_4_setup_nginx
run_step "安装注册 Self-hosted Runner"  step_5_setup_runner
run_step "验证部署准备"              step_6_verify

SERVER_IP="$(curl -s ifconfig.me 2>/dev/null || echo "<服务器IP>")"
printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%s基础设施初始化完成!%s\n' "$GREEN" "$NC"
printf '项目目录: /opt/langgraph-aui-app\n'
printf 'nginx 端口: 8080 (对外)\n'
printf '内部端口: 127.0.0.1:3001 (容器内 3000)\n'
printf '\n下一步: 在 GitHub 配置 2 个 Variables 并 push 到 develop 触发 CI\n'
printf '部署完成后访问: http://%s:8080\n' "$SERVER_IP"
printf '%s========================================%s\n' "$GREEN" "$NC"
