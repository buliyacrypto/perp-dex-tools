#!/bin/bash

# 一键拉取并部署 perp-dex-tools 的脚本
# 适用于 Ubuntu 系统
# 使用方法: bash pull_and_deploy.sh <GITHUB_REPO_URL>
# 示例: bash pull_and_deploy.sh https://github.com/<your-username>/perp-dex-tools.git

# 设置错误处理
set -e

# Helper: read from /dev/tty to support interaction when stdin is piped
tty_read_prompt() {
    # usage: tty_read_prompt "prompt text" varname
    local prompt="$1"; shift
    local varname="$1"
    if [ -c /dev/tty ]; then
        # shellcheck disable=SC2162
        read -r -p "$prompt" "$varname" </dev/tty
    else
        error "无法打开终端(/dev/tty)。请在交互式终端运行脚本，或提供相应环境变量以跳过交互。"
    fi
}

tty_read() {
    # usage: tty_read varname
    local varname="$1"
    if [ -c /dev/tty ]; then
        read -r "$varname" </dev/tty
    else
        error "无法打开终端(/dev/tty)。请在交互式终端运行脚本，或提供相应环境变量以跳过交互。"
    fi
}

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# 日志函数
log() {
    printf "${GREEN}[INFO] $1${NC}\n"
}

error() {
    printf "${RED}[ERROR] $1${NC}\n"
    exit 1
}

# 检查是否提供了 GitHub 仓库 URL
if [ -z "$1" ]; then
    error "请提供 GitHub 仓库 URL，例如：bash $0 https://github.com/<your-username>/perp-dex-tools.git"
fi
REPO_URL="$1"

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    error "请以 root 权限运行此脚本 (使用 sudo)"
fi

# 更新系统并安装基本依赖
log "更新系统并安装基本依赖..."
apt-get update
apt-get install -y software-properties-common git curl

# 检查 Python 版本 (需要 3.10 - 3.12)
PYTHON_VERSION=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "0")
if [[ ! "$PYTHON_VERSION" =~ ^3\.(10|11|12) ]]; then
    log "Python 版本不符合要求（需要 3.10 - 3.12，当前版本为 $PYTHON_VERSION），安装 Python 3.10..."
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1
else
    log "Python 版本 $PYTHON_VERSION 符合要求"
fi

# 确保 pip、venv 和其他依赖安装
apt-get install -y python3-venv python3-pip

# 创建项目目录
PROJECT_DIR="perp-dex-tools"
log "创建项目目录 $PROJECT_DIR..."
mkdir -p "$PROJECT_DIR"
# 设置项目目录和日志目录为全用户可读写执行
log "设置项目目录全用户可操作..."
chmod -R 777 "$PROJECT_DIR"
cd "$PROJECT_DIR"

# 拉取 GitHub 仓库
log "拉取 GitHub 仓库 $REPO_URL..."
if [ -d ".git" ]; then
    log "仓库已存在，执行 git pull..."
    git pull origin main || error "拉取仓库失败"
else
    git clone "$REPO_URL" . || error "克隆仓库失败"
fi

# 列出远程分支并允许用户选择要切换到的分支（默认 main -> master -> 第一个远程分支）
log "获取远程分支信息..."
git fetch --all --prune || log "警告：git fetch 失败，继续使用本地分支信息"

# 获取远端分支列表（去掉 origin/ 前缀），并去重排序
mapfile -t REMOTE_BRANCHES < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's@^origin/@@' | sort -u)

if [ ${#REMOTE_BRANCHES[@]} -eq 0 ]; then
    log "未发现远程分支，跳过分支选择"
else
    # 决定默认分支
    DEFAULT_BRANCH=""
    for b in "${REMOTE_BRANCHES[@]}"; do
        if [ "$b" = "main" ]; then
            DEFAULT_BRANCH="main"
            break
        fi
    done
    if [ -z "$DEFAULT_BRANCH" ]; then
        for b in "${REMOTE_BRANCHES[@]}"; do
            if [ "$b" = "master" ]; then
                DEFAULT_BRANCH="master"
                break
            fi
        done
    fi
    if [ -z "$DEFAULT_BRANCH" ]; then
        DEFAULT_BRANCH="${REMOTE_BRANCHES[0]}"
    fi

    # 如果环境变量 BRANCH 给定，则使用之（用于非交互 CI 场景）。但只允许远程已存在的分支。
    if [ -n "$BRANCH" ]; then
        if printf '%s\n' "${REMOTE_BRANCHES[@]}" | grep -xq "$BRANCH"; then
            SELECTED_BRANCH="$BRANCH"
            log "使用环境变量 BRANCH=$SELECTED_BRANCH"
        else
            error "环境变量 BRANCH=$BRANCH 指定的分支在远程 origin 中不存在"
        fi
    else
        echo "可选远程分支列表："
        i=1
        for b in "${REMOTE_BRANCHES[@]}"; do
            printf "  %2d) %s\n" "$i" "$b"
            i=$((i+1))
        done
        echo
    tty_read_prompt "请输入要切换的分支序号或名称（默认: $DEFAULT_BRANCH）：" BR_INPUT
        if [ -z "$BR_INPUT" ]; then
            SELECTED_BRANCH="$DEFAULT_BRANCH"
        else
            # 如果输入是数字，按序号选分支；否则按名称直接使用（但需在远程列表中）
            if [[ "$BR_INPUT" =~ ^[0-9]+$ ]]; then
                IDX=$((BR_INPUT-1))
                if [ $IDX -ge 0 ] && [ $IDX -lt ${#REMOTE_BRANCHES[@]} ]; then
                    SELECTED_BRANCH="${REMOTE_BRANCHES[$IDX]}"
                else
                    error "无效的分支序号"
                fi
            else
                # 验证名字在远程分支列表中
                if printf '%s\n' "${REMOTE_BRANCHES[@]}" | grep -xq "$BR_INPUT"; then
                    SELECTED_BRANCH="$BR_INPUT"
                else
                    error "指定的分支 '$BR_INPUT' 在远程 origin 中不存在"
                fi
            fi
        fi
    fi

    log "切换到远程存在的分支: $SELECTED_BRANCH"
    # 只允许切换到远程已存在的分支；若本地不存在，则创建本地分支并跟踪远程分支
    if git show-ref --verify --quiet "refs/heads/$SELECTED_BRANCH"; then
        git checkout "$SELECTED_BRANCH" || error "切换到分支 $SELECTED_BRANCH 失败"
    else
        # 远程必定存在（前面已校验），直接创建跟踪分支
        git checkout -b "$SELECTED_BRANCH" --track "origin/$SELECTED_BRANCH" || error "创建并切换到跟踪远程分支 $SELECTED_BRANCH 失败"
    fi
fi

# 创建并激活虚拟环境
log "创建并激活虚拟环境..."
python3 -m venv env
source env/bin/activate

# 安装基本依赖
log "安装基本依赖..."
pip install --upgrade pip
pip install -r requirements.txt

# 询问是否安装 grvt 专用依赖（默认安装）
log "是否安装 grvt 专用依赖？(Y/n，默认 Y)"
tty_read INSTALL_GRVT
if [[ -z "$INSTALL_GRVT" || "$INSTALL_GRVT" =~ ^[Yy]$ ]]; then
    log "安装 grvt 专用依赖..."
    pip install grvt-pysdk
else
    log "跳过安装 grvt 专用依赖"
fi

# 创建 .env 文件模板（如果不存在）
if [ ! -f ".env" ]; then
    log "创建 .env 文件模板..."
    cat > .env << EOL
# 通用配置
ACCOUNT_NAME=MAIN

# Telegram 配置 (可选)
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# EdgeX 配置
EDGEX_ACCOUNT_ID=
EDGEX_STARK_PRIVATE_KEY=
EDGEX_BASE_URL=https://pro.edgex.exchange
EDGEX_WS_URL=wss://quote.edgex.exchange

# Backpack 配置
BACKPACK_PUBLIC_KEY=
BACKPACK_SECRET_KEY=

# Paradex 配置
PARADEX_L1_ADDRESS=
PARADEX_L2_PRIVATE_KEY=

# Aster 配置
ASTER_API_KEY=
ASTER_SECRET_KEY=

# Lighter 配置
API_KEY_PRIVATE_KEY=
LIGHTER_ACCOUNT_INDEX=
LIGHTER_API_KEY_INDEX=

# GRVT 配置
GRVT_TRADING_ACCOUNT_ID=
GRVT_PRIVATE_KEY=
GRVT_API_KEY=

# Extended 配置
EXTENDED_API_KEY=
EXTENDED_STARK_KEY_PUBLIC=
EXTENDED_STARK_KEY_PRIVATE=
EXTENDED_VAULT=
EOL
    log ".env 文件模板已创建，请根据需要编辑"
else
    log ".env 文件已存在，跳过创建"
fi

# 询问是否编辑 .env 文件（默认编辑）
log "是否编辑 .env 文件？(Y/n，默认 Y)"
tty_read EDIT_ENV
if [[ -z "$EDIT_ENV" || "$EDIT_ENV" =~ ^[Yy]$ ]]; then
    log "请选择编辑器：1) nano  2) micro (默认 nano，按 Enter 选择 nano)"
    tty_read EDITOR_CHOICE
    if [[ -z "$EDITOR_CHOICE" || "$EDITOR_CHOICE" = "1" ]]; then
        EDITOR="nano"
        # 检查 nano 是否安装
        if ! command -v nano &> /dev/null; then
            log "nano 未安装，正在安装..."
            apt-get install -y nano
        fi
    elif [[ "$EDITOR_CHOICE" = "2" ]]; then
        EDITOR="micro"
        # 检查 micro 是否安装
        if ! command -v micro &> /dev/null; then
            log "micro 未安装，正在安装..."
            apt install -y micro
        fi
    else
        error "无效选择，请选择 1 (nano) 或 2 (micro)"
    fi
    log "使用 $EDITOR 编辑 .env 文件..."
    $EDITOR ".env"
else
    log "跳过编辑 .env 文件"
fi

# 提示用户如何完成配置和启动
log "部署完成！"
log "==============================="
log "请按照以下步骤启动交易机器人："
log "1.切换到项目目录：cd $PROJECT_DIR"
log "2. 如果未编辑 .env 文件，可使用：nano .env 或 micro .env"
log "3. 激活虚拟环境：source env/bin/activate"
log "4. 运行机器人，例如：python runbot.py --exchange edgex --ticker ETH --quantity 0.1 --take-profit 0.02 --max-orders 40 --wait-time 450"
log "5. 如需 Paradex 交易所，请自行安装para_requirements.txt依赖并激活 para_env 虚拟环境"
log "6. 要更新代码，重新运行此脚本：bash pull_and_deploy.sh $REPO_URL"
log "==============================="