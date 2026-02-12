# SK5 代理链 - VLESS + Reality + Kookeey 住宅出口

## 架构总览

```
手机 (192.168.66.105)
  │  无需任何设置，连 Wi-Fi 即走代理
  ▼
OpenWrt 路由器 (192.168.66.1) - N100 软路由
  │  sing-box tproxy 透明代理
  │  Fake-IP DNS (即时响应)
  │  iptables 劫持 DNS + 拦截 QUIC
  ▼
VPS (139.180.136.97:443) - Vultr 新加坡
  │  VLESS + Reality 协议 (伪装成正常 HTTPS)
  │  两种模式可切换:
  │    - Xray (Vision + 5 SNI 轮换) → 注册用
  │    - sing-box (h2mux 多路复用) → 刷视频用
  ▼
Kookeey 美国住宅代理 (gate-sea.kookeey.info:1000)
  │  SOCKS5 协议转发
  ▼
目标网站看到的是: 美国 T-Mobile 住宅 IP
  proxy=false, hosting=false
```

## 两种模式说明

| | Vision 模式 (注册) | Mux 模式 (刷视频) |
|---|---|---|
| VPS 程序 | Xray-core | sing-box |
| 防指纹 | Vision flow 防 TLS-in-TLS 检测 | 无 Vision |
| SNI 伪装 | 5 个域名随机轮换 | 单 SNI (speedtest.net) |
| 连接方式 | 每个请求独立 TCP 连接 | h2mux 4 连接复用所有流量 |
| 适用场景 | 微信注册、敏感操作 | 日常刷视频、浏览网页 |
| 切换命令 | `proxy-switch vision` | `proxy-switch mux` |

**为什么不能同时开？** Vision 和 Mux 是协议层面的根本冲突。Vision 逐个处理 TLS 记录做填充，Mux 把多个流混在一起打包，两者互相破坏。

---

## 一、VPS 部署 (Vultr 新加坡 139.180.136.97)

### 1.1 安装 Xray-core

```bash
# 官方安装脚本
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

安装完成后 Xray 在 `/usr/local/bin/xray`。

### 1.2 配置 Xray (Vision 模式)

将 `vps/xray/config.json` 放到 `/etc/xray/config.json`。

**配置说明：**

```
inbounds: 监听 443 端口
  ├── 协议: VLESS (轻量级，无额外加密开销)
  ├── flow: xtls-rprx-vision (防 TLS-in-TLS 指纹)
  ├── security: reality (伪装成访问真实网站)
  ├── serverNames: 5个 SNI 轮换
  │   ├── www.speedtest.net   (科技服务，长连接多)
  │   ├── www.homedepot.com   (大型零售，流量合规)
  │   ├── www.nvidia.com      (科技服务)
  │   ├── www.mayoclinic.org  (医疗，高信誉)
  │   └── www.ucla.edu        (学术，高信誉)
  ├── tcpFastOpen: true (握手时就携带数据，省一个 RTT)
  ├── tcpKeepAliveInterval: 30s (保持长连接不断)
  └── sniffing: 开启流量嗅探 (识别 HTTP/TLS/QUIC)

outbounds: 转发到 Kookeey 住宅代理
  └── SOCKS5 → gate-sea.kookeey.info:1000
      ├── user: 6458952-bcc9e8fa
      └── pass: c51094ec-US-32987325-2m
```

### 1.3 安装 sing-box (Mux 模式)

```bash
# 下载最新版
curl -Lo /usr/local/bin/sing-box https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-amd64.tar.gz
# 或者用官方安装脚本:
bash -c "$(curl -fsSL https://sing-box.app/deb-install.sh)"
```

将 `vps/sing-box/config.json` 放到 `/etc/sing-box/config.json`。

**与 Xray 配置的区别：**
- 无 `flow` (不使用 Vision)
- 多了 `multiplex: {"enabled": true}` (服务端开启 mux 支持)
- 单 SNI (www.speedtest.net)

### 1.4 安装 systemd 服务

```bash
# Xray 服务
cp vps/systemd/xray.service /etc/systemd/system/
# sing-box 服务
cp vps/systemd/sing-box.service /etc/systemd/system/
# 重载
systemctl daemon-reload
```

**注意：同一时间只能运行一个，因为都监听 443 端口。**

```bash
# 启用 Vision 模式 (默认)
systemctl enable xray
systemctl start xray

# 或启用 Mux 模式
systemctl enable sing-box
systemctl start sing-box
```

### 1.5 TCP 内核优化

```bash
cp vps/sysctl/99-keepalive.conf /etc/sysctl.d/
sysctl -p /etc/sysctl.d/99-keepalive.conf
```

**参数说明：**

| 参数 | 值 | 作用 |
|------|-----|------|
| tcp_keepalive_time | 30s | 空闲 30 秒后发探测包 (默认 7200s 太久) |
| tcp_keepalive_intvl | 10s | 每 10 秒重试一次 |
| tcp_keepalive_probes | 6 | 连续 6 次无响应才断开 |
| tcp_fastopen | 3 | 客户端+服务端都启用 TFO |

**为什么调这个？** 微信等 APP 会维持后台长连接。默认 2 小时才探测一次，运营商早就把连接掐了。30 秒探测能保住连接不被中间设备回收。

### 1.6 MTU 优化

```bash
# 查看当前 MTU
ip link show eth0

# 设置为 1400
ip link set eth0 mtu 1400

# 持久化 (Debian/Ubuntu)
echo 'post-up ip link set eth0 mtu 1400' >> /etc/network/interfaces.d/mtu
```

**为什么 1400？** 默认 MTU 是 1500。加上 VPN/代理的封装头后可能超过 1500 导致分片。微信对分片很敏感，会判定网络不稳定。降到 1400 留出足够余量。

### 1.7 防火墙放行

```bash
ufw allow 443/tcp
```

### 1.8 验证出口 IP

```bash
bash /usr/local/bin/check-ip.sh
```

正确输出应该是：
- country: United States
- isp: T-Mobile USA (或其他美国住宅运营商)
- proxy: false
- hosting: false

---

## 二、路由器部署 (OpenWrt N100 192.168.66.1)

### 2.1 安装 sing-box

```bash
# OpenWrt 上安装
opkg update
opkg install sing-box

# 或手动下载二进制
curl -Lo /usr/local/bin/sing-box [sing-box下载链接]
chmod +x /usr/local/bin/sing-box
```

### 2.2 配置文件

将两个配置文件放到路由器：

```bash
# Vision 模式客户端配置
scp router/sing-box/config-vision.json root@192.168.66.1:/etc/sing-box/config-vision.json

# Mux 模式客户端配置
scp router/sing-box/config-mux.json root@192.168.66.1:/etc/sing-box/config-mux.json

# 默认使用 mux 模式
cp /etc/sing-box/config-mux.json /etc/sing-box/config.json
```

**配置详解 (以 Mux 模式为例)：**

```
dns:
  ├── proxy-dns: DoH 1.1.1.1 (通过代理解析，防泄露)
  ├── fakeip-dns: Fake-IP 模式
  │   ├── inet4_range: 198.18.0.0/15 (虚拟 IPv4 段)
  │   └── inet6_range: fc00::/18 (虚拟 IPv6 段)
  └── local-dns: 本地解析 (仅用于解析代理服务器自身域名)

  DNS 规则:
  ├── outbound=any → local-dns (代理服务器的 DNS 走本地)
  └── A/AAAA 查询 → fakeip-dns (其他所有域名返回假 IP)

inbounds:
  └── tproxy 监听 12345 端口
      ├── sniff: true (嗅探实际域名)
      └── sniff_override_destination: true (用嗅探到的域名替换假 IP)

outbounds:
  ├── vless-out: 连接 VPS
  │   ├── server: 139.180.136.97:443
  │   ├── Reality + uTLS chrome 指纹
  │   └── multiplex: h2mux, 4 连接, 最少 4 流 (仅 Mux 模式)
  ├── direct: 直连 (局域网流量)
  └── dns-out: DNS 流量出口

route:
  ├── port 53 → dns-out (DNS 劫持)
  ├── 198.18.0.0/15 → vless-out (Fake-IP 流量走代理)
  ├── 192.168/10/172.16/127 → direct (局域网直连)
  └── 其他所有 → vless-out (默认走代理)
```

### 2.3 什么是 Fake-IP？为什么用它？

**正常 DNS 流程（慢）：**
```
手机请求 google.com
  → 路由器转发 DNS 到代理
  → 代理转发到远程 DNS (1.1.1.1)
  → 等待解析结果返回 (200-500ms)
  → 手机拿到 IP，开始连接
```

**Fake-IP 流程（快）：**
```
手机请求 google.com
  → 路由器立即返回假 IP: 198.18.0.5 (0ms)
  → 手机立即开始连接 198.18.0.5
  → 路由器拦截连接，嗅探出实际域名 google.com
  → 通过代理连接真正的 google.com
  → 同时后台异步完成真实 DNS 解析
```

**效果：** 设备感觉 DNS 瞬间完成，网页打开速度明显提升。

### 2.4 配置 iptables 规则

将 `router/scripts/rc.local` 放到 `/etc/rc.local`：

```bash
scp router/scripts/rc.local root@192.168.66.1:/etc/rc.local
ssh root@192.168.66.1 "chmod +x /etc/rc.local"
```

**iptables 规则详解：**

```bash
# 1. 创建 TPROXY 路由 (让标记的包走本地)
ip rule add fwmark 1 table 100
ip route add local 0.0.0.0/0 dev lo table 100

# 2. 拦截 QUIC (UDP 443)
iptables -t mangle -A SINGBOX -p udp --dport 443 -j DROP
# 为什么？微信内置浏览器优先用 QUIC，但住宅代理对 UDP 极差
# 拦截后强制走 TCP，加载速度反而更快

# 3. DNS 劫持 (端口 53)
iptables -t mangle -A SINGBOX -p udp --dport 53 -j TPROXY ...
# 为什么？防止手机用自己的 DNS (如 8.8.8.8)
# 劫持后强制走 Fake-IP，防止 DNS 泄露暴露真实位置

# 4. 跳过局域网地址
iptables -t mangle -A SINGBOX -d 192.168.0.0/16 -j RETURN
# 访问路由器、局域网设备不走代理

# 5. 其他流量全部透明代理
iptables -t mangle -A SINGBOX -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
iptables -t mangle -A SINGBOX -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

# 6. 只对指定设备生效
iptables -t mangle -A PREROUTING -s 192.168.66.105 -j SINGBOX
# 只有 192.168.66.105 这台设备走代理，其他设备正常上网
```

### 2.5 安装切换脚本

```bash
scp router/scripts/proxy-switch.sh root@192.168.66.1:/usr/local/bin/proxy-switch
ssh root@192.168.66.1 "chmod +x /usr/local/bin/proxy-switch"
```

### 2.6 MTU 优化

```bash
ssh root@192.168.66.1 "ip link set br-lan mtu 1400"
```

---

## 三、日常使用

### 切换模式

在路由器上执行：

```bash
# 刷视频、日常浏览 (快)
proxy-switch mux

# 微信注册、敏感操作 (安全)
proxy-switch vision
```

脚本会自动：
1. 切换 VPS 服务 (Xray ↔ sing-box)
2. 切换路由器配置文件
3. 重启 sing-box

### 添加/移除代理设备

```bash
# 添加设备 (把 IP 换成你的设备)
iptables -t mangle -A PREROUTING -s 192.168.66.200 -j SINGBOX

# 移除设备
iptables -t mangle -D PREROUTING -s 192.168.66.105 -j SINGBOX
```

### 检查代理状态

```bash
# 路由器上查看 sing-box 是否运行
ps | grep sing-box

# 查看日志
tail -f /var/log/sing-box.log

# VPS 上查看连接
ss -tn | grep ':443'    # 路由器的连接
ss -tn | grep ':1000'   # 到 kookeey 的连接

# 验证出口 IP
ssh root@VPS_IP "bash /usr/local/bin/check-ip.sh"
```

---

## 四、完整优化清单

### 已实施的优化

| # | 优化项 | 位置 | 说明 |
|---|--------|------|------|
| 1 | VLESS + Reality | VPS | 流量伪装成正常 HTTPS 访问 |
| 2 | Vision flow | VPS (Xray) | 防止 TLS-in-TLS 被识别 |
| 3 | 5 SNI 轮换 | VPS (Xray) | 每次连接随机使用不同 SNI |
| 4 | h2mux 多路复用 | VPS (sing-box) | 4 连接承载所有流量 |
| 5 | uTLS chrome 指纹 | 路由器 | TLS 握手模拟 Chrome 浏览器 |
| 6 | Fake-IP DNS | 路由器 | DNS 零延迟响应 |
| 7 | DNS 劫持 | 路由器 iptables | 防止 DNS 泄露 |
| 8 | QUIC 拦截 | 路由器 iptables | 强制 TCP，避免 UDP 卡顿 |
| 9 | TCP FastOpen | VPS + 路由器 | 握手时携带数据，省一个 RTT |
| 10 | TCP KeepAlive | VPS 内核 | 30s 心跳保持长连接 |
| 11 | MTU 1400 | VPS + 路由器 | 防止数据包分片 |
| 12 | 流量嗅探 | VPS + 路由器 | 自动识别访问的域名 |
| 13 | Kookeey 住宅出口 | VPS 出站 | T-Mobile USA 住宅 IP |

### 无法实施的优化

| # | 优化项 | 原因 |
|---|--------|------|
| 1 | Vision + Mux 同时开 | 协议层面冲突，无法共存 |
| 2 | Mux 到 Kookeey | Kookeey 是标准 SOCKS5，不认识 mux 帧 |
| 3 | UDP over TCP | Xray SOCKS5 outbound 不支持 |

---

## 五、完整链路数据流

### Vision 模式 (注册)

```
手机发出 HTTPS 请求
  ↓
路由器 iptables TPROXY 拦截
  ↓
sing-box Fake-IP 立即响应 DNS
  ↓
sing-box 嗅探 TLS SNI → 获取真实域名
  ↓
VLESS + Reality + Vision 加密发送到 VPS
  (外部看到的是: 访问 www.speedtest.net 的正常 HTTPS)
  (SNI 从 5 个域名中随机选择)
  ↓
VPS Xray 解密，转发到 Kookeey SOCKS5
  ↓
Kookeey 用美国 T-Mobile 住宅 IP 访问目标网站
  ↓
目标网站看到: 来自美国住宅 IP 的正常访问
```

### Mux 模式 (刷视频)

```
手机同时打开多个网页/视频
  ↓
路由器 sing-box 将所有请求打包
  ↓
通过 4 条 h2mux 连接发送到 VPS
  (不需要为每个请求单独握手)
  ↓
VPS sing-box 拆包，分别转发到 Kookeey
  ↓
Kookeey 住宅 IP 访问各目标网站
```

---

## 六、文件部署路径速查

### VPS (139.180.136.97)

| 文件 | 部署路径 |
|------|----------|
| vps/xray/config.json | /etc/xray/config.json |
| vps/sing-box/config.json | /etc/sing-box/config.json |
| vps/systemd/xray.service | /etc/systemd/system/xray.service |
| vps/systemd/sing-box.service | /etc/systemd/system/sing-box.service |
| vps/sysctl/99-keepalive.conf | /etc/sysctl.d/99-keepalive.conf |
| vps/check-ip.sh | /usr/local/bin/check-ip.sh |

### 路由器 (192.168.66.1)

| 文件 | 部署路径 |
|------|----------|
| router/sing-box/config-vision.json | /etc/sing-box/config-vision.json |
| router/sing-box/config-mux.json | /etc/sing-box/config-mux.json |
| router/scripts/proxy-switch.sh | /usr/local/bin/proxy-switch |
| router/scripts/rc.local | /etc/rc.local |

---

## 七、连接信息

### VLESS 客户端参数 (手动配置用)

| 参数 | 值 |
|------|-----|
| 地址 | 139.180.136.97 |
| 端口 | 443 |
| UUID | 72ff96dd-0dda-4757-bca4-f8cd9b9e5ef6 |
| 加密 | none |
| 传输 | tcp |
| 安全 | reality |
| SNI | www.speedtest.net |
| Public Key | 9vgpvqYG9nxuK_40Fz3OX8PFNHFU3GCUyP8lYOZ0Y2I |
| Short ID | 9aea47c4c738b641 |
| Flow | xtls-rprx-vision (Vision模式) / 留空 (Mux模式) |
| 指纹 | chrome |

### Kookeey SOCKS5

| 参数 | 值 |
|------|-----|
| 地址 | gate-sea.kookeey.info |
| 端口 | 1000 |
| 用户名 | 6458952-bcc9e8fa |
| 密码 | c51094ec-US-32987325-2m |

---

## 八、故障排查

### 设备没网

```bash
# 1. 检查 sing-box 是否运行
ps | grep sing-box

# 2. 检查日志
tail -20 /var/log/sing-box.log

# 3. 检查 tproxy 路由是否存在
ip rule list | grep fwmark
ip route list table 100
# 如果 table 100 是空的，执行:
ip route add local 0.0.0.0/0 dev lo table 100

# 4. 检查 iptables 规则
iptables -t mangle -L PREROUTING -n
iptables -t mangle -L SINGBOX -n
```

### missing fakeip record 错误

手机 DNS 缓存了旧的 Fake-IP 地址。解决：
- 手机切一下飞行模式 (清除 DNS 缓存)
- 或等待旧缓存过期 (通常几分钟)

### too many open files 错误

```bash
# 增加文件描述符限制
ulimit -n 65535
# 然后重启 sing-box
```

### VPS 显示 flow mismatch

路由器和 VPS 的模式不匹配。确保两端一致：
- Vision 模式：两端都有 flow
- Mux 模式：两端都没有 flow

用 `proxy-switch` 脚本切换可以避免此问题。
