# RenewX 管理脚本

## 功能

- 部署、启动、停止、重启和更新 RenewX 容器，更新失败时自动回滚。
- 生成安全的 `Config.xml`，编辑配置、查看日志和显示访问地址。
- 安装 Docker/Caddy、配置 Caddy 反向代理及在线更新管理脚本。
- 一致性备份 `/opt/renewx`，安全卸载 RenewX 并保留共享的 Docker/Caddy 环境。

## 下载

```bash
curl -fLo renewx.sh https://raw.githubusercontent.com/Leovikii/sh/main/renewx/renewx.sh
```

中国大陆网络可使用 CDN 加速：

```bash
curl -fLo renewx.sh https://cdn.jsdelivr.net/gh/Leovikii/sh@main/renewx/renewx.sh
```

## 运行

```bash
chmod +x renewx.sh && sudo ./renewx.sh
```
