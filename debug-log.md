# Shadowrocket 内网域名访问问题排查日志

## 问题现象

开启 Shadowrocket 后，访问 `*.sankuai.com` 等公司内网域名失败。

## 排查进展

### 阶段 1：Fake IP 路由问题

**发现**：SR 开启后，DNS 返回 Fake IP (198.18.0.x)，但 `bypass-tun` 包含 `198.18.0.0/15`，导致 Fake IP 流量被路由到物理网关而非 SR TUN。

**解决**：从 `bypass-tun` 中移除 `198.18.0.0/15`。

**结果**：Fake IP 流量正确进入 SR TUN，但仍然失败。

---

### 阶段 2：规则匹配问题

**发现**：`[Rule]` 中没有 sankuai.com 的直连规则，导致走默认代理策略。

**解决**：添加 `DOMAIN-SUFFIX,sankuai.com,DIRECT` 等规则。

**结果**：TCP 连接成功，但 TLS 握手失败。

---

### 阶段 3：TLS 握手问题

**发现**：
- TCP 连接到 Fake IP 成功
- TLS 握手时 SR 关闭连接（`SSL_ERROR_SYSCALL`）
- 服务器没有返回证书
- 直连真实 IP (10.192.22.20) TLS 正常

**分析**：SR 在处理 DIRECT 规则时，内部连接真实服务器失败。

**尝试 1**：添加 `[Host] real-ip` 配置 → SR 不支持此语法

**尝试 2**：改为 `[Host] *.sankuai.com = system` → 让公司域名使用系统 DNS

**结果**：待测试...

---

## 当前状态

- [x] bypass-tun 移除 198.18.0.0/15
- [x] bypass-tun 移除 100.64.0.0/10 (Tailscale)
- [x] skip-proxy 添加公司域名
- [x] [Rule] 添加公司域名 DIRECT 规则
- [x] [Host] 添加 system DNS 配置
- [ ] 测试验证

## 下一步

1. 推送更新到 GitHub
2. SR 中更新模块
3. 测试 DNS 解析是否返回真实 IP
4. 测试 HTTPS 连接
