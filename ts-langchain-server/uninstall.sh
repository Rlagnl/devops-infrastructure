#!/usr/bin/env bash
# ts-langchain-server 卸载脚本: 完整删除该子项目在服务器上的专属资源
# 与 bootstrap.sh 对应, 执行删除方向的操作, 且同样保持幂等(可重复执行, 已删除则跳过)
#
# 会删除(ts-langchain-server 专属):
#   1. Docker 容器:   ts-langchain-server / ts-langchain-postgres / ts-langchain-redis
#   2. Docker 数据卷: ts-langchain-server_pgdata / ts-langchain-server_redisdata (数据不可恢复!)
#   3. Docker 镜像:   ghcr.io/<user>/ts-langchain-server (latest 与 sha-* 全部)
#   4. nginx 站点:    /etc/nginx/sites-{available,enabled}/ts-langchain-server (监听 8081)
#   5. 项目目录:      /opt/ts-langchain-server (docker-compose.yml + CI 写入的 .env)
#
# 不会删除(共享资源, 其他子项目仍在使用):
#   - Docker 本体 / daemon.json 镜像加速器
#   - Docker 网络 app-network (langgraph-aui-app 也挂载)
#   - Self-hosted Runner (/home/github-runner/actions-runner + actions.runner.* 服务 + github-runner 用户)
#   - nginx 本体
#   - ghcr.io 登录凭证 (不执行 docker logout)
#
# 用法:
#   sudo ./uninstall.sh        # 交互式确认后删除
#   sudo ./uninstall.sh -y     # 跳过确认直接删除
#   sudo ./uninstall.sh -h     # 显示帮助

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
# 脚本包含 docker/rm -rf/nginx/systemctl 等操作, 必须以 root 身份运行
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

# ============ 参数解析 ============
SKIP_CONFIRM="false"

usage() {
    cat >&2 <<EOF
用法: sudo $0 [-y]
  -y  跳过交互确认, 直接执行删除
  -h  显示帮助
EOF
    exit 1
}

while getopts "yh" opt; do
    case "$opt" in
        y) SKIP_CONFIRM="true" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# ============ 删除前确认 ============
# 数据卷删除不可恢复, 默认要求交互确认, -y 可跳过(便于脚本化/重复执行)
confirm_deletion() {
    printf '%s========================================%s\n' "$YELLOW" "$NC"
    printf '%s将删除以下 ts-langchain-server 专属资源:%s\n' "$YELLOW" "$NC"
    printf '  - Docker 容器:   ts-langchain-server / ts-langchain-postgres / ts-langchain-redis\n'
    printf '  - Docker 数据卷: ts-langchain-server_pgdata / ts-langchain-server_redisdata (数据不可恢复!)\n'
    printf '  - Docker 镜像:   ghcr.io/*/ts-langchain-server (latest 与 sha-* 全部)\n'
    printf '  - nginx 站点:    /etc/nginx/sites-{available,enabled}/ts-langchain-server (8081)\n'
    printf '  - 项目目录:      /opt/ts-langchain-server\n'
    printf '\n%s以下共享资源不会被删除:%s\n' "$YELLOW" "$NC"
    printf '  Docker / app-network / nginx / Self-hosted Runner / ghcr.io 登录凭证\n'
    printf '%s========================================%s\n' "$YELLOW" "$NC"

    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        echo "已通过 -y 跳过确认, 直接执行删除"
        return 0
    fi

    local confirm
    read -r -p "确认删除? 输入 yes 继续: " confirm </dev/tty || true
    if [[ "$confirm" != "yes" ]]; then
        echo "已取消, 未做任何修改"
        exit 0
    fi
}

# ============ 1. 删除容器与数据卷 ============
step_1_remove_containers_and_volumes() {
    # 优先走 compose 文件清理(容器 + 命名卷一起删, external 网络 app-network 不受影响)
    if [[ -f /opt/ts-langchain-server/docker-compose.yml ]]; then
        cd /opt/ts-langchain-server
        docker compose down -v --remove-orphans
        echo "已通过 docker compose down -v 清理容器与数据卷"
    else
        echo "docker-compose.yml 不存在, 跳过 compose down"
    fi

    # 兜底: 目录可能已被手动删除但容器/卷残留, 按名称精确清理
    local c
    for c in ts-langchain-server ts-langchain-postgres ts-langchain-redis; do
        if docker ps -aq -f "name=^${c}$" | grep -q .; then
            docker rm -f "$c"
            echo "已删除残留容器: $c"
        else
            echo "容器不存在, 跳过: $c"
        fi
    done

    local v
    for v in ts-langchain-server_pgdata ts-langchain-server_redisdata; do
        if docker volume ls -q -f "name=^${v}$" | grep -q .; then
            docker volume rm "$v"
            echo "已删除残留数据卷: $v"
        else
            echo "数据卷不存在, 跳过: $v"
        fi
    done
}

# ============ 2. 删除 Docker 镜像 ============
step_2_remove_images() {
    # 按 repository 名称精确匹配(以 /ts-langchain-server 结尾), 避免误删其他项目镜像
    # latest 与 sha-* 标签共享同一镜像 ID 时, sort -u 去重后统一删除
    local ids
    ids="$(docker images --format '{{.ID}} {{.Repository}}' \
        | awk '$2 ~ /\/ts-langchain-server$/ {print $1}' \
        | sort -u)"

    if [[ -z "$ids" ]]; then
        echo "未找到 ts-langchain-server 镜像, 跳过"
        return 0
    fi

    echo "将删除以下镜像 ID:"
    echo "$ids"
    # shellcheck disable=SC2086  # ids 为多行镜像 ID, 需按空白分词逐个传入
    docker rmi -f $ids
    echo "镜像删除完成"
}

# ============ 3. 删除 nginx 站点 ============
step_3_remove_nginx() {
    rm -f /etc/nginx/sites-enabled/ts-langchain-server
    rm -f /etc/nginx/sites-available/ts-langchain-server
    echo "已删除 nginx 站点文件与软链"

    # 若本机还装有 nginx, 校验并重载; 失败仅告警不中断(可能该 VPS 已无其他站点)
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t; then
            systemctl reload nginx
            echo "nginx 已重载"
        else
            echo "警告: nginx -t 校验失败, 请检查剩余站点配置"
        fi
    fi
}

# ============ 4. 删除项目目录 ============
step_4_remove_project_dir() {
    if [[ -d /opt/ts-langchain-server ]]; then
        rm -rf /opt/ts-langchain-server
        echo "已删除目录: /opt/ts-langchain-server"
    else
        echo "目录不存在, 跳过: /opt/ts-langchain-server"
    fi
}

# ============ 5. 验证清理结果 ============
step_5_verify() {
    echo "=== 清理结果验证 ==="

    local remain=0
    if docker ps -aq -f name=ts-langchain 2>/dev/null | grep -q .; then
        echo "[残留] 仍有 ts-langchain 相关容器"
        remain=1
    else
        echo "[OK] 容器已清空"
    fi

    if docker volume ls -q 2>/dev/null | grep -q ts-langchain; then
        echo "[残留] 仍有 ts-langchain 相关数据卷"
        remain=1
    else
        echo "[OK] 数据卷已清空"
    fi

    if docker images --format '{{.Repository}}' 2>/dev/null | grep -q '/ts-langchain-server$'; then
        echo "[残留] 仍有 ts-langchain-server 镜像"
        remain=1
    else
        echo "[OK] 镜像已清空"
    fi

    if [[ -e /etc/nginx/sites-enabled/ts-langchain-server ]]; then
        echo "[残留] nginx 站点软链仍存在"
        remain=1
    else
        echo "[OK] nginx 站点已移除"
    fi

    if [[ -d /opt/ts-langchain-server ]]; then
        echo "[残留] 项目目录仍存在"
        remain=1
    else
        echo "[OK] 项目目录已删除"
    fi

    # 共享网络应保留, 仅提示状态
    echo ""
    echo "共享网络 app-network 状态(应保留):"
    docker network ls --format '{{.Name}}' 2>/dev/null | grep app-network || echo "  app-network 不存在"

    if [[ "$remain" -ne 0 ]]; then
        echo ""
        echo "存在残留项, 请检查上述 [残留] 提示"
        return 1
    fi
    echo ""
    echo "ts-langchain-server 专属资源已全部清理完毕"
}

# ============ 执行 ============
confirm_deletion
run_step "删除容器与数据卷"  step_1_remove_containers_and_volumes
run_step "删除 Docker 镜像"    step_2_remove_images
run_step "删除 nginx 站点"     step_3_remove_nginx
run_step "删除项目目录"        step_4_remove_project_dir
run_step "验证清理结果"        step_5_verify

printf '\n%s========================================%s\n' "$GREEN" "$NC"
printf '%sts-langchain-server 卸载完成!%s\n' "$GREEN" "$NC"
printf '共享资源(Docker / app-network / nginx / Runner / ghcr 凭证)已保留。\n'
printf '如需彻底移除 GitHub 侧配置, 请另行删除: Secrets/Variables、ghcr package、.bak workflow 文件。\n'
printf '%s========================================%s\n' "$GREEN" "$NC"
