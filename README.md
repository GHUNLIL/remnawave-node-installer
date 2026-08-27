# Remnawave Node 一键安装脚本

在一台全新的 Debian/Ubuntu VPS 上自动安装 Docker、部署官方 `remnawave/node` 容器，并通过 Remnawave 面板生成的 `SECRET_KEY` 完成节点对接。

脚本默认使用 `2222/TCP` 作为 Node Port。密钥会隐藏输入，只保存在服务器的 `/opt/remnanode/.env`，权限为 `600`，不会上传到 GitHub，也不会出现在 Compose 文件或终端回显中。

## 一键安装

先在 Remnawave 面板中创建节点：

1. 打开“节点管理”并创建新节点。
2. Node Port 填写 `2222`。
3. 复制面板生成的 `SECRET_KEY`。
4. 为节点选择配置文件与入站并提交。
5. 登录新服务器的 `root`，粘贴下面这一行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/remnawave-node-installer/main/install.sh)
```

脚本提示时粘贴 `SECRET_KEY` 并按回车。输入过程不会显示任何字符，这是正常现象。

## 支持范围

- Debian 12、Debian 13
- Ubuntu 22.04、Ubuntu 24.04
- `amd64` 与 Docker 官方仓库支持的其他架构
- Docker Compose v2
- 重复运行：更新镜像并重新创建容器

## 使用其他 Node Port

必须保证脚本端口和 Remnawave 面板中的 Node Port 完全一致：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/remnawave-node-installer/main/install.sh) --port 3000
```

## 安装结果

```text
/opt/remnanode/
├── .env                # SECRET_KEY，root:root 600
└── docker-compose.yml  # 容器配置，root:root 600
```

容器使用官方镜像 `remnawave/node:latest`、host 网络、`NET_ADMIN` capability 和 `restart: always`。

常用命令：

```bash
# 状态
docker compose --env-file /opt/remnanode/.env -f /opt/remnanode/docker-compose.yml ps

# 日志
docker logs -f --tail 100 remnanode

# 更新
bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/remnawave-node-installer/main/install.sh)
```

## 防火墙与安全组

脚本不会擅自修改云厂商安全组或系统防火墙。至少需要允许 Remnawave 主控访问 Node Port（默认 `2222/TCP`），并放行配置文件中各入站实际使用的 TCP/UDP 端口。

更安全的做法是只允许主控公网 IP 访问 Node Port，而不是向全网开放。

## 安全设计

- 仅允许 root 执行真实安装。
- `SECRET_KEY` 使用隐藏交互输入。
- 校验密钥格式，不接受换行或 shell 特殊字符。
- 密钥与配置文件权限均为 `600`，目录权限为 `700`。
- 不覆盖非本脚本创建的 Remnawave 配置或同名容器。
- Docker 使用 Docker 官方 APT 仓库安装。
- Docker 日志自动轮转，避免占满磁盘。

不要把 `SECRET_KEY` 写进命令行、截图、Issue 或聊天记录。如果密钥曾公开，请在 Remnawave 面板重新生成。

## 来源

- [Remnawave Node 官方仓库](https://github.com/remnawave/node)
- [Docker Engine 官方安装文档](https://docs.docker.com/engine/install/)

## License

[MIT](LICENSE)
