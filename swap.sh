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
