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
    #    Ubuntu 24.04+ / Debian 13+ 官方仓库已包含 gum;
    #    旧系统(如 Ubuntu 22.04)仓库没有 gum 包, 安装会失败, 自动回退到 read.
    #    相比下载静态二进制: apt 走系统源(国内服务器配了阿里云/清华源就很快),
    #    无需依赖 GitHub/代理, 稳定性高一个数量级.
    printf '%s[gum]%s 未检测到 gum, 尝试通过 apt 安装...\n' "$YELLOW" "$NC" >/dev/tty

    # 避免 apt 交互式提示卡住脚本 (如 tzdata 配置弹窗等待输入)
    export DEBIAN_FRONTEND=noninteractive
    # apt 输出量大(几百行), 重定向到临时日志, 失败时打印末尾辅助诊断
    local apt_log
    apt_log="$(mktemp)"

    # apt-get update: 刷新包索引, 避免过期索引导致安装失败
    # apt-get install: -y 自动 yes, -qq 静默模式减少输出
    # 两条命令用 && 链接放 if 条件里, 失败不会触发 set -e, 直接走回退分支
    if apt-get update -qq >"$apt_log" 2>&1 \
        && apt-get install -y -qq gum >>"$apt_log" 2>&1; then
        # 验证安装真的成功: 极少数情况 apt 返回 0 但实际没装上(如包名错误)
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
    # nvm 管理的 node/npm/pm2 只在 nvm 的 PATH 里(/root/.nvm/versions/node/v22.x/bin/),
    # 用户登录的新 shell 不会自动加载 nvm, 导致手动执行 pm2 报 "command not found".
    # 创建 symlink 到 /usr/local/bin(系统默认 PATH), 让所有用户和重启后的 systemd 都能用.
    ln -sf "$(which node)" /usr/local/bin/node
    ln -sf "$(which npm)"  /usr/local/bin/npm
    ln -sf "$(which pm2)"  /usr/local/bin/pm2
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

# ============ 6. 确保 swap (build 前置) ============
step_6_ensure_swap() {
    # Next.js build 峰值内存 2-4GB, 1GB 内存的 VPS 不加 swap 会 OOM 卡死.
    # 幂等: 已有足够 swap(>=1GB) 则跳过, 支持脚本重复执行.
    local current_swap_kb
    current_swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
    # 1GB = 1048576 KB, 已有 >= 1GB swap 就不再创建
    if [[ "${current_swap_kb:-0}" -ge 1048576 ]]; then
        echo "已有 swap $((current_swap_kb / 1024)) MB, 跳过创建"
        return 0
    fi

    echo "当前 swap $((current_swap_kb / 1024)) MB, 不足以支撑 Next.js build, 创建 4GB swap..."

    local swap_file="/swapfile"

    # 检查根分区剩余空间: 空间不足时 fallocate 会失败, dd 会写到磁盘满后卡死,
    # 提前检查并显式失败, 让 on_error trap 清晰报告原因
    local free_mb
    free_mb="$(df -m / | awk 'NR==2 {print $4}')"
    if [[ "${free_mb:-0}" -lt 4096 ]]; then
        echo "错误: 根分区剩余空间仅 ${free_mb} MB, 需要 4096 MB, 无法创建 swap"
        echo "请清理磁盘空间或手动配置 swap 后重试"
        return 1
    fi

    # 创建 swap 文件: 优先 fallocate(瞬间完成), 某些文件系统(ZFS/Btrfs)不支持时 fallback 到 dd
    if [[ -f "$swap_file" ]]; then
        echo "swap 文件已存在但未启用, 重新格式化并启用"
    else
        if ! fallocate -l 4G "$swap_file" 2>/dev/null; then
            echo "fallocate 不支持, 改用 dd 创建 (可能需要 3-5 分钟)..."
            dd if=/dev/zero of="$swap_file" bs=1M count=4096 status=progress
        fi
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file" >/dev/null
    swapon "$swap_file"

    # 确保 kernel 积极使用 swap: 某些云服务器(阿里云/腾讯云)默认 swappiness=1 或 0,
    # 内核宁可 OOM kill 也不用 swap, 必须显式调到 60(默认值)才会在内存紧张时换页.
    # 用 || true 避免 sysctl 失败影响主流程(swappiness 设置失败不影响 swap 本身生效)
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true

    # 写入 fstab 持久化(重启后自动挂载), 检查避免重复写入
    if ! grep -q "^${swap_file} " /etc/fstab; then
        echo "${swap_file} none swap sw 0 0" >> /etc/fstab
    fi

    echo "swap 创建完成:"
    free -h
}

# ============ 7. 安装依赖 ============
step_7_install_deps() {
    cd ai-chat-demo-app
    corepack enable
    pnpm install
    # 注意 filter 语法: 必须是 --filter=<pkg>, 不能写成 filter=<pkg>.
    # 错误写法 `filter=aui-components-doc` 缺少 -- 前缀, turbo 不会把它当 filter 选项,
    # 而是当作第二个 task 名, 导致 --filter 失效, turbo 会构建 monorepo 里所有 package
    # 的 build 任务(不只是 aui-components-doc), 其他 package 卡住时整体看起来像挂死.
    #
    # --concurrency=1: 强制串行构建. --filter 会自动构建目标包的依赖包(meta/knowledge-builder),
    # turbo 默认并行构建无依赖关系的包, 多个 node 进程同时跑导致内存叠加(峰值 4-8GB)触发 OOM.
    # 串行构建时内存峰值 = 单个任务最大值(约 2-4GB), 1GB 内存 + 4GB swap = 5GB 够用.
    pnpm turbo build --filter=aui-components-doc --concurrency=1
}

# ============ 8. 启动服务 ============
step_8_start_service() {
    cd apps/docs/aui-components-doc
    pm2 start pnpm --name aui-components-doc -- start
}

# ============ 9. 配置 pm2 开机自启 ============
step_9_pm2_autostart() {
    sudo env PATH=$PATH:$(dirname $(dirname $(which node))) \
         $(which pm2) startup systemd -u $USER --hp $HOME
    # 保存进程列表, 开机后自动恢复
    pm2 save
}

# ============ 10. 安装 nginx ============
step_10_install_nginx() {
    apt install nginx -y
    systemctl enable nginx
    systemctl start nginx
    # 用 sudo + heredoc 写入 nginx 配置
    # 注意 EOF 加了单引号 'EOF', 这样 $host、$remote_addr 等 nginx 变量不会被 shell 展开
    sudo tee /etc/nginx/sites-available/aui-components-doc > /dev/null <<'EOF'
server {
    listen 80;

    server_name _;

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
run_step "确保 swap (build 前置)"    step_6_ensure_swap
run_step "安装依赖"                  step_7_install_deps
run_step "启动服务"                  step_8_start_service
run_step "配置 pm2 开机自启"          step_9_pm2_autostart
run_step "安装 nginx"                step_10_install_nginx

printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%s所有步骤执行完成! 服务已部署成功。%s\n' "$GREEN" "$NC"
