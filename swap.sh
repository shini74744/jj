#!/usr/bin/env bash

SWAPFILE="/swapfile"
SYSCTL_FILE="/etc/sysctl.d/99-swappiness.conf"
FSTAB_FILE="/etc/fstab"

run_priv() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

check_privilege() {
    if [[ "$(id -u)" -ne 0 ]]; then
        sudo -v || {
            echo "错误：需要sudo权限。"
            exit 1
        }
    fi
}

is_swap_active() {
    local target="$1"
    swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$target"
}

get_swap_type() {
    local target="$1"
    swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk -v target="$target" '$1 == target {print $2; exit}'
}

get_first_active_swap_file() {
    swapon --show=NAME,TYPE --noheadings 2>/dev/null | awk '$2 == "file" {print $1; exit}'
}

remove_fstab_swap_entry() {
    local target="$1"

    if [[ ! -f "$FSTAB_FILE" ]]; then
        return 0
    fi

    local backup="${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    local tmpfile

    tmpfile="$(mktemp)" || {
        echo "错误：无法创建临时文件。"
        return 1
    }

    run_priv cp "$FSTAB_FILE" "$backup"

    awk -v target="$target" '
        !(($1 == target) && ($3 == "swap")) { print }
    ' "$FSTAB_FILE" > "$tmpfile"

    run_priv cp "$tmpfile" "$FSTAB_FILE"
    rm -f "$tmpfile"

    echo "已清理 $FSTAB_FILE 中的 $target 条目。"
    echo "fstab备份文件：$backup"
}

check_swap() {
    echo -e "\n当前系统内存和swap使用情况:"
    free -h

    local swap_total
    swap_total=$(free -b | awk '/^Swap:/ {print $2}')

    echo

    if [[ "$swap_total" -eq 0 ]]; then
        echo "当前没有启用swap。"
    else
        echo "当前已启用swap，详细信息如下:"
        swapon --show
    fi

    echo
    echo "当前swappiness值:"
    cat /proc/sys/vm/swappiness

    echo "--------------------------"
}

create_swap_with_dd() {
    local swap_size="$1"
    local num unit count_mb

    num="${swap_size%[MmGg]}"
    unit="${swap_size: -1}"
    unit="${unit^^}"

    if [[ "$unit" == "G" ]]; then
        count_mb=$((num * 1024))
    else
        count_mb="$num"
    fi

    run_priv dd if=/dev/zero of="$SWAPFILE" bs=1M count="$count_mb" status=progress
}

create_swap() {
    local swap_size="$1"
    local created_by="fallocate"

    if [[ ! "$swap_size" =~ ^[0-9]+[MmGg]$ ]]; then
        echo "请输入有效的swap文件大小，例如 512M、2G、4G。"
        return 1
    fi

    if is_swap_active "$SWAPFILE"; then
        echo "$SWAPFILE 已经是启用状态。"
        swapon --show
        return 1
    fi

    if [[ -e "$SWAPFILE" ]]; then
        echo "错误：$SWAPFILE 已存在。"
        echo "请先删除旧swap文件，或手动处理后再创建。"
        return 1
    fi

    echo -e "\n创建大小为 $swap_size 的swap文件：$SWAPFILE"

    if ! run_priv fallocate -l "$swap_size" "$SWAPFILE"; then
        echo "fallocate创建失败，改用dd创建swap文件..."
        created_by="dd"

        if ! create_swap_with_dd "$swap_size"; then
            echo "错误：dd创建swap文件失败。"
            return 1
        fi
    fi

    run_priv chmod 600 "$SWAPFILE"

    if ! run_priv mkswap "$SWAPFILE"; then
        echo "错误：mkswap失败。"
        run_priv rm -f "$SWAPFILE"
        return 1
    fi

    if ! run_priv swapon "$SWAPFILE"; then
        if [[ "$created_by" == "fallocate" ]]; then
            echo "fallocate创建的swap文件启用失败，尝试使用dd重建..."

            run_priv swapoff "$SWAPFILE" 2>/dev/null
            run_priv rm -f "$SWAPFILE"

            if ! create_swap_with_dd "$swap_size"; then
                echo "错误：dd重建swap文件失败。"
                return 1
            fi

            run_priv chmod 600 "$SWAPFILE"

            if ! run_priv mkswap "$SWAPFILE"; then
                echo "错误：mkswap失败。"
                run_priv rm -f "$SWAPFILE"
                return 1
            fi

            if ! run_priv swapon "$SWAPFILE"; then
                echo "错误：仍然无法启用swap文件。"
                echo "请检查文件系统是否支持swapfile，例如Btrfs需要额外配置。"
                return 1
            fi
        else
            echo "错误：无法启用swap文件。"
            return 1
        fi
    fi

    if ! awk -v target="$SWAPFILE" '($1 == target) && ($3 == "swap") {found=1} END {exit !found}' "$FSTAB_FILE" 2>/dev/null; then
        echo "$SWAPFILE none swap sw 0 0" | run_priv tee -a "$FSTAB_FILE" > /dev/null
        echo "已添加到 $FSTAB_FILE，开机将自动启用。"
    else
        echo "$FSTAB_FILE 中已存在 $SWAPFILE 条目。"
    fi

    echo "成功创建并启用swap文件。"
    free -h
    echo "--------------------------"
}

set_swappiness() {
    local swappiness_value="$1"

    if [[ ! "$swappiness_value" =~ ^[0-9]+$ ]] || \
       [[ "$swappiness_value" -lt 0 ]] || \
       [[ "$swappiness_value" -gt 100 ]]; then
        echo "请输入一个有效的swappiness值：0-100。"
        return 1
    fi

    echo "当前swappiness值：$(cat /proc/sys/vm/swappiness)"
    echo "正在设置swappiness为：$swappiness_value"

    if ! run_priv sysctl "vm.swappiness=$swappiness_value"; then
        echo "错误：临时设置swappiness失败。"
        return 1
    fi

    echo "vm.swappiness=$swappiness_value" | run_priv tee "$SYSCTL_FILE" > /dev/null

    if ! run_priv sysctl -p "$SYSCTL_FILE" > /dev/null; then
        echo "错误：永久配置加载失败。"
        return 1
    fi

    echo "swappiness已设置为：$(cat /proc/sys/vm/swappiness)"
    echo "永久配置文件：$SYSCTL_FILE"
    echo "--------------------------"
}

disable_swap_file() {
    local target
    local detected_swap

    echo -e "\n当前启用的swap:"
    if swapon --show | grep -q .; then
        swapon --show
    else
        echo "当前没有启用的swap。"
    fi

    detected_swap="$(get_first_active_swap_file)"

    if [[ -n "$detected_swap" ]]; then
        read -r -p "请输入要禁用的swap文件路径，默认 $detected_swap: " target
        target="${target:-$detected_swap}"
    else
        read -r -p "请输入要禁用的swap文件路径，默认 $SWAPFILE: " target
        target="${target:-$SWAPFILE}"
    fi

    if [[ -z "$target" ]]; then
        echo "路径不能为空。"
        return 1
    fi

    if [[ "$target" != /* ]]; then
        echo "请输入绝对路径，例如 /swapfile 或 /swap.img。"
        return 1
    fi

    if ! is_swap_active "$target"; then
        echo "$target 当前没有启用。"
        return 0
    fi

    local swap_type
    swap_type="$(get_swap_type "$target")"

    if [[ "$swap_type" != "file" ]]; then
        echo "拒绝操作：$target 不是普通swap文件，类型为 $swap_type。"
        echo "为避免误关swap分区或zram，本功能只处理swap文件。"
        return 1
    fi

    if ! run_priv swapoff "$target"; then
        echo "错误：禁用 $target 失败。"
        echo "可能是当前内存不足，无法把swap中的内容迁回内存。"
        return 1
    fi

    remove_fstab_swap_entry "$target"

    echo "$target 已禁用，但文件未删除。"
    free -h
    echo "--------------------------"
}

delete_existing_swap_file() {
    local target
    local detected_swap

    echo -e "\n当前启用的swap:"
    if swapon --show | grep -q .; then
        swapon --show
    else
        echo "当前没有启用的swap。"
    fi

    detected_swap="$(get_first_active_swap_file)"

    if [[ -n "$detected_swap" ]]; then
        read -r -p "请输入要删除的swap文件路径，默认 $detected_swap: " target
        target="${target:-$detected_swap}"
    else
        read -r -p "请输入要删除的swap文件路径，默认 $SWAPFILE: " target
        target="${target:-$SWAPFILE}"
    fi

    if [[ -z "$target" ]]; then
        echo "路径不能为空。"
        return 1
    fi

    if [[ "$target" != /* ]]; then
        echo "请输入绝对路径，例如 /swapfile 或 /swap.img。"
        return 1
    fi

    if is_swap_active "$target"; then
        local swap_type
        swap_type="$(get_swap_type "$target")"

        if [[ "$swap_type" != "file" ]]; then
            echo "拒绝删除：$target 不是普通swap文件，类型为 $swap_type。"
            echo "本脚本不会删除swap分区、zram或其他块设备。"
            return 1
        fi

        echo "正在禁用swap文件：$target"

        if ! run_priv swapoff "$target"; then
            echo "错误：swapoff $target 失败。"
            echo "可能是当前内存不足，无法把swap中的内容迁回内存。"
            return 1
        fi
    else
        echo "$target 当前不是启用状态。"
    fi

    remove_fstab_swap_entry "$target"

    if [[ -f "$target" ]]; then
        read -r -p "确认删除文件 $target ? 输入 yes 继续: " confirm

        if [[ "$confirm" != "yes" ]]; then
            echo "已取消删除。"
            return 0
        fi

        if ! run_priv rm -f "$target"; then
            echo "错误：删除 $target 失败。"
            return 1
        fi

        echo "已删除swap文件：$target"
    else
        echo "$target 文件不存在，无需删除。"
    fi

    free -h
    echo "--------------------------"
}

show_menu() {
    echo -e "\n请选择操作:"
    echo "1. 查看当前swap使用情况"
    echo "2. 创建并启用swap文件"
    echo "3. 修改swappiness值"
    echo "4. 禁用swap文件，不删除文件"
    echo "5. 删除现有swap文件"
    echo "6. 退出"
}

check_privilege

while true; do
    show_menu
    read -r -p "请输入选择 (1-6): " choice

    case "$choice" in
        1)
            check_swap
            ;;
        2)
            read -r -p "请输入要创建的swap文件大小，例如 512M、2G、4G: " swap_size
            create_swap "$swap_size"
            ;;
        3)
            read -r -p "请输入swappiness值，范围0到100: " swappiness_value
            set_swappiness "$swappiness_value"
            ;;
        4)
            disable_swap_file
            ;;
        5)
            delete_existing_swap_file
            ;;
        6)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择。"
            ;;
    esac
done
