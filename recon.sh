#!/bin/bash


# 脚本配置: 任何命令失败时，脚本立即退出
set -e

# --- 可配置参数（可通过环境变量覆盖） ---
: ${HTTPX_THREADS:=50}          # httpx并发线程数
: ${HTTPX_TIMEOUT:=10}          # 超时时间（秒）
: ${HTTPX_RETRIES:=2}           # 重试次数
: ${MAX_PARALLEL_JOBS:=2}       # 最大并行任务数
: ${TEMP_FILE_PREFIX:="recon_${RANDOM}"}  # 临时文件前缀

# --- 1. 参数检查 ---
if [ "$#" -ne 2 ]; then
    echo "用法: $0 <domain.com> <output_file.txt>"
    echo "示例: $0 iflytek.com iflytek_results.txt"
    echo ""
    echo "可选环境变量:"
    echo "  HTTPX_THREADS      httpx并发数 (默认: 50)"
    echo "  HTTPX_TIMEOUT      超时时间(秒) (默认: 10)"
    echo "  HTTPX_RETRIES      重试次数 (默认: 2)"
    echo "  MAX_PARALLEL_JOBS  最大并行任务数 (默认: 2)"
    exit 1
fi

DOMAIN=$1
OUTPUT_FILE=$2

# --- 2. 依赖检查 ---
echo "[*] 检查所需工具是否已安装..."
TOOLS=("subfinder" "assetfinder" "httpx")
MISSING_TOOLS=0
for tool in "${TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "[-] 错误: '$tool' 未安装或不在你的 PATH 中。"
        MISSING_TOOLS=1
    fi
done

if [ $MISSING_TOOLS -eq 1 ]; then
    echo ""
    echo "安装建议:"
    echo "  subfinder:  go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    echo "  assetfinder: go install -v github.com/tomnomnom/assetfinder@latest"
    echo "  httpx:       go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest"
    exit 1
fi
echo "[✓] 所有工具检查通过。"

# --- 3. 定义文件名 ---
SUBFINDER_OUT="${TEMP_FILE_PREFIX}_subfinder.tmp"
ASSETFINDER_OUT="${TEMP_FILE_PREFIX}_assetfinder.tmp"
DOMAINS_OUT="${TEMP_FILE_PREFIX}_domains.tmp"
STATUS_OUT="$OUTPUT_FILE"

# --- 4. 设置信号处理（确保清理临时文件） ---
cleanup() {
    echo "[*] 收到退出信号，清理临时文件..."
    rm -f "$SUBFINDER_OUT" "$ASSETFINDER_OUT" "$DOMAINS_OUT" 2>/dev/null
    echo "[✓] 临时文件已清理。"
    exit 0
}

# 捕获退出信号
trap cleanup EXIT INT TERM

# --- 5. 步骤 1: 子域名发现 (并行执行) ---
echo ""
echo "[*] 步骤 1/3: 并行发现子域名..."
echo "    - 使用 subfinder..."
subfinder -d "$DOMAIN" -all -silent > "$SUBFINDER_OUT" &
SUBFINDER_PID=$!

echo "    - 使用 assetfinder..."
assetfinder "$DOMAIN" -subs-only > "$ASSETFINDER_OUT" &
ASSETFINDER_PID=$!

# 等待所有并行任务完成
wait $SUBFINDER_PID $ASSETFINDER_PID
echo "[✓] 子域名发现完成。"

# 检查子域名发现结果
if [ ! -s "$SUBFINDER_OUT" ] && [ ! -s "$ASSETFINDER_OUT" ]; then
    echo "[-] 错误: 未发现任何子域名，请检查域名输入。"
    exit 1
fi

# --- 6. 步骤 2: 合并和去重 ---
echo ""
echo "[*] 步骤 2/3: 合并和去重子域名..."
# 更高效的去重方式：先使用cat合并，再sort去重
cat "$SUBFINDER_OUT" "$ASSETFINDER_OUT" 2>/dev/null | sort -u > "$DOMAINS_OUT"
SUBDOMAIN_COUNT=$(wc -l < "$DOMAINS_OUT" 2>/dev/null || echo "0")

if [ "$SUBDOMAIN_COUNT" -eq 0 ]; then
    echo "[-] 错误: 去重后未发现任何子域名。"
    exit 1
fi

echo "[✓] 合并完成。共找到 $SUBDOMAIN_COUNT 个唯一子域名。"

# --- 7. 步骤 3: 存活探测和技术识别 ---
echo ""
echo "[*] 步骤 3/3: 使用 httpx 探测存活域名..."
echo "    - 并发数: $HTTPX_THREADS"
echo "    - 超时: ${HTTPX_TIMEOUT}秒"
echo "    - 重试: ${HTTPX_RETRIES}次"
echo "    - 请稍候，这可能需要一些时间..."

# 优化httpx参数：
# -threads: 控制并发数
# -timeout: 请求超时
# -retries: 重试次数
# -no-color: 无颜色输出以便保存到文件
# -follow-redirects: 跟随重定向
# -random-agent: 使用随机User-Agent
# -status-code: 显示状态码
# -content-length: 显示内容长度
# -title: 获取页面标题
# -web-server: 获取Web服务器信息
# -tech-detect: 技术栈检测
# -rate-limit: 限制请求速率（每分钟）
# -silent: 安静模式
cat "$DOMAINS_OUT" | httpx \
  -threads "$HTTPX_THREADS" \
  -timeout "$HTTPX_TIMEOUT" \
  -retries "$HTTPX_RETRIES" \
  -no-color \
  -follow-redirects \
  -random-agent \
  -status-code \
  -content-length \
  -title \
  -web-server \
  -tech-detect \
  -rate-limit 300 \
  -silent \
  -o "$STATUS_OUT"

# 检查httpx输出
if [ ! -f "$STATUS_OUT" ] || [ ! -s "$STATUS_OUT" ]; then
    echo "[-] 警告: httpx未输出任何存活域名。"
    ALIVE_COUNT=0
else
    ALIVE_COUNT=$(wc -l < "$STATUS_OUT" 2>/dev/null || echo "0")
    echo "[✓] 存活探测完成。共发现 $ALIVE_COUNT 个存活域名。"
    
    # 显示一些统计信息
    if [ "$ALIVE_COUNT" -gt 0 ] && [ "$ALIVE_COUNT" -lt 10 ]; then
        echo ""
        echo "存活域名预览:"
        head -5 "$STATUS_OUT" | awk '{print "    - " $0}'
    fi
fi

# --- 8. 清理中间文件 ---
echo ""
echo "[*] 清理中间文件..."
rm -f "$SUBFINDER_OUT" "$ASSETFINDER_OUT" "$DOMAINS_OUT" 2>/dev/null

# --- 9. 完成和总结 ---
echo ""
echo "======================================"
echo "[✓] 任务完成！"
echo ""
echo "统计信息:"
echo "    - 发现的子域名: $SUBDOMAIN_COUNT"
echo "    - 存活的域名: $ALIVE_COUNT"
if [ "$ALIVE_COUNT" -gt 0 ]; then
    echo "    - 存活率: $((ALIVE_COUNT * 100 / SUBDOMAIN_COUNT))%"
fi
echo ""
echo "输出文件:"
echo "    $(pwd)/$STATUS_OUT"
echo ""
echo "文件内容格式:"
echo "    域名 [状态码] [长度] [标题] [服务器] [技术栈]"
echo ""
echo "可选: 查看结果前10行 - head -10 $STATUS_OUT"
echo "======================================"
echo ""
