# 多节点 VMess 代理链 - 三服务器 + 多代理出口

## 架构总览

```
手机 / 设备 (VMess 客户端)
  │  选择任意一条 VMess 链接连接
  ▼
入口服务器 (三选一，同一时间只开一台)
  ├─ HK: 93.179.124.237:22620  ← 当前使用
  ├─ US: 138.128.193.157:22620  ← 已部署，已停止
  └─ SG: 45.77.248.60:22620    ← 已部署，已停止
  │
  │  VMess + TCP (无 TLS)
  │  三台服务器配置完全一致 (相同 UUID)
  │  可通过域名 v.app-ns.com 切换 (Cloudflare DNS)
  ▼
代理出口 (97 条线路)
  ├─ line-1 ~ line-46:  Oxylabs S5 住宅代理 (pr.oxylabs.io:7777)
  ├─ dc-47:              Oxylabs 数据中心代理 (dc.oxylabs.io:8000)
  └─ line-48 ~ line-97:  Kookeey gate-sea US 住宅代理 (gate-sea.kookeey.info:1000)
  │
  ▼
目标网站看到的是: 美国住宅 IP
```

## 服务器信息

| 服务器 | IP | 位置 | 系统 | 状态 |
|--------|-----|------|------|------|
| HK | 93.179.124.237 | 香港 | AlmaLinux 9 | 运行中 |
| US | 138.128.193.157 | 美国 | AlmaLinux 9 | 已停止 |
| SG | 45.77.248.60 | 新加坡 | Debian 12 | 已停止 |
| 路由器 | 192.168.66.1 | 本地 | OpenWrt (N100) | 备用 |

## 域名切换

域名 `v.app-ns.com` 通过 Cloudflare DNS 管理，TTL 60 秒。

切换服务器只需修改 DNS A 记录指向：
- 走香港: `v.app-ns.com` → `93.179.124.237`
- 走美国: `v.app-ns.com` → `138.128.193.157`
- 走新加坡: `v.app-ns.com` → `45.77.248.60`

客户端链接不用改，60 秒内自动切换。

---

## 一、VPS 部署步骤

以下以香港服务器为例，美国和新加坡步骤完全相同。

### 1.1 安装 Xray

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

### 1.2 关闭 BBR（重要）

BBR 在住宅代理链上会导致速度下降，必须切换为 cubic：

```bash
# 查看当前拥塞控制
sysctl net.ipv4.tcp_congestion_control

# 切换为 cubic
echo "net.ipv4.tcp_congestion_control = cubic" >> /etc/sysctl.conf
sysctl -p
```

### 1.3 部署 Xray 配置

配置文件路径: `/usr/local/etc/xray/config.json`

配置结构说明:

```json
{
  "log": {"loglevel": "warning"},
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4"]
  },
  "inbounds": [
    {
      "tag": "vmess-in",
      "port": 22620,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {"id": "UUID-1", "alterId": 0, "email": "line-1"},
          {"id": "UUID-2", "alterId": 0, "email": "line-2"},
          {"id": "UUID-97", "alterId": 0, "email": "line-97"}
        ]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"},
    {
      "tag": "ox-1",
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "pr.oxylabs.io",
          "port": 7777,
          "users": [{"user": "用户名", "pass": "密码"}]
        }]
      }
    },
    {
      "tag": "ox-47",
      "protocol": "http",
      "settings": {
        "servers": [{
          "address": "dc.oxylabs.io",
          "port": 8000,
          "users": [{"user": "用户名", "pass": "密码"}]
        }]
      },
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {"allowInsecure": true}
      }
    },
    {
      "tag": "kk-48",
      "protocol": "http",
      "settings": {
        "servers": [{
          "address": "gate-sea.kookeey.info",
          "port": 1000,
          "users": [{"user": "用户名", "pass": "密码"}]
        }]
      }
    }
  ],
  "routing": {
    "rules": [
      {"type": "field", "outboundTag": "block", "protocol": ["bittorrent"]},
      {"type": "field", "outboundTag": "direct", "port": "53"},
      {"type": "field", "outboundTag": "direct", "ip": ["8.8.8.8","8.8.4.4","1.1.1.1","1.0.0.1"]},
      {"type": "field", "outboundTag": "direct", "domain": ["full:dldir1v6.qq.com"]},
      {"type": "field", "inboundTag": ["vmess-in"], "user": ["line-1"], "outboundTag": "ox-1"},
      {"type": "field", "inboundTag": ["vmess-in"], "user": ["line-2"], "outboundTag": "ox-2"}
    ]
  }
}
```

**配置要点:**
- line-1 到 line-46: Oxylabs S5 (socks 协议)
- dc-47: Oxylabs 数据中心 (http 协议 + TLS)
- line-48 到 line-97: Kookeey gate-sea (http 协议)
- 每个用户 email 对应一条路由规则，分配到独立的代理出口

### 1.4 启动 Xray

```bash
systemctl enable xray
systemctl restart xray
systemctl status xray
```

### 1.5 同步配置到其他服务器

三台服务器配置完全相同，直接复制即可：

```bash
# 从 HK 复制到 US
scp root@93.179.124.237:/usr/local/etc/xray/config.json \
  root@138.128.193.157:/usr/local/etc/xray/config.json

# 从 HK 复制到 SG
scp root@93.179.124.237:/usr/local/etc/xray/config.json \
  root@45.77.248.60:/usr/local/etc/xray/config.json
```

---

## 二、代理出口说明

### 2.1 Oxylabs S5 住宅代理 (line-1 ~ line-46)

- 协议: SOCKS5
- 地址: `pr.oxylabs.io:7777`
- 速度: ~1 MB/s (从 HK)
- 特点: 美国住宅 IP，带 session 定时切换
- 注意: session 会过期，需定期更新代理列表

### 2.2 Oxylabs 数据中心代理 (dc-47)

- 协议: HTTPS (HTTP CONNECT over TLS)
- 地址: `dc.oxylabs.io:8000`
- 速度: ~1 MB/s
- 特点: 数据中心 IP（非住宅），Xray 配置需加 `streamSettings.security: "tls"`

### 2.3 Kookeey gate-sea 住宅代理 (line-48 ~ line-97)

- 协议: HTTP
- 地址: `gate-sea.kookeey.info:1000`
- 速度: ~400 KB/s (从 HK)
- 特点: 美国住宅 IP，2 分钟定时切换
- 格式: `用户名:密码-US-会话ID-2m`

---

## 三、VMess 链接生成

### 链接格式要求（必须遵守）

- `port` 和 `aid` 必须是**字符串**（`"22620"`、`"0"`），不能是整数
- 必须包含额外字段: `scy`, `sni`, `alpn`, `fp`

完整模板:
```json
{
  "v": "2",
  "ps": "名称",
  "add": "服务器IP或域名",
  "port": "22620",
  "id": "UUID",
  "aid": "0",
  "scy": "auto",
  "net": "tcp",
  "type": "none",
  "host": "",
  "path": "",
  "tls": "",
  "sni": "",
  "alpn": "",
  "fp": ""
}
```

### 生成脚本示例

```python
import json, base64

clients = [...]  # 从 config.json 读取
server = "93.179.124.237"  # 或 v.app-ns.com

for i, cl in enumerate(clients):
    obj = {
        "v": "2", "ps": f"line-{i+1}", "add": server, "port": "22620",
        "id": cl["id"], "aid": "0", "scy": "auto", "net": "tcp",
        "type": "none", "host": "", "path": "", "tls": "",
        "sni": "", "alpn": "", "fp": ""
    }
    link = "vmess://" + base64.b64encode(json.dumps(obj).encode()).decode()
    print(link)
```

---

## 四、桌面链接文件说明

| 文件名 | 内容 | 地址 |
|--------|------|------|
| 香港-vless_links_46.txt | Oxylabs S5 x 46 | 93.179.124.237 |
| 香港-dc_oxylabs.txt | dc.oxylabs x 1 | 93.179.124.237 |
| 香港-kookeey_sea_50.txt | Kookeey sea x 50 | 93.179.124.237 |
| 域名-oxylabs_46.txt | Oxylabs S5 x 46 | v.app-ns.com |
| 域名-dc_oxylabs.txt | dc.oxylabs x 1 | v.app-ns.com |
| 域名-kookeey_sea_50.txt | Kookeey sea x 50 | v.app-ns.com |

---

## 五、Cloudflare DNS 切换

使用 Cloudflare API 切换服务器:

```bash
# 查看当前 DNS 记录
curl -s "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records" \
  -H "Authorization: Bearer API_TOKEN"

# 修改 A 记录指向 (RECORD_ID 从上面获取)
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records/RECORD_ID" \
  -H "Authorization: Bearer API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"A","name":"v","content":"新IP","ttl":60,"proxied":false}'
```

当前信息:
- Zone ID: `d0221a78ee7d25d3e23aca5498eebf0b`
- Record ID: `8ebc7d125981e78b4c098005dc364004`
- 域名: `v.app-ns.com`

---

## 六、路由规则说明

配置中的路由规则按顺序匹配:

1. **BT 屏蔽** - BitTorrent 协议直接拦截
2. **DNS 端口直连** - 端口 53 的流量走直连，避免 DNS 查询通过代理超时
3. **DNS IP 直连** - 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1 走直连
4. **特定域名直连** - `dldir1v6.qq.com` 等不需要代理的域名
5. **用户路由** - 根据用户 email (line-1, line-2...) 分配到对应代理出口

---

## 七、Mux 多路复用（可选）

### 适用场景
- 需要降低服务器连接数
- 小流量、多请求的场景

### 路由器 Mux 中转方案

```
手机 (VMess) -> 路由器 192.168.66.1:22620 (VMess+Mux) -> HK -> 代理出口
```

路由器 Xray 配置要点:
- VMess 入站: 与 HK 相同的 97 个 UUID
- VMess 出站: 连接 HK，每个 UUID 一条出站，启用 Mux
- Mux concurrency 建议值: **2**（更高会卡）

```json
{
  "mux": {
    "enabled": true,
    "concurrency": 2
  }
}
```

### 注意事项
- Mux 只减少路由器到HK的连接数，手机到路由器不受影响
- 住宅代理响应不稳定时，Mux 会放大延迟问题
- 如果感觉卡顿，建议关闭 Mux 直连 HK

---

## 八、速度参考

2MB 文件下载测试 (从各服务器经 Oxylabs S5):

| 服务器 | 平均速度 |
|--------|---------|
| HK | ~891 KB/s |
| US | ~1,011 KB/s |
| SG | ~788 KB/s |

各代理出口速度 (从 HK):

| 代理 | 平均速度 |
|------|---------|
| Oxylabs S5 (pr.oxylabs.io:7777) | ~1 MB/s |
| dc.oxylabs (dc.oxylabs.io:8000) | ~1 MB/s |
| Kookeey gate-sea | ~400 KB/s |

---

## 九、重要经验

1. **关闭 BBR**: 住宅代理带宽有限，BBR 的激进拥塞控制会导致丢包重传，速度反而下降。用 cubic。
2. **DNS 必须直连**: 如果 DNS 查询也走代理，会超时导致无法上网。配置中必须加 DNS 直连规则。
3. **VMess 链接格式**: port/aid 必须是字符串，必须包含 scy/sni/alpn/fp 字段，否则部分客户端无法使用。
4. **Oxylabs session 过期**: S5 的 sesstime 参数控制 session 有效期，过期后需更新代理列表。
5. **dc.oxylabs 需要 TLS**: 数据中心代理是 HTTPS 协议，Xray 出站需配置 `streamSettings.security: "tls"`。
6. **Kookeey gate-sea 是 HTTP 代理**: 不是 SOCKS5，Xray 出站协议用 `http`。
