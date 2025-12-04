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

# --- 修改网络配置部分 ---
# 检查系统是否使用 netplan
if [ -d "/etc/netplan" ]; then
    echo "系统使用 netplan 配置。正在修改 /etc/netplan/50-cloud-init.yaml 中的DNS设置..."
    # 修改 /etc/netplan/50-cloud-init.yaml 中的 DNS 配置
    sudo sed -i "/nameservers:/,/addresses:/c\nnameservers:\n  addresses:\n    - ${dns_array[0]}\n    - ${dns_array[1]:-1.1.1.1}\n    - 8.8.8.8" /etc/netplan/50-cloud-init.yaml
    # 应用 netplan 配置
    sudo netplan apply
    echo "netplan 配置已应用。"
elif [ -f "/etc/network/interfaces" ]; then
    echo "系统使用 ifupdown 配置。正在修改 /etc/network/interfaces 中的DNS设置..."
    # 如果使用 ifupdown 配置工具，修改 /etc/network/interfaces 中的 DNS 配置
    echo -e "\ndns-nameservers ${dns_array[0]} ${dns_array[1]:-1.1.1.1} 8.8.8.8" | sudo tee -a /etc/network/interfaces
    # 重启网络服务
    sudo systemctl restart networking
    echo "ifupdown 配置已更新并应用。"
else
    echo "未检测到 netplan 或 ifupdown 配置，可能是使用 NetworkManager。"
    echo "请手动检查 DNS 设置。"
fi

# --- 修改 systemd-resolved 配置部分 ---
# 检查 systemd 是否启用 systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
    echo "系统使用 systemd-resolved 配置。正在修改 /etc/systemd/resolved.conf 中的DNS设置..."
    # 修改 /etc/systemd/resolved.conf 中的 DNS 配置
    sudo sed -i "/DNS=/c\DNS=${dns_array[0]}\nFallbackDNS=1.1.1.1 8.8.8.8" /etc/systemd/resolved.conf
    # 重启 systemd-resolved 服务
    sudo systemctl restart systemd-resolved
    echo "systemd-resolved 配置已更新并重启。"
else
    echo "系统未启用 systemd-resolved，使用 /etc/resolv.conf 配置。正在修改 /etc/resolv.conf..."
    # 如果没有 systemd-resolved，修改 /etc/resolv.conf
    sudo sed -i "/^nameserver/c\nameserver ${dns_array[0]}" /etc/resolv.conf
    sudo sh -c "echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"
    sudo sh -c "echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
    echo "/etc/resolv.conf 配置已更新。"
fi

# 输出当前 DNS 配置
echo "DNS配置已更改为:"
systemd-resolve --status || cat /etc/resolv.conf

echo "修改完成！"
