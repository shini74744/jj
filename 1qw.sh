#!/bin/bash

# 获取VPS性能来自动选择线程数量
get_optimal_threads() {
    local cpu_count=$(nproc)  # 获取CPU核心数
    echo $((cpu_count * 2))   # 根据核心数推荐线程数，通常2倍核心数
}

# 随机选择测速地址
get_random_speedtest_url() {
    local urls=(
        "http://ipv4.download.thinkbroadband.com/10MB.zip"
        "http://ipv4.speedtest.tele2.net/10MB.zip"
        "http://speed.hetzner.de/10MB.bin"
    )
    echo ${urls[$RANDOM % ${#urls[@]}]}
}

# 测试下载流量
download_speed() {
    local url=$1
    local thread_count=$2
    for ((i=0; i<thread_count; i++)); do
        wget -q --spider --no-check-certificate "$url" &
    done
    wait
}

# 测试上传流量
upload_speed() {
    local url=$1
    local thread_count=$2
    for ((i=0; i<thread_count; i++)); do
        dd if=/dev/urandom bs=1M count=10 | curl -X POST --data-binary @- "$url" &
    done
    wait
}

# 显示菜单并执行相应操作
display_menu() {
    echo "===== VPS 流量消耗脚本 ====="
    echo "1. 开始测速消耗"
    echo "2. 退出"
    read -p "请选择操作（1/2）: " choice
    
    case $choice in
        1)
            # 选择线程数
            read -p "请输入线程数量（默认根据VPS性能选择，当前推荐 $(get_optimal_threads)）： " thread_count
            thread_count=${thread_count:-$(get_optimal_threads)}  # 如果没有输入，使用默认值
            
            # 选择测速地址
            read -p "请输入测速地址（默认随机选择，当前选择 $(get_random_speedtest_url)）： " url
            url=${url:-$(get_random_speedtest_url)}  # 如果没有输入，使用随机地址

            # 选择上传还是下载
            read -p "选择测速模式（1: 下载 2: 上传 3: 同时）: " mode
            case $mode in
                1)
                    echo "开始下载测速..."
                    download_speed "$url" "$thread_count"
                    ;;
                2)
                    echo "开始上传测速..."
                    upload_speed "$url" "$thread_count"
                    ;;
                3)
                    echo "开始下载和上传测速..."
                    download_speed "$url" "$thread_count" &
                    upload_speed "$url" "$thread_count" &
                    wait
                    ;;
                *)
                    echo "无效选择，请重新运行程序。"
                    ;;
            esac
            ;;
        2)
            echo "退出程序。"
            exit 0
            ;;
        *)
            echo "无效选择，请重新选择。"
            ;;
    esac
}

# 主程序
while true; do
    display_menu
done
