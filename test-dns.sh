#!/bin/bash
# DNS 解析测试脚本

DOMAIN="msstest.vip.sankuai.com"

echo "============================================"
echo "测试域名: $DOMAIN"
echo "当前时间: $(date)"
echo "============================================"
echo ""

echo ">>> nslookup 结果:"
nslookup $DOMAIN

echo ""
echo ">>> dig 结果:"
dig $DOMAIN +short

echo ""
echo ">>> curl 连接测试 (5秒超时):"
curl -v --connect-timeout 5 https://$DOMAIN 2>&1 | head -20

echo ""
echo "============================================"
echo "测试完成"
echo "============================================"
