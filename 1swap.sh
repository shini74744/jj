#!/bin/bash

# 查看当前swap使用情况，并反馈是否启动swap
check_swap() {
    echo -e "\n当前系统内存和swap使用情况:"
    
    # 使用 free 命令查看内存和swap信息
    swap_status=$(free -h)

    if [[ $(echo "$swap_status" | grep -c "Swap:") -eq 1 && $(echo "$swap_status" | grep -c "0B") -eq 1 ]]; then
        echo "$swap_status"
        echo "没有启用swap!"
    else
        echo "$swap_status"
        echo "当前swap已经启用，详细情况如下:"
    fi

    echo "--------------------------"
}

# 创建并启用swap文件
create_swap() {
    # 参数1: swap文件大小（例如 2G）
    swap_size=$1

    # 检查swap文件大小是否有效
    if [[ ! "$swap_size" =~ ^[0-9]+[Gg]$ ]]; then
        echo "请输入有效的swap文件大小（例如 2G 或 4G）。"
        return 1
    fi

    echo -e "\n创建大小为 $swap_size 的swap文件..."

    # 使用 fallocate 创建 swap 文件，如果 fallocate 失败则使用 dd
    if ! sudo fallocate -l $swap_size /swapfile; then
        echo "fallocate命令失败，尝试使用dd创建swap文件..."
        sudo dd if=/dev/zero of=/swapfile bs=1M count=$(( ${swap_size%G} * 1024 )) status=progress
    fi

    # 设置文件权限
    sudo chmod 600 /swapfile

    # 设置为swap区域
    sudo mkswap /swapfile

    # 启用swap文件
    if ! sudo swapon /swapfile; then
        echo "错误：无法启用swap文件。请检查日志或手动激活swap。"
        return 1
    fi

    # 添加到fstab文件中，确保开机自动启用
    if ! grep -q '/swapfile' /etc/fstab; then
        echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
    fi

    echo "成功创建并启用swap文件!"
    free -h
    echo "--------------------------"
}


# 设置swappiness值
set_swappiness() {
    # 参数1: swappiness值（0到100）
    swappiness_value=$1

    # 验证swappiness值是否有效
    if [[ ! "$swappiness_value" =~ ^[0-9]+$ ]] || [ "$swappiness_value" -lt 0 ] || [ "$swappiness_value" -gt 100 ]; then
        echo "请输入一个有效的swappiness值 (0-100)。"
        return 1
    fi

    # 设置swappiness值
    sudo sysctl vm.swappiness=$swappiness_value

    # 永久生效
    echo "vm.swappiness=$swappiness_value" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p

    echo "swappiness值已设置为 $swappiness_value"
    echo "--------------------------"
}

# 禁用swap
disable_swap() {
    # 禁用swap并删除swap文件
    sudo swapoff -a
    sudo rm -f /swapfile

    # 从fstab中删除swap文件条目
    sudo sed -i '/swapfile/d' /etc/fstab

    echo "swap已禁用，swap文件已删除!"
    free -h
    echo "--------------------------"
}

# 主菜单函数
show_menu() {
    echo -e "\n请选择操作:"
    echo "1. 查看当前swap使用情况"
    echo "2. 创建并启用swap文件"
    echo "3. 设置swappiness值"
    echo "4. 禁用swap"
    echo "5. 退出"
}

# 主逻辑
while true; do
    show_menu
    read -p "请输入选择 (1-5): " choice

    case $choice in
        1)
            check_swap
            ;;
        2)
            read -p "请输入要创建的swap文件大小 (例如 2G 或 4G): " swap_size
            create_swap $swap_size
            ;;
        3)
            read -p "请输入swappiness值 (0到100): " swappiness_value
            set_swappiness $swappiness_value
            ;;
        4)
            disable_swap
            ;;
        5)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择!"
            ;;
    esac
done
