# Shadowrocket 内网域名访问问题排查日志

## 状态：✅ 已解决

---

## 排查阶段总结

### 阶段 1：Fake IP 路由问题
- **问题**：bypass-tun 包含 198.18.0.0/15，Fake IP 流量被路由到物理网关
- **解决**：移除 198.18.0.0/15

### 阶段 2：规则匹配问题
- **问题**：缺少 DIRECT 规则
- **解决**：添加 DOMAIN-SUFFIX,sankuai.com,DIRECT

### 阶段 3：尝试跳过 Fake IP
- **尝试**：real-ip、system、fake-ip-filter 等
- **结果**：全部失败，fake-ip-filter 导致配置解析错误

### 阶段 4：DNS 解析盲区（最终定位）
- **发现**：SR 内部使用公共 DNS 解析真实 IP，无法解析内网域名
- **解决**：[Host] 指定 server:11.11.11.11，bypass-tun 添加 DNS 服务器 IP

---

## 最终解决方案

```ini
[General]
bypass-tun = 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 11.11.11.11/32

[Host]
*.sankuai.com = server:11.11.11.11
*.meituan.com = server:11.11.11.11

[Rule]
DOMAIN-SUFFIX,sankuai.com,DIRECT
```

---

详细记录见 [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
