# ===== 输出表格（按平均延迟排序后对齐显示）=====

# 先准备表头（用 TAB 分隔，方便 column 对齐）
HEADER=$'编号\t目标\t地区\tASN\t公司\t丢包\t最小(ms)\t平均(ms)\t最大(ms)\t抖动'

# 生成主体数据（仍然先按平均值排序；然后把百分号等格式化好，整行用 TAB 连接）
BODY=$(
  printf '%b\n' "${RESULTS[@]}" \
  | LC_ALL=C sort -t$'\t' -k1,1n \
  | cut -f2- \
  | while IFS=$'\t' read -r idx0 ip region asn company loss min avg max mdev; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$idx0" "$ip" "$region" "$asn" "$company" \
        "$(printf '%.1f%%' "${loss:-0}")" \
        "${min:-N/A}" "${avg:-N/A}" "${max:-N/A}" "${mdev:-N/A}"
    done
)

# 如果系统有 column（util-linux），用它来对齐；否则回退到定宽 printf
if command -v column >/dev/null 2>&1; then
  { printf '%s\n' "$HEADER"; printf '%s\n' "$BODY"; } | column -t -s $'\t'
else
  # 回退：定宽打印（可能略有偏移，但保证可读）
  printf "%-4s %-39s %-18s %-8s %-28s %-6s %-9s %-9s %-9s %-7s\n" \
    "编号" "目标" "地区" "ASN" "公司" "丢包" "最小(ms)" "平均(ms)" "最大(ms)" "抖动"
  printf -- "-----------------------------------------------------------------------------------------------\n"
  printf '%b\n' "${RESULTS[@]}" \
  | LC_ALL=C sort -t$'\t' -k1,1n \
  | cut -f2- \
  | while IFS=$'\t' read -r idx0 ip region asn company loss min avg max mdev; do
      printf "%-4s %-39s %-18s %-8s %-28s %-6s %-9s %-9s %-9s %-7s\n" \
        "$idx0" "$ip" "$region" "$asn" "$company" \
        "$(printf '%.1f%%' "${loss:-0}")" \
        "${min:-N/A}" "${avg:-N/A}" "${max:-N/A}" "${mdev:-N/A}"
    done
fi
