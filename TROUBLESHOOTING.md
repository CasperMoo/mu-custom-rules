# Shadowrocket 问题排查完整记录

## 环境背景

- **设备**: Mac
- **代理软件**: Shadowrocket (SR)
- **公司网络**: 通过 Tailscale 连接
- **公司域名**: *.sankuai.com, *.meituan.com 等
- **公司 DNS**: 11.11.11.11

---

## 问题一：Tailscale 路由冲突 ✅ 已解决

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
bypass-tun = 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8

[Rule]
IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
```

---

## 问题二：内网域名 TLS 握手失败 ✅ 已解决

### 问题现象

| 状态 | 访问 sankuai.com | 错误信息 |
|------|------------------|----------|
| SR 开启 | ❌ 失败 | SSL_ERROR_SYSCALL |
| SR 关闭 | ✅ 成功 | - |

### 排查过程

#### 阶段 1：Fake IP 路由问题

**发现**：`bypass-tun` 包含 `198.18.0.0/15`（Fake IP 段），导致 Fake IP 流量被路由到物理网关。

**解决**：从 bypass-tun 移除 `198.18.0.0/15`。

**结果**：Fake IP 流量正确进入 SR TUN，但 TLS 仍然失败。

#### 阶段 2：规则匹配问题

**发现**：缺少 DIRECT 规则，流量可能走代理。

**解决**：添加 `DOMAIN-SUFFIX,sankuai.com,DIRECT` 规则。

**结果**：TLS 仍然失败。

#### 阶段 3：尝试跳过 Fake IP（失败）

尝试了多种让公司域名跳过 Fake IP 的方法：

| 方案 | 配置 | 结果 |
|------|------|------|
| `[Host] real-ip` | `*.sankuai.com = real-ip` | ❌ SR 不支持 |
| `[Host] system` | `*.sankuai.com = system` | ❌ 不生效 |
| `[General] real-ip` | `real-ip = *.sankuai.com` | ❌ 不生效 |
| `[General] fake-ip-filter` | `fake-ip-filter = *.sankuai.com` | ❌ 不生效，且导致配置解析错误 |

#### 阶段 4：定位 DNS 解析盲区（最终方案）

**关键发现**：

通过对比测试（SR 开启 vs 关闭），发现问题根源：

1. **Fake IP 仍在生效**：`nslookup` 返回 `198.18.0.x`
2. **连接卡在 SR 内部**：SR 根据 DIRECT 规则准备直连目标服务器
3. **💥 致命问题**：SR 需要解析真实 IP 才能直连，但它使用**公共 DNS（如 8.8.8.8）**而非公司 DNS（11.11.11.11）
4. 公共 DNS 无法解析内网域名 → SR 找不到真实服务器 → 连接断开

### 最终解决方案

**核心思路**：告诉 SR 遇到公司域名时，使用公司 DNS 解析。

```ini
[General]
# 把公司 DNS 加入 bypass-tun，避免 DNS 请求被代理
bypass-tun = 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 11.11.11.11/32

[Host]
# 强制内网域名使用公司 DNS 解析
*.sankuai.com = server:11.11.11.11
*.meituan.com = server:11.11.11.11
*.sankuai.org = server:11.11.11.11
*.mt.com = server:11.11.11.11

[Rule]
DOMAIN-SUFFIX,sankuai.com,DIRECT
DOMAIN-SUFFIX,meituan.com,DIRECT
```

### 验证结果

- `nslookup` 仍返回 Fake IP（正常，Fake IP 模式下预期行为）
- `curl` HTTPS 请求成功完成 TLS 握手 ✅
- 内网域名访问正常 ✅

---

## 问题三：Tailscale 路由冲突复发（skip-proxy）🔬 待设备端验证

### 问题现象

- mini → 盒子（100.78.36.121）TS SSH 失败，包被丢给家里路由器
- `route get 100.78.36.121` → `gateway: 10.0.0.1, interface: en0`

```
100.64/10 → 10.0.0.1 → en0    (SR 创建)   ← 赢
100.64/10 → utun11           (Tailscale)  ← 被压住
```

### 与问题一的区别

问题一修复时只从 `bypass-tun` 剔除了 `100.64.0.0/10`，但 `skip-proxy` 中仍保留该段
（当时为防 HTTP 代理引擎拦截而加入）。本次在模块已存在的机器上实测：SR 运行时
en0 网关路由再次出现 → **skip-proxy 段同样会被编程为指向物理网关的系统路由**。

排除项：
- 路由器 DHCP 未下发 option 121 静态路由（`ipconfig getpacket en0` 无 classless route）
- 问题一时已实验证明：SR 关闭 → 冲突路由消失

### 修复（2026-08-25）

从 `skip-proxy` 移除 `100.64.0.0/10`。TS 全段（所有设备）的放行统一由引擎层规则承担：

```ini
[Rule]
IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
IP-CIDR6,fd7a:115c:a1e0::/48,DIRECT,no-resolve
```

引擎层 DIRECT 不创建系统路由，不会压过 Tailscale 的 utun。

### 验证步骤（设备端）

1. SR 中更新模块并重启（让 TUN 重建）
2. `netstat -rn -f inet | grep '100.64'` → 应只剩 utun 一条
3. `route get 100.78.36.121` → interface 应为 utun11
4. TS SSH 恢复

应急手段（临时，SR 重启后复原）：

```bash
sudo route delete -net 100.64.0.0/10 10.0.0.1
```

---

## 关键配置项说明

| 配置项 | 作用层级 | 说明 |
|--------|----------|------|
| `bypass-tun` | 系统路由 | 排除的 IP 不走 TUN，系统创建指向物理网关的路由 |
| `skip-proxy` | HTTP 代理 + 系统路由 | 排除的 IP/域名不走 HTTP 代理；⚠️ 段同样会被编程为指向物理网关的系统路由（问题三） |
| `[Rule]` | SR 引擎 | 流量判定规则，决定 DIRECT/PROXY |
| `[Host]` | DNS 映射 | 域名到 DNS 服务器的映射，`server:x.x.x.x` 指定 DNS |

---

## 经验总结

### 1. Fake IP 模式的工作原理

```
用户请求域名 → SR 拦截 DNS → 返回 Fake IP (198.18.x.x)
     ↓
用户连接 Fake IP → SR 根据域名匹配规则 → 决定 DIRECT/PROXY
     ↓
DIRECT 时：SR 内部解析真实 IP → 连接真实服务器
```

**关键点**：SR 内部解析真实 IP 时，需要正确的 DNS 服务器！

### 2. bypass-tun / skip-proxy 的陷阱

- `bypass-tun` 会创建指向物理网关的高优先级路由
- 如果包含 Tailscale 网段（100.64.0.0/10），会破坏 Tailscale 连接
- 如果包含 Fake IP 网段（198.18.0.0/15），Fake IP 流量无法进入 SR
- `skip-proxy` 段同样会被编程为系统路由（问题三），Tailscale 网段也不可放入
- TS 设备的排除统一走 `[Rule]` 引擎层 DIRECT（`IP-CIDR,100.64.0.0/10`），不碰系统路由

### 3. 内网域名与 Fake IP 的兼容

企业内网 DNS 通常无法被公共 DNS 解析。在 Fake IP 模式下：

- 必须在 `[Host]` 中指定内网域名使用企业 DNS
- 企业 DNS 服务器 IP 应加入 `bypass-tun`，避免 DNS 请求本身被代理

### 4. SR Module 兼容性

Shadowrocket 的 Module 机制与 Surge 有差异：
- `fake-ip-filter`、`real-ip`、`always-real-ip` 等 Surge 指令可能不被支持
- 使用这些指令可能导致配置解析错误，整个代理失效
- `[Host]` 的 `server:x.x.x.x` 语法是可靠的

---

## 路由表状态（SR 开启时）

```
default            → utun7 (SR TUN)
198.18.0/15        → utun7 (SR TUN) ✓ Fake IP 正确进入 SR
100.64/10          → utun6 (Tailscale TUN) ✓ Tailscale 正常
```

---

## 最终配置文件

参见 [my_rules.module](./my_rules.module)

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
| c2d9338 | 尝试 fake-ip-filter（导致配置解析错误） |
| c21fbfe | 回滚到稳定配置 |
| cccd966 | **最终方案**：[Host] 指定公司 DNS |
| 5fb7e11 | **问题三修复**：skip-proxy 移除 Tailscale 段，TS 放行统一走 [Rule] |
