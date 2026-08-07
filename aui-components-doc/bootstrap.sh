#!/usr/bin/env bash
# 部署引导脚本: 安装 nvm/Node/npm 源/git, 克隆项目, 安装依赖, 启动服务, 配置 nginx
# 每个步骤在「执行前 / 执行中 / 执行后」都会输出状态; 失败时打印错误信息并终止
# 步骤划分依据脚本中的 `# ============ N. xxx ============` 注释

set -euo pipefail  # 未定义变量报错, 管道失败传递, 命令失败由 ERR trap 统一处理并退出
set -E             # errtrace: 让 ERR trap 传播进 step_* 函数内部, 否则函数内命令失败时不会触发 on_error

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
# 脚本包含 apt/systemctl/pm2 startup 等操作, 必须以 root 身份运行
if [[ $EUID -ne 0 ]]; then
    printf '%s错误: 本脚本必须以 root 权限执行。%s\n' "$RED" "$NC" >&2
    printf '请使用 sudo 重新运行, 例如:%s\n' "$NC" >&2
    printf '  sudo %s%s%s\n' "$0" "${*:+ }" "$*" >&2
    exit 1
fi

# 保存原始 stdout/stderr 到 fd 3/4, 供 on_error 绕过 run_step 里的 tee 直接写终端
# (否则 trap 输出会被 tee 写进 $STEP_LOG, 造成错误信息里混入 trap 自身输出)
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
# 设计目标: 在「系统已装 gum」→「下载静态 gum」→「回退到 read」三级中自动降级,
# 任何环节失败都不影响脚本继续运行, 只是交互体验从 TUI 退化为普通 read.
GUM_BIN=""

ensure_gum() {
    # 1) 系统已安装: 直接复用 PATH 中的 gum
    if command -v gum >/dev/null 2>&1; then
        GUM_BIN="$(command -v gum)"
        return 0
    fi
    # 2) 之前下载过的临时副本(同一台机器重复执行时省一次下载)
    local tmp_gum="/tmp/gum-bootstrap/gum"
    if [[ -x "$tmp_gum" ]]; then
        GUM_BIN="$tmp_gum"
        return 0
    fi
    # 3) 自动下载静态二进制
    #    - 锁定版本避免上游破坏性变更; 失败则静默回退到 read
    #    - 仅支持 Linux x86_64/arm64 (本脚本本就要求 root + Linux 部署环境)
    local arch os version
    arch="$(uname -m)"
    case "$arch" in
        x86_64)        arch="x86_64" ;;
        aarch64|arm64) arch="arm64"  ;;
        *)  # 不支持的架构(如 mips/ppc): 静默走回退, 不报错
            return 0 ;;
    esac
    os="Linux"
    version="0.14.5"   # 如需升级, 修改此处即可
    local url="https://github.com/charmbracelet/gum/releases/download/v${version}/gum_${version}_${os}_${arch}.tar.gz"
    local tmp_dir="/tmp/gum-bootstrap"
    mkdir -p "$tmp_dir"

    # 必须打印提示: 否则国内服务器访问 GitHub releases 慢时, 脚本会静默 hang,
    # 用户看到的是"一执行就卡住无输出", 误以为脚本挂死.
    # 写到 /dev/tty 而非 stdout, 避免被外层管道/重定向吞掉.
    printf '%s[gum]%s 未检测到 gum, 正在下载静态二进制 (最多 30s)...\n' "$YELLOW" "$NC" >/dev/tty

    # 关键: 必须给 curl 设超时, 否则 TCP/TLS 阶段可能 hang 数分钟
    #   --connect-timeout 10: TCP 连接 + TLS 握手上限 10s (国内 DNS 污染/丢包时快速失败)
    #   --max-time 30:        整个下载上限 30s (大文件下载慢时快速放弃)
    # 任一步失败都跳到末尾 return 0, 让 prompt_* 走 read 回退, 不影响主流程
    if curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$tmp_dir/gum.tar.gz" 2>/dev/null \
        && tar -xzf "$tmp_dir/gum.tar.gz" -C "$tmp_dir" 2>/dev/null; then
        # tar 包内二进制路径可能是 ./gum 或 gum_Linux_x86_64/gum, 两种都试
        local extracted_bin=""
        for candidate in "$tmp_dir/gum" "$tmp_dir/gum_${os}_${arch}/gum"; do
            if [[ -f "$candidate" ]]; then
                extracted_bin="$candidate"
                break
            fi
        done
        if [[ -n "${extracted_bin:-}" ]]; then
            chmod +x "$extracted_bin"
            GUM_BIN="$extracted_bin"
            printf '%s[gum]%s 下载成功, 将使用 TUI 交互模式\n' "$GREEN" "$NC" >/dev/tty
            return 0
        fi
    fi
    # 4) 下载/解压失败: GUM_BIN 保持空字符串, 由 prompt_* 函数走 read 回退
    printf '%s[gum]%s 下载失败, 回退到普通 read 交互模式\n' "$YELLOW" "$NC" >/dev/tty
    return 0
}

# 通用文本输入: 优先 gum input, 失败回退到 read </dev/tty
# 用法: GIT_USER="$(prompt_input "请输入 GitHub 用户名:")"
prompt_input() {
    local prompt="$1"
    local value
    if [[ -n "$GUM_BIN" ]]; then
        # 关键: gum 的 TUI 走 stderr, 必须显式重定向到 /dev/tty,
        # 否则在 run_step 的 `> >(tee) 2>&1` 包裹下, stderr 是 pipe 而非 tty,
        # gum 会判定非交互终端而拒绝渲染或直接退出.
        # stdout 仍走命令替换被捕获, 用来取回用户输入的 value.
        if value="$("$GUM_BIN" input --header "$prompt" --prompt "> " --width 50 \
                        </dev/tty 2>/dev/tty)"; then
            printf '%s' "$value"
            return 0
        fi
    fi
    # 回退: 普通交互输入. read -p 提示走 stderr, 会随 run_step 的 tee 显示到终端
    read -r -p "$prompt" value </dev/tty
    printf '%s' "$value"
}

# 密码输入: 优先 gum input --password, 失败回退到 read -s </dev/tty
# 用法: GIT_TOKEN="$(prompt_password "请输入 GitHub Token:")"
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
    # 回退: -s 静默模式不回显, 防止 token 明文出现在屏幕/日志
    read -rs -p "$prompt" value </dev/tty
    # -s 不会在回车后换行, 这里补一个换行让光标移到下一行.
    # 必须写到 /dev/tty, 不能用普通 echo, 否则换行会被 $(...) 捕获进 value.
    echo > /dev/tty
    printf '%s' "$value"
}

# 在 trap 安装后尽早探测 gum, 让后续所有 prompt_* 都能直接使用 GUM_BIN
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
    # 通过进程替换 > >(tee) 把输出同时写到终端和日志文件:
    #   * 实时显示命令原始输出
    #   * 失败时供 on_error 提取错误信息
    # 关键: 进程替换不会为函数创建子 shell, 因此 cd/export/source 等副作用会保留到后续步骤
    "$func" > >(tee "$STEP_LOG") 2>&1

    local duration=$((SECONDS - start_time))
    # 短暂等待, 确保 tee 已把缓冲写入终端与日志
    sleep 0.1

    # —— 执行后(成功) ——
    printf '%s----------------------------------------%s\n' "$GREEN" "$NC"
    printf '%s[状态] 步骤 %s [成功] - %s (耗时 %ss)%s\n' "$GREEN" "$STEP_NUM" "$desc" "$duration" "$NC"

    rm -f "$STEP_LOG"
    STEP_DESC=""
}

# ============ 1. 安装 nvm ============
step_1_install_nvm() {
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    # 加载 nvm(脚本内必须手动 source, 否则后续 nvm 命令不存在)
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

# ============ 2. 安装 Node LTS ============
step_2_install_node() {
    nvm install 22
    nvm use 22
    nvm alias default 22
}

# ============ 3. 切换 npm 源到淘宝镜像 ============
step_3_switch_npm_registry() {
    npm install -g nrm
    nrm use taobao
    npm install -g pm2
}

# ============ 4. 安装 git ============
step_4_install_git() {
    apt update
    apt install git -y
}

# ============ 5. 克隆项目 ============
step_5_clone_project() {
    # 兼容目录不存在的情况: 先创建再进入(-p 已存在时不报错)
    mkdir -p /root/workspace
    cd /root/workspace
    # 交互式输入凭证(总是提示输入, 不复用环境变量, 避免误用旧值导致鉴权失败)
    # prompt_input/prompt_password 已封装好 gum 优先 + read 回退逻辑:
    #   * gum 可用 -> 美观的 TUI 输入框
    #   * gum 不可用 -> 自动回退到 read </dev/tty, 仍能在 `curl|bash` 管道场景下工作
    while true; do
        GIT_USER="$(prompt_input "请输入 GitHub 用户名:")"
        [[ -n "$GIT_USER" ]] && break
        echo "用户名不能为空, 请重新输入"
    done
    while true; do
        GIT_TOKEN="$(prompt_password "请输入 GitHub Personal Access Token:")"
        [[ -n "$GIT_TOKEN" ]] && break
        echo "Token 不能为空, 请重新输入"
    done
    REPO_URL="https://github.com/Rlagnl/ai-chat-demo-app.git"
    # 禁用 git 自身的交互提示, 避免凭证错误时卡死(凭证由 helper 提供)
    export GIT_TERMINAL_PROMPT=0
    # 用临时 credential helper clone, 凭证不落地、不进 history
    # 注: 本脚本未开启 set -x, 且 git 不会回显 helper 提供的凭证, 因此日志中不会出现 token
    git -c credential.helper="!f() { echo username=${GIT_USER}; echo password=${GIT_TOKEN}; }; f" \
        clone "$REPO_URL"
}

# ============ 6. 安装依赖 ============
step_6_install_deps() {
    cd ai-chat-demo-app
    corepack enable
    pnpm install
    pnpm turbo build filter=aui-components-doc
}

# ============ 7. 启动服务 ============
step_7_start_service() {
    cd apps/docs/aui-components-doc
    pm2 start pnpm --name aui-components-doc -- start
}

# ============ 8. 配置 pm2 开机自启 ============
step_8_pm2_autostart() {
    sudo env PATH=$PATH:$(dirname $(dirname $(which node))) \
         $(which pm2) startup systemd -u $USER --hp $HOME
    # 保存进程列表, 开机后自动恢复
    pm2 save
}

# ============ 9. 安装 nginx ============
step_9_install_nginx() {
    apt install nginx -y
    systemctl enable nginx
    systemctl start nginx
    # 用 sudo + heredoc 写入 nginx 配置
    # 注意 EOF 加了单引号 'EOF', 这样 $host、$remote_addr 等 nginx 变量不会被 shell 展开
    sudo tee /etc/nginx/sites-available/aui-components-doc > /dev/null <<'EOF'
server {
    listen 80;

    server_name_;

    location / {
        proxy_pass http://127.0.0.1:3000;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    # 启用站点: 建立 sites-enabled 软链接
    sudo ln -sf /etc/nginx/sites-available/aui-components-doc /etc/nginx/sites-enabled/aui-components-doc
    # 测试配置语法(出错就退出, 不重启 nginx)
    sudo nginx -t
    # 重载 nginx 使配置生效
    sudo systemctl reload nginx
}

# ============ 执行所有步骤 ============
run_step "安装 nvm"                  step_1_install_nvm
run_step "安装 Node LTS"             step_2_install_node
run_step "切换 npm 源到淘宝镜像"      step_3_switch_npm_registry
run_step "安装 git"                  step_4_install_git
run_step "克隆项目"                  step_5_clone_project
run_step "安装依赖"                  step_6_install_deps
run_step "启动服务"                  step_7_start_service
run_step "配置 pm2 开机自启"          step_8_pm2_autostart
run_step "安装 nginx"                step_9_install_nginx

printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%s所有步骤执行完成! 服务已部署成功。%s\n' "$GREEN" "$NC"
