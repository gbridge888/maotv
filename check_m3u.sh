#!/bin/bash

# 脚本功能：检测 M3U 文件，严格排除 MP4 fallback 链接
# 使用方法：./m3u_checker.sh input.m3u [output.m3u]

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示用法
usage() {
    echo "用法: $0 <输入m3u文件> [输出m3u文件]"
    echo "示例: $0 playlist.m3u playlist_clean.m3u"
    exit 1
}

# 检查依赖
check_dependencies() {
    local deps=("curl" "grep" "sed")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}错误: 未找到 $dep 命令${NC}"
            echo "请安装: sudo apt-get install $dep (Ubuntu/Debian) 或 sudo yum install $dep (RHEL/CentOS)"
            exit 1
        fi
    done
    
    # 检查ffprobe
    if command -v ffprobe &> /dev/null; then
        HAS_FFPROBE=1
    else
        HAS_FFPROBE=0
        echo -e "${YELLOW}警告: 未找到 ffprobe，将使用基础检测${NC}"
    fi
}

# 检测内容类型
check_content_type() {
    local url="$1"
    local content_type
    
    # 获取内容类型
    content_type=$(curl -L --max-time 10 --retry 1 --head \
                      -s -w "%{content_type}" -o /dev/null "$url" 2>/dev/null || echo "unknown")
    
    echo "$content_type"
}

# 使用 ffprobe 检测格式并排除MP4
check_with_ffprobe() {
    local url="$1"
    
    # 使用 ffprobe 检测格式信息
    local format_info
    format_info=$(timeout 15 ffprobe -v quiet -print_format json -show_format "$url" 2>/dev/null || echo "{}")
    
    # 检查是否是MP4格式
    if echo "$format_info" | grep -q "\"format_name\":.*mp4"; then
        echo -n "[MP4格式] "
        return 1
    fi
    
    # 检查文件名或URL中是否包含mp4
    if echo "$format_info" | grep -q "\"filename\":.*\.mp4"; then
        echo -n "[MP4文件] "
        return 1
    fi
    
    # 检查编解码器
    local codec_info
    codec_info=$(timeout 15 ffprobe -v quiet -print_format json -show_streams "$url" 2>/dev/null || echo "{}")
    
    # 如果主要是h264/aac且没有其他流媒体特征，可能是MP4
    if echo "$codec_info" | grep -q "\"codec_name\":\"h264\"" && \
       echo "$codec_info" | grep -q "\"codec_name\":\"aac\""; then
        echo -n "[H264/AAC 可能为MP4] "
        # 进一步检查是否是流媒体格式
        if echo "$format_info" | grep -q "\"format_name\":.*mpegts\|hls\|m3u8"; then
            echo -n "[但为流媒体格式] "
            return 0
        else
            return 1
        fi
    fi
    
    return 0
}

# 检查URL是否为有效的流媒体（严格排除MP4）
check_stream_url() {
    local url="$1"
    local http_code
    local content_type
    
    # 方法1: 检查HTTP状态码
    http_code=$(curl -L --max-time 10 --retry 1 \
                    -o /dev/null -s -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    
    # 如果状态码不是2xx/3xx，直接返回无效
    if [[ ! "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        echo -e "${RED}HTTP状态码无效: $http_code${NC}"
        return 1
    fi
    
    # 方法2: 通过URL模式检测MP4（最直接）
    local url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
    if [[ "$url_lower" =~ \.mp4($|\?|&) ]] || \
       [[ "$url_lower" =~ /mp4(/|$) ]] || \
       [[ "$url_lower" =~ format=mp4 ]] || \
       [[ "$url_lower" =~ type=mp4 ]]; then
        echo -e "${RED}URL包含MP4模式 - 排除${NC}"
        return 1
    fi
    
    # 方法3: 检查内容类型
    content_type=$(check_content_type "$url")
    echo -n "[类型: $content_type] "
    
    # 明确排除的MP4内容类型
    local excluded_types=(
        "video/mp4" "video/x-mp4" "video/quicktime" "application/mp4"
        "audio/mp4" "audio/x-mp4"
    )
    
    # 检查是否在排除列表中
    for excluded_type in "${excluded_types[@]}"; do
        if [[ "$content_type" == *"$excluded_type"* ]]; then
            echo -e "${RED}排除MP4类型: $content_type${NC}"
            return 1
        fi
    done
    
    # 有效的流媒体内容类型
    local valid_stream_types=(
        "video/mp2t" "application/vnd.apple.mpegurl" "application/x-mpegurl"
        "audio/mpegurl" "audio/mpeg" "video/mpeg" "application/octet-stream"
        "binary/octet-stream" "video/H264" "application/x-mpegURL"
        "video/MP2T" "application/x-mpegurl"
    )
    
    # 检查是否在有效列表中
    local type_valid=0
    for valid_type in "${valid_stream_types[@]}"; do
        if [[ "$content_type" == *"$valid_type"* ]]; then
            type_valid=1
            break
        fi
    done
    
    if [ $type_valid -eq 1 ]; then
        echo -e "${GREEN}有效流媒体类型${NC}"
        return 0
    fi
    
    # 方法4: 如果有ffprobe，进行深度格式检测
    if [ $HAS_FFPROBE -eq 1 ]; then
        echo -n "[ffprobe检测] "
        if check_with_ffprobe "$url"; then
            echo -e "${GREEN}非MP4流媒体有效${NC}"
            return 0
        else
            echo -e "${RED}检测为MP4格式 - 排除${NC}"
            return 1
        fi
    else
        # 方法5: 对于未知类型，保守策略 - 如果无法确定，排除
        if [[ "$content_type" == *"text/html"* || "$content_type" == *"text/plain"* ]]; then
            echo -e "${RED}内容类型无效 (可能是错误页面): $content_type${NC}"
            return 1
        elif [[ "$content_type" == "unknown" || -z "$content_type" ]]; then
            echo -e "${YELLOW}无法确定类型 - 保守排除${NC}"
            return 1
        else
            echo -e "${YELLOW}未知类型但非MP4 - 保留${NC}"
            return 0
        fi
    fi
}

# 主函数
main() {
    # 参数检查
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        usage
    fi

    local input_file="$1"
    local output_file="${2:-${input_file%.*}_clean.${input_file##*.}}"

    # 检查输入文件是否存在
    if [ ! -f "$input_file" ]; then
        echo -e "${RED}错误: 输入文件 '$input_file' 不存在${NC}"
        exit 1
    fi

    # 检查依赖
    check_dependencies

    # 检查M3U文件格式
    if ! head -n 1 "$input_file" | grep -q "^#EXTM3U"; then
        echo -e "${RED}错误: 文件 '$input_file' 不是有效的M3U格式${NC}"
        exit 1
    fi

    echo -e "${YELLOW}开始检测M3U文件: $input_file${NC}"
    echo -e "${YELLOW}输出文件: $output_file${NC}"
    echo -e "${BLUE}严格过滤模式: 排除所有MP4格式链接${NC}"
    echo -e "${BLUE}检测策略: URL模式 → 内容类型 → FFprobe格式检测${NC}"

    local total_channels=0
    local valid_channels=0
    local temp_file=$(mktemp)

    # 首先写入M3U头
    head -n 1 "$input_file" > "$temp_file"

    # 处理M3U文件
    while IFS= read -r line; do
        if [[ "$line" =~ ^#EXTINF ]]; then
            # 频道信息行
            extinf_line="$line"
            if read -r url_line; then
                total_channels=$((total_channels + 1))
                
                # 提取频道名称用于显示
                channel_name=$(echo "$extinf_line" | sed -n 's/.*,\(.*\)/\1/p')
                if [ -z "$channel_name" ]; then
                    channel_name="未知频道"
                fi
                
                # 显示短名称
                local display_name="${channel_name:0:30}"
                if [ ${#channel_name} -gt 30 ]; then
                    display_name="${display_name}..."
                fi
                
                echo -n "检测频道 $total_channels: $display_name ... "
                
                if check_stream_url "$url_line"; then
                    echo "$extinf_line" >> "$temp_file"
                    echo "$url_line" >> "$temp_file"
                    valid_channels=$((valid_channels + 1))
                else
                    echo -e "${RED}无效 - 已跳过${NC}"
                fi
            fi
        fi
    done < <(tail -n +2 "$input_file")

    # 创建输出文件
    mv "$temp_file" "$output_file"

    # 输出统计信息
    echo -e "\n${GREEN}检测完成!${NC}"
    echo -e "总频道数: $total_channels"
    echo -e "有效频道: ${GREEN}$valid_channels${NC}"
    echo -e "无效频道: ${RED}$((total_channels - valid_channels))${NC}"
    echo -e "清理后的文件: ${YELLOW}$output_file${NC}"
}

# 运行主函数
main "$@"
