# my-devops

> 个人 DevOps 工具与脚本集合，涵盖日常运维、CI/CD 辅助、环境配置等场景。

## 功能说明

本项目主要用于沉淀个人/团队在 DevOps 实践中常用的 Shell 脚本与配置文件，包括但不限于：

- 🚀 一键部署与环境初始化脚本
- 🛠️ 服务器日常运维辅助工具
- 📦 CI/CD 流水线辅助脚本
- ⚙️ 各类服务配置模板（Nginx、Docker、systemd 等）
- 🔒 敏感信息处理与安全配置示例

> 注：具体脚本会持续补充，目录结构会随之演进。

## 安装与使用

### 环境要求

- Linux / macOS（推荐）
- Bash 4.0+ 或 Zsh
- 常用工具：`git`、`curl`、`docker`（按脚本需要）

### 克隆仓库

```bash
git clone <repository-url> my-devops
cd my-devops
```

### 使用脚本

通常脚本位于 `scripts/` 目录下，赋予执行权限后即可运行：

```bash
chmod +x scripts/<script-name>.sh
./scripts/<script-name>.sh
```

> ⚠️ 运行前请先阅读脚本顶部的注释说明，确认参数与影响范围，避免误操作。

### 配置文件

配置模板放在 `configs/` 目录下，复制后按需修改：

```bash
cp configs/<template>.conf.example configs/<template>.conf
# 编辑其中的变量，尤其是密钥、域名等敏感信息
```

## 项目结构

```
my-devops/
├── scripts/          # Shell 脚本（部署、运维、CI/CD 辅助等）
├── configs/          # 配置文件模板（.example 为示例，实际配置不入库）
├── docs/             # 说明文档
├── .gitignore
└── README.md
```

## License

本项目采用 [MIT License](LICENSE) 开源协议，可自由使用与修改。

> 若后续需要更换协议，请同步更新本节及 LICENSE 文件。
