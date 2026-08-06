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
    cd /root/workspace
    # 凭证优先使用环境变量; 若未设置则在此交互式输入(token 用 -s 静默输入, 不回显)
    # 注意: read 从 stdin(终端键盘)读取, 不受 run_step 里 tee 重定向影响
    # 先初始化为空, 避免下方 while 在 set -u 下引用未定义变量报错
    GIT_USER="${GIT_USER:-}"
    GIT_TOKEN="${GIT_TOKEN:-}"
    if [[ -z "$GIT_USER" ]]; then
        while [[ -z "$GIT_USER" ]]; do
            read -r -p "请输入 GitHub 用户名: " GIT_USER
        done
    fi
    if [[ -z "$GIT_TOKEN" ]]; then
        while [[ -z "$GIT_TOKEN" ]]; do
            # -s: 静默模式, 输入不回显, 防止 token 明文出现在屏幕/日志中
            read -rs -p "请输入 GitHub Personal Access Token (输入不可见): " GIT_TOKEN
            echo  # -s 不会在回车后换行, 这里补一个换行
        done
    fi
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
