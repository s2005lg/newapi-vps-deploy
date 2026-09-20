# NewAPI on DMIT VPS

面向 Ubuntu 24.04 LTS 的单机部署脚本，部署以下组件：

- NewAPI
- PostgreSQL 16
- Redis 7
- Caddy（提供域名时启用）
- UFW 与 Fail2ban
- 每晚 PostgreSQL 和 NewAPI 数据备份

## 当前无域名的部署方式

1. 在 GitHub 中打开 `install.sh`，点击 **Raw** 后全选并复制。
2. 在 iPad 的 SSH 客户端中连接 VPS，然后运行：

   ```bash
   nano /root/install-newapi.sh
   ```

3. 粘贴脚本，按 `Ctrl+O`、回车保存，再按 `Ctrl+X` 退出。
4. 执行：

   ```bash
   chmod 700 /root/install-newapi.sh
   bash /root/install-newapi.sh
   ```

脚本在无域名模式下只把 NewAPI 绑定到 VPS 的 `127.0.0.1:3000`，不会把未加密后台暴露到公网。

在支持端口转发的 SSH 客户端中创建本地转发：

```text
本地端口：3000
远程主机：127.0.0.1
远程端口：3000
```

然后访问 `http://127.0.0.1:3000` 完成 NewAPI 初始管理员设置。

## 有域名后的部署方式

先将域名的 A 记录指向 VPS 公网 IP，确认解析生效后重新运行：

```bash
DOMAIN=api.example.com bash /root/install-newapi.sh
```

脚本会启用 Caddy，并开放 80/443，由 Caddy自动申请 HTTPS 证书。把示例域名替换为实际域名。

## 常用检查命令

```bash
cd /opt/newapi
docker compose ps
docker compose logs --tail=100 new-api
systemctl status newapi-backup.timer --no-pager
ufw status verbose
```

## 更新

```bash
cd /opt/newapi
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
```

更新前建议先手动备份：

```bash
/usr/local/sbin/newapi-backup
```

## 安全说明

- PostgreSQL 与 Redis 没有宿主机端口映射，不能从公网直接访问。
- 数据库、Redis 和会话密钥在首次执行时随机生成，保存在 `/opt/newapi/.env`，权限为 `600`。
- 重复执行脚本会保留已有密钥，不会导致数据库因密码变化而失联。
- 无域名时不要把 3000 端口开放到公网。
- 脚本不会自动关闭 root 密码登录，以免在只有密码认证时把管理员锁在服务器外。配置好 SSH 公钥并验证后，应再关闭 root 密码登录。
- 使用临时 root 密码完成安装后，请执行 `passwd` 更换密码。

## 本地测试

```bash
bash tests/test_install.sh
```

该测试会验证脚本语法、密钥格式、`.env` 权限、无域名模式的本地绑定、数据库端口隔离，以及域名模式的 HTTPS 配置。

