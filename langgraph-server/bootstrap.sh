#!/usr/bin/env bash
# Docker 部署引导脚本: 安装 Docker, 创建 compose 配置(三服务), 配置 nginx + HTTPS, 安装注册 Self-hosted Runner
# HTTPS 方式参考 packages/devops-infrastructure/aui-components-mcp-server/bootstrap.sh(certbot --nginx)
#
# 与 ts-langchain-server 的主要差异:
#   1. Python 版用 langgraph build 构建镜像(非 langgraphjs build)
#   2. docker-compose.yml 包含 postgres + redis + langgraph-server 三个服务
#   3. 不创建 .env(由 CI deploy job 从 GitHub Variables/Secrets 写入,避免明文凭证残留服务器)
#   4. 不执行 docker compose up -d(缺少 .env 时 Postgres 启动失败,首次启动交由 CI 完成)
#   5. nginx 监听 80(HTTP 301 跳转) + 443(HTTPS),proxy_pass 127.0.0.1:2025,支持 SSE 长连接
#   6. HTTPS 用 certbot --nginx(HTTP-01)自动签发 + 改写 nginx
#   7. 数据目录 /opt/langgraph-server/
#   8. 比 TS 版多 Supabase / DashScope / Cohere 相关 RAG 变量
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
SERVER_NAME="${SERVER_NAME:-api.aide.rlagnl.top}"      # 对外域名(证书签发对象)
CERTBOT_EMAIL="${CERTBOT_EMAIL:-250989770@qq.com}"    # Let's Encrypt 通知邮箱(证书过期提醒)
ENABLE_HTTPS="${ENABLE_HTTPS:-1}"                     # 是否启用 HTTPS(1 启用, 0 跳过)

usage() {
    cat >&2 <<EOF
用法: sudo $0 [-u GitHub用户名] [-t GitHubToken] [-d 域名]
  -u  GitHub 用户名 (也可用环境变量 GITHUB_USER 或交互输入)
  -t  GitHub Personal Access Token (需 repo + write:packages + read:packages 权限)
      repo: 注册 self-hosted runner; write:packages/read:packages: 推拉 ghcr 镜像
  -r  Self-hosted Runner 注册的目标仓库 (默认 ai-chat-demo-app, 也可用环境变量 RUNNER_REPO)
  -d  HTTPS 域名 (默认 api.aide.rlagnl.top, 也可用环境变量 SERVER_NAME)
  -h  显示帮助
EOF
    exit 1
}

while getopts "u:t:r:d:h" opt; do
    case "$opt" in
        u) GITHUB_USER="$OPTARG" ;;
        t) GITHUB_PAT="$OPTARG" ;;
        r) RUNNER_REPO="$OPTARG" ;;
        d) SERVER_NAME="$OPTARG" ;;
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

    # 配置 Docker Hub 镜像加速器: postgres/redis 镜像从 Docker Hub 拉取
    mkdir -p /etc/docker
    # 仅在 daemon.json 不存在时写入, 避免覆盖已有配置(幂等)
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

    # 创建 Docker 共享网络(容器间通信, 幂等)
    # 其他子项目(如 langgraph-aui-app)通过此网络用容器名访问 langgraph-server:8000
    docker network create app-network 2>/dev/null || echo "app-network 已存在, 跳过创建"
}

# ============ 2. 创建 compose 配置 ============
# 生产版 compose: 拉取 ghcr 镜像, 无 build 字段
# 注意: 不创建 .env, 由 CI deploy job 从 GitHub Variables/Secrets 写入
# 注意: 不执行 docker compose up, 缺 .env 时 Postgres 启动失败, 首次启动交由 CI
step_2_create_compose() {
    mkdir -p /opt/langgraph-server
    cd /opt/langgraph-server

    # EOF 不加引号: ${GITHUB_USER} 需要被 shell 展开写入镜像地址
    # ${GITHUB_USER,,} 把用户名转小写: ACR 命名空间即 GitHub 用户名小写
    # 端口映射 2025:8000: 容器内 LangGraph Server 监听 8000(由 langgraph build 生成)
    cat > docker-compose.yml << EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: langgraph-postgres
    env_file: .env
    environment:
      POSTGRES_USER: langgraph
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: langgraph
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U langgraph"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: langgraph-redis
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  langgraph-server:
    image: ghcr.io/${GITHUB_USER,,}/langgraph-server:latest
    container_name: langgraph-server
    env_file: .env
    environment:
      POSTGRES_URI: postgres://langgraph:\${POSTGRES_PASSWORD}@postgres:5432/langgraph
      REDIS_URI: redis://redis:6379
      # 生产固定输出 JSON 日志(structlog), 与本地开发 ConsoleRenderer 区分
      LOG_FORMAT: json
    ports:
      - "127.0.0.1:2025:8000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - default
      - app-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/ok"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  pgdata:
  redisdata:

networks:
  app-network:
    external: true
EOF
    echo "docker-compose.yml 已生成:"
    cat docker-compose.yml
}

# ============ 3. 登录 ghcr.io ============
# 仅登录, 不执行 docker compose up -d
# .env 文件由 CI deploy job 首次部署时从 GitHub Variables/Secrets 写入
step_3_login_ghcr() {
    cd /opt/langgraph-server
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

    # JSON 访问日志格式: log_format/map 必须在 http 上下文, 写入 conf.d(被 nginx.conf include)
    # map: 状态码 → 日志级别(2xx/3xx→info, 4xx→warn, 5xx→error)
    # 使用项目前缀命名避免同机多项目(如 langgraph-aui-app)的 log_format/map 变量冲突
    tee /etc/nginx/conf.d/langgraph-server-log-format.conf > /dev/null <<'NGINX_CONF'
map $status $langgraph_server_log_level {
    ~^[23]  info;
    ~^4     warn;
    ~^5     error;
    default info;
}

log_format langgraph_server_json escape=json '{"timestamp":"$time_iso8601","level":"$langgraph_server_log_level","service":"langgraph-server","message":"$request_method $uri $status","event":"http_request","trace_id":"$request_id","http":{"method":"$request_method","uri":"$uri","status":$status},"duration_ms":$request_time,"user_agent":"$http_user_agent"}';
NGINX_CONF

    # 先写 80 端口的初始 HTTP 配置(证书未签发前先按 HTTP 提供服务)
    # 证书签出后由 step_5_setup_https 重写为 80(301 跳转) + 443(SSL 终结)
    # 'NGINX' 加引号: $host 等 nginx 变量不被 shell 展开; __DOMAIN__ 由 sed 替换
    # proxy_buffering off + proxy_cache off: 支持 SSE 流式响应(LangGraph stream 端点)
    # proxy_read_timeout 86400s: SSE 长连接超时设为 24 小时
    tee /etc/nginx/sites-available/langgraph-server > /dev/null <<'NGINX'
server {
    listen 80;
    server_name __DOMAIN__;

    # JSON 访问日志(格式定义见 conf.d/langgraph-server-log-format.conf)
    access_log /var/log/nginx/access.log langgraph_server_json;

    # 关闭缓冲, 支持 SSE 流式响应
    proxy_buffering off;
    proxy_cache off;

    location / {
        proxy_pass http://127.0.0.1:2025;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 透传 request_id 给应用, 应用侧可关联同源 trace_id
        proxy_set_header X-Request-Id $request_id;

        # SSE 长连接支持
        proxy_set_header Connection "";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX
    # 将站点配置中的 __DOMAIN__ 占位符替换为实际域名(certbot --nginx 需按 server_name 匹配)
    sed -i "s/__DOMAIN__/${SERVER_NAME}/g" /etc/nginx/sites-available/langgraph-server

    # 移除 nginx 默认站点(遵循工作区规则: 避免 80 端口显示 "Welcome to nginx")
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/langgraph-server /etc/nginx/sites-enabled/langgraph-server
    nginx -t
    systemctl reload nginx

    # logrotate: 自定义 access_log 文件名无系统默认轮转, 需单独配置防止日志无限增长占满磁盘
    tee /etc/logrotate.d/langgraph-server > /dev/null <<'LOGROTATE'
/var/log/nginx/langgraph-server-access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 www-data adm
    sharedscripts
    postrotate
        [ -s /run/nginx.pid ] && kill -USR1 `cat /run/nginx.pid`
    endscript
}
LOGROTATE
}

# ============ 5. 配置 HTTPS (Let's Encrypt HTTP-01) ============
# 用 certbot certonly --nginx(HTTP-01)只签发证书, 再手动写 80/443 配置
# 不用 certbot --nginx 自动改写: 服务器上已存在其它站点(如 aui-components-mcp-server 的 mcp.aui.rlagnl.top),
#   自动改写会因多站点/复杂 server 块导致本项目的 443 server 块缺失, 使请求落到其它站点的 default server
step_5_setup_https() {
    # 可通过 ENABLE_HTTPS=0 显式关闭(例如域名尚未解析到本机时)
    if [[ "${ENABLE_HTTPS:-1}" != "1" ]]; then
        echo "已设置 ENABLE_HTTPS=0, 跳过 HTTPS 配置"
        return 0
    fi

    # 安装 certbot 及其 nginx 插件(certonly --nginx 需要 nginx 插件)
    if ! command -v certbot >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq certbot python3-certbot-nginx
    fi

    # 签发证书(幂等): 已存在则只续期, 不重复签发
    if [[ -d "/etc/letsencrypt/live/${SERVER_NAME}" ]]; then
        echo "证书已存在: /etc/letsencrypt/live/${SERVER_NAME}, 跳过签发, 仅续期"
        certbot renew --quiet || true
    else
        echo "通过 HTTP-01 验证签发证书(仅签发, 不自动改写 nginx)..."
        # certonly --nginx: HTTP-01 验证, 只签发证书, 不改写 nginx 配置
        certbot certonly --nginx -d "$SERVER_NAME" \
            --non-interactive --agree-tos \
            -m "$CERTBOT_EMAIL" \
            --keep-until-expiring
    fi

    # 无论证书是否已存在, 都重写 nginx 配置(幂等): 保证 443 server 块始终正确
    # 证书已存在但 nginx 配置被改乱时(如之前 certbot --nginx 残留), 重跑也能修复
    # 'NGINX' 加引号: $host 等 nginx 变量不被 shell 展开; __DOMAIN__ 由 sed 替换
    tee /etc/nginx/sites-available/langgraph-server > /dev/null <<'NGINX'
# HTTP → HTTPS 跳转
server {
    listen 80;
    server_name __DOMAIN__;
    return 301 https://$host$request_uri;
}

# HTTPS 服务
server {
    listen 443 ssl;
    server_name __DOMAIN__;

    ssl_certificate /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;

    # JSON 访问日志(格式定义见 conf.d/langgraph-server-log-format.conf)
    access_log /var/log/nginx/access.log langgraph_server_json;

    # 关闭缓冲, 支持 SSE 流式响应
    proxy_buffering off;
    proxy_cache off;

    location / {
        proxy_pass http://127.0.0.1:2025;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 透传 request_id 给应用, 应用侧可关联同源 trace_id
        proxy_set_header X-Request-Id $request_id;

        # SSE 长连接支持
        proxy_set_header Connection "";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX
    sed -i "s/__DOMAIN__/${SERVER_NAME}/g" /etc/nginx/sites-available/langgraph-server

    # 确保软链接存在(幂等): 即使软链接丢失或 step_4 未执行, 重跑本步骤也能让配置生效
    ln -sf /etc/nginx/sites-available/langgraph-server /etc/nginx/sites-enabled/langgraph-server

    nginx -t
    systemctl reload nginx
}

# ============ 6. 安装注册 Self-hosted Runner ============
# build 留在 GitHub 托管 runner, 本机 runner 仅执行轻量的 docker compose pull && up -d
step_6_setup_runner() {
    echo "确保 jq 已安装(解析 GitHub API 返回的 JSON)..."
    command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq; }

    echo "创建 github-runner 用户并加入 docker 组(不以 root 跑 runner)..."
    if ! id github-runner >/dev/null 2>&1; then
        useradd -m -s /bin/bash github-runner
    fi
    usermod -aG docker github-runner

    # deploy job 以 github-runner 用户运行, 需要对项目目录有写权限(写 .env、执行 docker compose)
    # /opt/langgraph-server 由 step_2 以 root 创建, 这里移交所有者
    chown -R github-runner:github-runner /opt/langgraph-server

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
        # 确保服务正在运行(可能因服务器重启而停止)
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
    # 此时 config.sh 会报 "already configured", 需要先 remove 再重新注册
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

# ============ 7. 验证部署准备 ============
# 注意: 服务尚未启动(.env 由 CI 写入), 仅验证基础设施配置
step_7_verify() {
    echo "=== 基础设施验证 ==="

    # 检查 docker-compose.yml
    if [[ -f /opt/langgraph-server/docker-compose.yml ]]; then
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

    # 检查 HTTPS 证书(仅当启用 HTTPS 时)
    if [[ "${ENABLE_HTTPS:-1}" == "1" ]]; then
        if [[ -d "/etc/letsencrypt/live/${SERVER_NAME}" ]]; then
            echo "[OK] HTTPS 证书已签发: /etc/letsencrypt/live/${SERVER_NAME}"
        else
            echo "[WARN] HTTPS 证书未签发, 请确认 step_5 已成功执行"
        fi
    fi

    # 检查 Runner 服务
    local runner_status
    runner_status="$(systemctl is-active 'actions.runner.*' 2>/dev/null || echo unknown)"
    echo "Self-hosted Runner 服务状态: $runner_status"

    echo ""
    echo "=== 后续步骤 ==="
    echo "1. 确认域名 ${SERVER_NAME} 已解析到本机公网 IP"
    echo "2. 在 GitHub 仓库配置 Variables(非敏感) 与 Secrets(敏感), 见部署方案 4.2 节"
    echo "   Variables: LANGSMITH_TRACING / LANGSMITH_ENDPOINT / LANGSMITH_PROJECT /"
    echo "              CLOUDFLARE_ACCOUNT_ID / MCP_SERVER_URL / SUPABASE_URL / DASHSCOPE_BASE_URL"
    echo "   Secrets: LANGSMITH_API_KEY / CLOUDFLARE_API_TOKEN / DEEPSEEK_API_KEY /"
    echo "            MEM0_API_KEY / SUPABASE_SERVICE_ROLE_KEY / DASHSCOPE_API_KEY /"
    echo "            COHERE_API_KEY / POSTGRES_PASSWORD"
    echo "3. 确认仓库 Workflow permissions 设为 Read and write"
    echo "4. 提交代码 push 到 develop 分支触发 CI"
    echo "5. CI deploy job 会自动写入 .env 并执行 docker compose up -d"
    echo "6. 部署完成后访问: https://${SERVER_NAME}/ok"
}

# ============ 执行所有步骤 ============
run_step "收集 GitHub 凭证"           step_0_collect_credentials
run_step "安装 Docker"                step_1_install_docker
run_step "创建 compose 配置"          step_2_create_compose
run_step "登录 ghcr.io"               step_3_login_ghcr
run_step "配置 nginx 反向代理"        step_4_setup_nginx
run_step "配置 HTTPS 证书"            step_5_setup_https
run_step "安装注册 Self-hosted Runner" step_6_setup_runner
run_step "验证部署准备"               step_7_verify

printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%s基础设施初始化完成!%s\n' "$GREEN" "$NC"
printf '项目目录: /opt/langgraph-server\n'
printf 'nginx 端口: 80/443 (HTTP/HTTPS)\n'
printf '内部端口: 127.0.0.1:2025 (容器内 8000)\n'
printf '访问域名: %s\n' "$SERVER_NAME"
printf '\n下一步: 在 GitHub 配置 Variables/Secrets 并 push 到 develop 触发 CI\n'
printf '部署完成后访问: https://%s/ok\n' "$SERVER_NAME"
printf '%s========================================%s\n' "$GREEN" "$NC"
