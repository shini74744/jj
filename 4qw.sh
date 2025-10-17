#!/bin/bash

# 获取VPS性能来自动选择线程数量
get_optimal_threads() {
    local cpu_count=$(nproc)  # 获取CPU核心数
    echo $((cpu_count * 2))   # 根据核心数推荐线程数，通常2倍核心数
}

# 随机选择测速地址
get_random_speedtest_url() {
    local urls=(
        "https://speed.cloudflare.com/__down?bytes=104857600"   # Cloudflare 100MB测速
    )
    echo ${urls[$RANDOM % ${#urls[@]}]}
}

# 检查URL是否可用
check_url() {
    local url=$1
    local retries=3
    local success=false
    for ((i=0; i<$retries; i++)); do
        if curl -s --head "$url" | grep "200 OK" > /dev/null; then
            success=true
            break
        fi
        echo "地址 $url 不可用，正在重试..."
        sleep 2
    done
    echo $success
}

# 测试下载流量
download_speed() {
    local url=$1
    local thread_count=$2
    local total_downloaded=0
    for ((i=0; i<thread_count; i++)); do
        wget --spider --no-check-certificate "$url" --progress=dot -O /dev/null 2>&1 | \
        grep --line-buffered "%" | \
        while read -r line; do
            # 提取下载进度百分比
            progress=$(echo $line | awk '{print $2}' | sed 's/%//')
            if [[ ! -z "$progress" ]]; then
                # 计算下载进度，假设每次下载10MB
                total_downloaded=$((total_downloaded + 10))  # 每次下载10MB
                echo "当前下载进度: ${progress}%"
                echo "当前总下载流量: ${total_downloaded}MB"
            fi
        done &
    done
    wait
}

# 测试上传流量
upload_speed() {
    local url=$1
    local thread_count=$2
    local retries=3  # 设置最大重试次数
    local total_uploaded=0
    for ((i=0; i<thread_count; i++)); do
        attempt=1
        while [[ $attempt -le $retries ]]; do
            echo "上传尝试 $attempt/$retries"
            result=$(dd if=/dev/urandom bs=1M count=10 | curl -X POST --data-binary @- "$url" -w "%{size_download}" -o /dev/null)
            if [[ $? -eq 0 ]]; then
                total_uploaded=$((total_uploaded + result))
                echo "上传成功，当前总上传流量: ${total_uploaded}MB"
                break
            else
                echo "上传失败，正在重试..."
                ((attempt++))
                sleep 2  # 重试前等待2秒
            fi
        done &
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
            
            # 选择下载测速地址
            valid_download_urls=()
            invalid_download_urls=()
            for i in {1..5}; do  # 执行最多5次检查
                url=$(get_random_speedtest_url)
                if check_url "$url"; then
                    valid_download_urls+=("$url")
                else
                    invalid_download_urls+=("$url")
                fi
            done

            # 选择上传测速地址
            valid_upload_urls=()
            invalid_upload_urls=()
            for i in {1..5}; do  # 执行最多5次检查
                url=$(get_random_speedtest_url)
                if check_url "$url"; then
                    valid_upload_urls+=("$url")
                else
                    invalid_upload_urls+=("$url")
                fi
            done

            if [ ${#valid_download_urls[@]} -eq 0 ] || [ ${#valid_upload_urls[@]} -eq 0 ]; then
                echo "没有有效的下载或上传地址，退出程序。"
                exit 1
            fi

            # 输出下载地址和上传地址
            echo "当前下载地址： ${valid_download_urls[0]}"
            echo "当前上传地址： ${valid_upload_urls[0]}"

            # 选择测速模式
            read -p "选择测速模式（1: 下载 2: 上传 3: 同时）: " mode
            case $mode in
                1)
                    echo "开始下载测速..."
                    download_speed "${valid_download_urls[0]}" "$thread_count"
                    ;;
                2)
                    echo "开始上传测速..."
                    upload_speed "${valid_upload_urls[0]}" "$thread_count"
                    ;;
                3)
                    echo "开始下载和上传测速..."
                    download_speed "${valid_download_urls[0]}" "$thread_count" &
                    upload_speed "${valid_upload_urls[0]}" "$thread_count" &
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
