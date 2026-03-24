# Shadowrocket 问题排查完整记录

## 环境背景

- **设备**: Mac
- **代理软件**: Shadowrocket (SR)
- **公司网络**: 通过 Tailscale 连接
- **公司域名**: *.sankuai.com, *.meituan.com 等
- **DNS**: 公司 DNS 服务器 11.11.11.11

---

## 问题一：Tailscale 路由冲突

### 问题现象

| 状态 | Ping Tailscale 设备 | 原因 |
|------|---------------------|------|
| SR 开启 | 100% 丢包 | SR 路由覆盖了 Tailscale |
| SR 关闭 | 0% 丢包 | Tailscale 路由正常 |

### 根本原因

订阅配置的 `bypass-tun` 包含 `100.64.0.0/10`（CGNAT 地址段）。

`bypass-tun` 的作用是告诉系统："发往这些 IP 的流量不要走 TUN"。

macOS/iOS 实现这个"排除"的方式是：**创建一条指向物理默认网关的最高优先级路由**。

```
SR 开启时：
100.64/10 → 物理网关 → en0 (SR 创建的高优先级路由) ❌
100.64/10 → utun6    (Tailscale，被覆盖)

SR 关闭时：
100.64/10 → utun6 (Tailscale) ✅
```

### 解决方案

在 Module 中重写 `bypass-tun`，**剔除 `100.64.0.0/10`**。

```ini
[General]
bypass-tun = 10.0.0.0/8,127.0.0.0/8,... (不含 100.64.0.0/10)

[Rule]
IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
```

### 结果

✅ **已解决** - Tailscale 流量正确路由到 utun6

---

## 问题二：Fake IP 导致内网域名无法访问

### 问题现象

| 状态 | 访问 sankuai.com | 错误信息 |
|------|------------------|----------|
| SR 开启 | ❌ 失败 | SSL_ERROR_SYSCALL |
| SR 关闭 | ✅ 成功 | - |

### 根本原因分析

#### Fake IP 机制

SR 默认使用 **Fake IP 模式**：
1. DNS 查询被 SR 拦截
2. SR 返回假 IP（198.18.0.x），而非真实 IP
3. 当流量发往假 IP 时，SR 知道对应哪个域名，可应用规则

#### 冲突机制

```
bypass-tun 包含 198.18.0.0/15 (Fake IP 段)
→ Fake IP 流量被路由到物理网关 (en0)
→ 物理网关不知道假 IP 是什么 → 连接关闭 ❌
```

### 解决方案

从 `bypass-tun` 中**移除 `198.18.0.0/15`**。

### 结果

✅ Fake IP 流量正确进入 SR TUN，但 **TLS 握手失败**

---

## 问题三：Fake IP 模式下 TLS 握手失败（当前问题）

### 问题现象

- DNS 解析返回 Fake IP (198.18.0.x) ✓
- TCP 连接成功 ✓
- **TLS 握手失败** - SSL_ERROR_SYSCALL ✗

### 排查发现

| 测试 | 结果 |
|------|------|
| 真实 IP (10.192.22.20) 直连 TLS | ✅ 正常 |
| Fake IP 通过 SR TLS | ❌ 失败 |

**结论**: SR 在处理 Fake IP 到真实 IP 的 TLS 转发时出现问题。

### 尝试过的解决方案

| 方案 | 配置 | 结果 |
|------|------|------|
| `[Host] real-ip` | `*.sankuai.com = real-ip` | ❌ SR 不支持此语法 |
| `[Host] system` | `*.sankuai.com = system` | ❌ 不生效，仍返回 Fake IP |
| `[General] real-ip` | `real-ip = *.sankuai.com` | ❌ 不生效 |
| `[General] always-real-ip` | `always-real-ip = *.sankuai.com` | ❌ 不生效 |
| `[General] fake-ip-filter` | `fake-ip-filter = *.sankuai.com` | ❌ 不生效 |

### 当前状态

- [x] bypass-tun 移除 198.18.0.0/15
- [x] bypass-tun 移除 100.64.0.0/10 (Tailscale)
- [x] skip-proxy 添加公司域名
- [x] [Rule] 添加公司域名 DIRECT 规则
- [ ] **让公司域名跳过 Fake IP** - 所有尝试均失败

---

## 关键配置项说明

| 配置项 | 作用层级 | 说明 |
|--------|----------|------|
| `bypass-tun` | 系统路由 | 排除的 IP 不走 TUN，系统创建指向物理网关的路由 |
| `skip-proxy` | HTTP 代理 | 排除的 IP/域名不走 HTTP 代理，防止 503 |
| `[Rule]` | SR 引擎 | 流量判定规则，决定 DIRECT/PROXY |
| `[Host]` | DNS 映射 | 域名到 IP 的映射 |
| `fake-ip-filter` | Fake IP | 排除域名不使用 Fake IP（Surge 语法） |

---

## 待尝试方案

### 方案 A：特定 Tailscale IP（用户建议）

不从 bypass-tun 移除整个 100.64.0.0/10，改为只处理特定 Tailscale IP。

**问题**: 这与 sankuai.com 的 Fake IP 问题无关。

### 方案 B：切换到 Redir Host 模式

在 SR 设置中将 DNS 模式从 Fake IP 切换到 Redir Host（真实 IP）。

**缺点**: 可能影响其他功能（规则匹配延迟等）。

### 方案 C：检查 Module 配置是否生效

Module 中的某些配置可能不被 SR 识别或覆盖。需要确认：
1. Module 是否正确加载
2. 配置是否被主订阅覆盖

### 方案 D：联系 SR 开发者

可能需要向 Shadowrocket 开发者反馈此问题。

---

## 路由表状态（SR 开启时）

```
default            → utun7 (SR TUN)
198.18.0/15        → utun7 (SR TUN) ✓ Fake IP 正确进入 SR
100.64/10          → utun6 (Tailscale TUN) ✓ Tailscale 正常
```

---

## 文件变更历史

| 提交 | 描述 |
|------|------|
| c98cf8e | 重写 bypass-tun 解决 Tailscale |
| ec1ce2c | 移除 198.18.0.0/15 解决 Fake IP 路由 |
| eae3849 | 文档记录 Fake IP 问题 |
| 2718b8f | 添加 sankuai/meituan DIRECT 规则 |
| e99bebb | 尝试 [Host] real-ip |
| d753e77 | 尝试 [Host] system |
| 9e37ae9 | 尝试 real-ip 指令 |
| c2d9338 | 尝试 fake-ip-filter |
