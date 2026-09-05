#!/usr/bin/env bash
# Docker 部署引导脚本: 安装 Docker, 创建 compose 配置, 拉取启动服务, 配置 nginx, 配置 HTTPS, 安装注册 Self-hosted Runner
# 参考 langgraph-aui-app/bootstrap.sh 的分步骤执行 + 错误处理 + gum 交互模式
# GITHUB_USER / GITHUB_PAT 支持三种传入方式:
#   1) 命令行参数: sudo ./docker_bootstrap.sh -u <user> -t <token>
#   2) 环境变量:   sudo GITHUB_USER=... GITHUB_PAT=... ./docker_bootstrap.sh
#   3) 交互式输入: 不传任何参数, 脚本运行后用 gum/read 提示输入
#
# ALIYUN_ACCESS_KEY_ID / ALIYUN_ACCESS_KEY_SECRET 同样支持三种传入方式(DNS-01 签发证书):
#   1) 命令行参数: sudo ./docker_bootstrap.sh -k <AccessKeyID> -s <AccessKeySecret>
#   2) 环境变量:   sudo ALIYUN_ACCESS_KEY_ID=... ALIYUN_ACCESS_KEY_SECRET=... ./docker_bootstrap.sh
#   3) 交互式输入: 不传时脚本运行后提示输入
#
# HTTPS 通过 Let's Encrypt DNS-01(阿里云 DNS)签发证书, 域名默认 doc.aui.rlagnl.top
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
    # 仅在有步骤上下文时打印, 避免脚本启动前的意外错误也走这里
    if [[ -n "$STEP_DESC" ]]; then
        # 绕过 run_step 里的 tee 重定向, 直接写原始终端, 避免污染 $STEP_LOG
        exec 1>&3 2>&4
        printf '\n%s========================================%s\n' "$RED" "$NC"
        printf '%s[失败] 步骤 %s: %s (退出码: %s)%s\n' "$RED" "$STEP_NUM" "$STEP_DESC" "$code" "$NC"
        # 等待 tee 刷新缓冲, 然后提取最近输出作为错误信息
        if [[ -n "$STEP_LOG" && -f "$STEP_LOG" ]]; then
            sleep 0.1
            printf '%s最近输出(错误信息):%s\n' "$RED" "$NC"
            tail -n 20 "$STEP_LOG" | sed 's/^/    /'
        fi
        printf '%s========================================%s\n' "$RED" "$NC"
        printf '%s脚本因步骤 %s 失败而终止。%s\n' "$RED" "$STEP_NUM" "$NC"
    fi
    # 清理临时日志
    [[ -n "$STEP_LOG" && -f "$STEP_LOG" ]] && rm -f "$STEP_LOG"
    exit "$code"
}
trap on_error ERR

# ============ gum 自动检测 + 静默回退 ============
# 设计目标: 在「系统已装 gum」→「apt 安装 gum」→「回退到 read」三级中自动降级,
# 任何环节失败都不影响脚本继续运行, 只是交互体验从 TUI 退化为普通 read.
GUM_BIN=""

ensure_gum() {
    # 1) 系统已安装: 直接复用 PATH 中的 gum
    if command -v gum >/dev/null 2>&1; then
        GUM_BIN="$(command -v gum)"
        return 0
    fi

    # 2) 通过 apt 安装 (稳定优先, 版本旧一点可接受)
    printf '%s[gum]%s 未检测到 gum, 尝试通过 apt 安装...\n' "$YELLOW" "$NC" >/dev/tty

    # 避免 apt 交互式提示卡住脚本
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
        # 验证安装真的成功
        if command -v gum >/dev/null 2>&1; then
            GUM_BIN="$(command -v gum)"
            printf '%s[gum]%s 安装成功, 将使用 TUI 交互模式\n' "$GREEN" "$NC" >/dev/tty
            rm -f "$apt_log"
            return 0
        fi
    fi

    # 3) apt 失败: 打印日志末尾帮助诊断, 回退到 read (不影响主流程)
    printf '%s[gum]%s apt 安装失败, 回退到普通 read 交互模式\n' "$YELLOW" "$NC" >/dev/tty
    if [[ -s "$apt_log" ]]; then
        printf '%s[gum]%s apt 日志(最后 10 行):\n%s\n' "$YELLOW" "$NC" \
            "$(tail -n 10 "$apt_log")" >/dev/tty
    fi
    rm -f "$apt_log"
    return 0
}

# 通用文本输入: 优先 gum input, 失败回退到 read </dev/tty
prompt_input() {
    local prompt="$1"
    local value
    if [[ -n "$GUM_BIN" ]]; then
        # gum 的 TUI 走 stderr, 必须显式重定向到 /dev/tty, 否则在 run_step 的 tee 包裹下会拒绝渲染
        if value="$("$GUM_BIN" input --header "$prompt" --prompt "> " --width 50 \
                        </dev/tty 2>/dev/tty)"; then
            printf '%s' "$value"
            return 0
        fi
    fi
    read -r -p "$prompt" value </dev/tty
    printf '%s' "$value"
}

# 密码输入: 优先 gum input --password, 失败回退到 read -s </dev/tty
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
    # -s 静默模式不回显, 防止 token 明文出现在屏幕/日志
    read -rs -p "$prompt" value </dev/tty
    # -s 不会在回车后换行, 补一个换行到 /dev/tty (不能用 echo, 会被 $(...) 捕获)
    echo > /dev/tty
    printf '%s' "$value"
}

# ============ 参数解析 ============
# 先读取环境变量作为默认值, 再用命令行参数覆盖, 最后缺失项交由交互式输入补全
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
# runner 注册的目标仓库(应用仓库), 可用环境变量 RUNNER_REPO 或 -r 参数覆盖
RUNNER_REPO="${RUNNER_REPO:-ai-chat-demo-app}"
SERVER_NAME="${SERVER_NAME:-doc.aui.rlagnl.top}"          # 对外域名(证书签发对象)
CERTBOT_EMAIL="${CERTBOT_EMAIL:-250989770@qq.com}"        # Let's Encrypt 通知邮箱(证书过期提醒)
ENABLE_HTTPS="${ENABLE_HTTPS:-1}"                         # 是否启用 HTTPS(1 启用, 0 跳过)
ALIYUN_ACCESS_KEY_ID="${ALIYUN_ACCESS_KEY_ID:-}"          # 阿里云 RAM AccessKey ID(DNS-01 签发证书)
ALIYUN_ACCESS_KEY_SECRET="${ALIYUN_ACCESS_KEY_SECRET:-}"  # 阿里云 RAM AccessKey Secret(DNS-01 签发证书)

usage() {
    cat >&2 <<EOF
用法: sudo $0 [-u GitHub用户名] [-t GitHubToken] [-d 域名] [-k AccessKeyID] [-s AccessKeySecret]
  -u  GitHub 用户名 (也可用环境变量 GITHUB_USER 或交互输入)
  -t  GitHub Personal Access Token (需 repo + write:packages + read:packages 权限)
      repo: 注册 self-hosted runner; write:packages/read:packages: 推拉 ghcr 镜像
  -r  Self-hosted Runner 注册的目标仓库 (默认 ai-chat-demo-app, 也可用环境变量 RUNNER_REPO)
  -d  HTTPS 域名 (默认 doc.aui.rlagnl.top, 也可用环境变量 SERVER_NAME)
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

# 在 trap 安装后尽早探测 gum, 让后续 prompt_* 都能直接使用 GUM_BIN
ensure_gum

# ============ 步骤执行器 ============
# 用法: run_step "步骤描述" step_function_name
run_step() {
    local desc="$1"
    local func="$2"
    STEP_NUM=$((STEP_NUM + 1))
    STEP_DESC="$desc"
    STEP_LOG="$(mktemp)"

    # —— 执行前 ——
    printf '\n%s========================================%s\n' "$BLUE" "$NC"
    printf '%s步骤 %s: %s%s\n' "$BLUE" "$STEP_NUM" "$desc" "$NC"
    printf '%s[状态] 开始执行...%s\n' "$YELLOW" "$NC"
    printf '%s----------------------------------------%s\n' "$BLUE" "$NC"

    local start_time=$SECONDS

    # —— 执行中 ——
    # 进程替换不会为函数创建子 shell, 因此 cd/export 等副作用会保留到后续步骤
    "$func" > >(tee "$STEP_LOG") 2>&1

    local duration=$((SECONDS - start_time))
    sleep 0.1

    # —— 执行后(成功) ——
    printf '%s----------------------------------------%s\n' "$GREEN" "$NC"
    printf '%s[状态] 步骤 %s [成功] - %s (耗时 %ss)%s\n' "$GREEN" "$STEP_NUM" "$desc" "$duration" "$NC"

    rm -f "$STEP_LOG"
    STEP_DESC=""
}

# ============ 0. 收集 GitHub 凭证 ============
step_0_collect_credentials() {
    # 命令行/环境变量已提供则跳过交互, 否则提示输入
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

# ============ 1. 安装 Docker ============
step_1_install_docker() {
    # 幂等: 已安装则跳过
    if command -v docker >/dev/null 2>&1; then
        echo "Docker 已安装, 跳过安装步骤"
    else
        # Aliyun 镜像源加速, 国内服务器拉取 docker-ce 更稳定
        curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    fi
    systemctl enable docker
    systemctl start docker

    # 配置 Docker Hub 镜像加速器: 国内直连 registry-1.docker.io 会 i/o timeout.
    # 本部署不直接拉 Docker Hub 镜像(app 走 ghcr.io, runner 二进制走 github releases),
    # 但保留加速器以备未来 docker pull Docker Hub 镜像之用.
    # 只放「全量代理」源, 不要放白名单源(如 docker.m.daocloud.io):
    #   白名单源对非白名单镜像会返回 HTTP 错误, 而 Docker 遇到正常 HTTP 错误不会
    #   回退到下一个 mirror, 导致非白名单镜像拉取直接失败.
    # 2026 年实测可用的全量代理源(多源回退, 顺序即优先级):
    #   docker.1ms.run       毫秒镜像
    #   docker.xuanyuan.me   轩辕镜像免费版
    #   docker.1panel.live   1Panel
    # 注: 此处覆盖 /etc/docker/daemon.json, 适用于全新部署的服务器.
    mkdir -p /etc/docker
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
    echo "Docker 镜像加速器已配置:"
    docker info 2>/dev/null | grep -A5 "Registry Mirrors" || cat /etc/docker/daemon.json
}

# ============ 2. 创建 compose 配置 ============
step_2_create_compose() {
    mkdir -p /opt/aui-components-doc
    cd /opt/aui-components-doc
    # EOF 不加引号: ${GITHUB_USER} 需要被 shell 展开写入镜像地址
    # ${GITHUB_USER,,} 把用户名转小写: ACR 命名空间即 GitHub 用户名小写
    cat > docker-compose.yml << EOF
services:
  aui-components-doc:
    image: ghcr.io/${GITHUB_USER,,}/aui-components-doc:latest
    container_name: aui-components-doc
    ports:
      - "127.0.0.1:3000:80"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:80/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
EOF
    echo "docker-compose.yml 已生成:"
    cat docker-compose.yml
}

# ============ 3. 登录 ghcr.io 并拉取启动服务 ============
step_3_login_and_start() {
    cd /opt/aui-components-doc
    # password-stdin: 避免 token 出现在命令行参数/进程列表(/proc/<pid>/cmdline)中
    echo "$GITHUB_PAT" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
    docker compose pull
    # 清理残留的同名容器：显式 container_name 与旧容器（可能因 service 更名成为孤儿）重名时，
    # docker compose up 会报 "Conflict. The container name is already in use"。
    # 强制移除后重建（静态文档无状态，可安全幂等重建）。
    docker rm -f aui-components-doc >/dev/null 2>&1 || true
    # --remove-orphans: 一并清理不属于当前 compose 文件的孤儿容器
    docker compose up -d --remove-orphans
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
    # duration_ms 使用 $request_time(秒, 毫秒精度), nginx 原生无法在 log_format 内乘 1000
    # 使用项目前缀命名避免同机多项目(如 langgraph-aui-app)的 log_format/map 变量冲突
    tee /etc/nginx/conf.d/aui-components-doc-log-format.conf > /dev/null <<'NGINX_CONF'
map $status $aui_components_doc_log_level {
    ~^[23]  info;
    ~^4     warn;
    ~^5     error;
    default info;
}

log_format aui_components_doc_json escape=json '{"timestamp":"$time_iso8601","level":"$aui_components_doc_log_level","service":"aui-components-doc","message":"$request_method $uri $status","event":"http_request","trace_id":"$request_id","http":{"method":"$request_method","uri":"$uri","status":$status},"duration_ms":$request_time,"user_agent":"$http_user_agent"}';
NGINX_CONF

    # 'NGINX' 加引号: $host 等 nginx 变量不被 shell 展开; __DOMAIN__ 由后续 sed 替换
    tee /etc/nginx/sites-available/aui-components-doc > /dev/null <<'NGINX'
server {
    listen 80;
    server_name __DOMAIN__;

    # JSON 访问日志(格式定义见 conf.d/aui-components-doc-log-format.conf)
    access_log /var/log/nginx/access.log aui_components_doc_json;

    # Next.js 静态导出资源不记访问日志, 排除噪音
    location /_next/static/ {
        access_log off;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 图片/字体等静态资源不记访问日志
    location ~* \.(png|jpg|jpeg|gif|ico|svg|webp|woff2?|ttf|eot)$ {
        access_log off;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket 支持
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
    # 将站点配置中的 __DOMAIN__ 占位符替换为实际域名(certbot 按 server_name 匹配签发对象)
    sed -i "s/__DOMAIN__/${SERVER_NAME}/g" /etc/nginx/sites-available/aui-components-doc

    # 移除 nginx 默认站点(遵循工作区规则: 避免 80 端口显示 "Welcome to nginx")
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/aui-components-doc /etc/nginx/sites-enabled/aui-components-doc
    # 测试配置语法, 出错就退出不 reload
    nginx -t
    systemctl reload nginx
}

# ============ 5. 配置 HTTPS (Let's Encrypt DNS-01) ============
# 使用 DNS-01 验证(阿里云 DNS), 绕开 80 端口的 HTTP-01 验证
# 原因: 本项目 server 块含正则 location + 多个 location, certbot --nginx 无法正确注入
#       .well-known/acme-challenge 校验 location, 导致 HTTP-01 校验失败
#       DNS-01 通过 DNS TXT 记录验证, 不依赖 nginx 配置, 证书照常签发
step_5_setup_https() {
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

    # 证书签出后重新生成站点配置: 80 端口 301 跳转 HTTPS, 443 端口 SSL 终结 + 完整反向代理
    # 'NGINX' 加引号: $host 等 nginx 变量不被 shell 展开; __DOMAIN__ 由 sed 替换
    tee /etc/nginx/sites-available/aui-components-doc > /dev/null <<'NGINX'
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

    # JSON 访问日志(格式定义见 conf.d/aui-components-doc-log-format.conf)
    access_log /var/log/nginx/access.log aui_components_doc_json;

    # Next.js 静态导出资源不记访问日志, 排除噪音
    location /_next/static/ {
        access_log off;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 图片/字体等静态资源不记访问日志
    location ~* \.(png|jpg|jpeg|gif|ico|svg|webp|woff2?|ttf|eot)$ {
        access_log off;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # WebSocket 支持
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
    sed -i "s/__DOMAIN__/${SERVER_NAME}/g" /etc/nginx/sites-available/aui-components-doc

    nginx -t
    systemctl reload nginx
}

# ============ 6. 安装注册 Self-hosted Runner ============
# 替代 Watchtower: build 留在 GitHub 托管 runner(VPS 仅 1GB 内存无法 build),
# 本机 runner 仅执行轻量的 docker compose pull && up -d, 由 push 触发, 无需 SSH/docker.io
step_6_setup_runner() {
    echo "确保 jq 已安装(解析 GitHub API 返回的 JSON)..."
    command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq; }

    echo "创建 github-runner 用户并加入 docker 组(不以 root 跑 runner)..."
    # 专用用户 + docker 组: runner 需执行 docker compose, 不以 root 跑 runner(GitHub 安全建议)
    if ! id github-runner >/dev/null 2>&1; then
        useradd -m -s /bin/bash github-runner
    fi
    usermod -aG docker github-runner

    local runner_dir="/home/github-runner/actions-runner"
    # 已存在 config.sh 则跳过下载(支持脚本重复执行)
    if [[ ! -f "$runner_dir/config.sh" ]]; then
        mkdir -p "$runner_dir"
        chown github-runner:github-runner "$runner_dir"

        echo "获取最新 runner 版本号(公共 API, 免鉴权)..."
        # 取最新 runner 版本号(公共 API, 免鉴权); -s 静默避免污染 $(...) 捕获值
        local ver
        ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
                | jq -r '.tag_name' | sed 's/^v//')"

        echo "下载 runner 二进制(约 150MB, 优先国内镜像加速, 显示进度条)..."
        # runner 包在 github.com releases, 国内直连慢, 用国内加速镜像前缀多源回退.
        # 镜像用法: <前缀>https://github.com/...  空前缀=直连 github.com(慢但稳, 兜底).
        # --connect-timeout 10: 仅限制连接握手(死镜像快速失败), 不限制传输(不影响下载完成);
        #   故不会出现"快下完被超时掐断"的情况.
        # -f: HTTP 错误失败; -L: 跟随重定向; -#: 进度条(走 stderr, 不进 tar 管道).
        local runner_url="https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-x64-${ver}.tar.gz"
        local mirrors=(
            "https://gh-proxy.com/"
            "https://ghfast.top/"
            "https://ghproxy.net/"
            "https://mirror.ghproxy.com/"
            ""  # 兜底: 直连 github.com
        )
        local downloaded=0
        for m in "${mirrors[@]}"; do
            echo "尝试下载: ${m:+$m(镜像)}${m:-直连 github.com}"
            # if 条件内: curl 失败不触发 set -e, 继续下一个源
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
    # 用 GITHUB_PAT 调 API 拿 registration token(需 repo scope, 一次性, ~1h 过期无需持久化)
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
    # 安装 systemd 服务并启动(开机自启)
    ./svc.sh install github-runner
    ./svc.sh start

    echo "Runner 服务状态:"
    ./svc.sh status 2>/dev/null || systemctl status 'actions.runner.*' --no-pager || true
}

# ============ 7. 验证部署 ============
step_7_verify() {
    # 容器刚启动需要短暂时间进入 ready 状态
    sleep 2
    local internal_code https_code
    # || echo "000" 兜底: 连接失败时 curl 返回非 0, 用 000 表示不可达, 不触发 set -e
    internal_code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000 || echo "000")"
    echo "容器内部响应(127.0.0.1:3000): $internal_code"
    if [[ "${ENABLE_HTTPS:-1}" == "1" ]]; then
        # --resolve 强制域名解析到 127.0.0.1 并携带 SNI, 正确命中 HTTPS server 块,
        # 同时绕开公网 IP 回环(hairpin NAT)可能不通的问题
        https_code="$(curl -sk --resolve "${SERVER_NAME}:443:127.0.0.1" \
            -o /dev/null -w "%{http_code}" "https://${SERVER_NAME}/" || echo "000")"
        echo "HTTPS 转发响应(https://${SERVER_NAME}): $https_code"
    else
        https_code="000"
    fi
    if [[ "$internal_code" != "200" && "$https_code" != "200" ]]; then
        echo "警告: 服务未正常响应, 请检查容器日志: docker logs aui-components-doc"
    fi
    echo "Self-hosted Runner 服务: $(systemctl is-active 'actions.runner.*' 2>/dev/null || echo unknown)"
}

# ============ 执行所有步骤 ============
run_step "收集 GitHub 凭证"          step_0_collect_credentials
run_step "安装 Docker"               step_1_install_docker
run_step "创建 compose 配置"         step_2_create_compose
run_step "登录 ghcr.io 并启动服务"   step_3_login_and_start
run_step "配置 nginx 反向代理"        step_4_setup_nginx
run_step "配置 HTTPS 证书"            step_5_setup_https
run_step "安装注册 Self-hosted Runner"  step_6_setup_runner
run_step "验证部署"                  step_7_verify

printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%s所有步骤执行完成! 服务已部署成功。%s\n' "$GREEN" "$NC"
printf '访问地址: https://%s\n' "$SERVER_NAME"
printf '项目目录: /opt/aui-components-doc\n'
printf 'git push 即自动部署 (Self-hosted Runner 拉取 ghcr 镜像并重启)\n'
printf '%s========================================%s\n' "$GREEN" "$NC"
