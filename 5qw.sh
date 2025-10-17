#!/bin/bash

# 选择需要测速的地址
URLS=("http://example.com" "http://google.com" "http://baidu.com" "http://your-server-address.com")

# 清屏
clear

# 显示菜单
echo "选择一个操作:"
echo "1. 开始流量消耗"
echo "2. 退出"

# 读取用户输入
read -p "请输入选择(1-2): " choice

# 开始流量消耗
if [ "$choice" -eq 1 ]; then
    clear
    echo "开始流量消耗..."
    
    # 循环执行测速
    for URL in "${URLS[@]}"; do
        echo "正在测试: $URL"
        # 使用 curl 测试流量消耗并测速
        curl -s -o /dev/null -w "消耗流量: %{size_download} bytes, 请求时间: %{time_total} 秒\n" "$URL"
    done
    
    echo "流量消耗完毕！"
elif [ "$choice" -eq 2 ]; then
    clear
    echo "退出程序！"
    exit 0
else
    echo "无效的输入，请选择 1 或 2"
fi
