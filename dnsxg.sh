#!/bin/bash

# 提示用户输入主 DNS 服务器
echo "请输入要设置的主DNS服务器（如果有多个DNS，使用空格分隔）:"
read dns_servers

# 获取当前的主DNS地址
IFS=' ' read -r -a dns_array <<< "$dns_servers"
if [ ${#dns_array[@]} -lt 1 ]; then
  echo "请输入至少一个DNS服务器地址。"
  exit 1
fi

# --- 修改 netplan 配置部分 ---
# 查找 netplan 配置目录中的所有 .yaml 文件
netplan_files=$(ls /etc/netplan/*.yaml)

if [ -n "$netplan_files" ]; then
    for file in $netplan_files; do
        echo "正在修改 $file 中的 DNS 设置..."
        # 修改 netplan 配置文件中的 DNS 配置
        sudo sed -i "/nameservers:/,/addresses:/c\nnameservers:\n  addresses:\n    - ${dns_array[0]}\n    - ${dns_array[1]:-1.1.1.1}\n    - 8.8.8.8" "$file"
    done
    # 应用 netplan 配置
    sudo netplan apply
    echo "netplan 配置已应用。"
else
    echo "未检测到 netplan 配置文件，请检查系统的网络配置。"
    exit 1
fi

# --- 修改 systemd-resolved 配置部分 ---
# 检查 systemd 是否启用 systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
    echo "系统使用 systemd-resolved 配置。正在修改 /etc/systemd/resolved.conf 中的DNS设置..."
    
    # 清理重复的 DNS 配置，确保只修改一次
    sudo sed -i "/^DNS=/c\DNS=${dns_array[0]}" /etc/systemd/resolved.conf
    sudo sed -i "/^FallbackDNS=/c\FallbackDNS=1.1.1.1 8.8.8.8" /etc/systemd/resolved.conf
    
    # 重新生成 /etc/resolv.conf 并禁用 stub 模式
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    
    # 重启 systemd-resolved 服务
    sudo systemctl restart systemd-resolved
    echo "systemd-resolved 配置已更新并重启。"
else
    echo "系统未启用 systemd-resolved，使用 /etc/resolv.conf 配置。正在修改 /etc/resolv.conf..."
    # 如果没有 systemd-resolved，修改 /etc/resolv.conf
    sudo sed -i "/^nameserver/c\nnameserver ${dns_array[0]}" /etc/resolv.conf
    sudo sh -c "echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"
    sudo sh -c "echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
    echo "/etc/resolv.conf 配置已更新。"
fi

# 输出当前 DNS 配置
echo "DNS配置已更改为:"
resolvectl status || cat /etc/resolv.conf

echo "修改完成！"
