#!/usr/bin/env bash
# 下载 /var/www/Example/ 下的 Baltic / Native American 媒体文件
# 需要 yt-dlp（视频）和 curl（音频）
# 仅 ltu/ 和 lu/ 版本的 HTML 模板需要这些媒体文件；
# 主 EU 模板（fake-site-eu.html）使用用户粘贴 URL 的播放器，无需本地文件。
set -euo pipefail

DEST="${1:-/var/www/Example}"
mkdir -p "$DEST"

check_yt_dlp() {
    if ! command -v yt-dlp >/dev/null 2>&1; then
        echo "[ERROR] yt-dlp 未安装，无法下载视频文件"
        echo "        安装: pip install yt-dlp  或  curl -Lo /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp && chmod +x /usr/local/bin/yt-dlp"
        return 1
    fi
}

echo "== 下载 Baltic 视频（MP4）到 ${DEST}/ =="
if check_yt_dlp; then
    yt-dlp -o "${DEST}/%(title)s_%(height)sp.%(ext)s" \
        --format "bestvideo[ext=mp4][height<=1080]+bestaudio[ext=m4a]/best[ext=mp4][height<=1080]" \
        --merge-output-format mp4 \
        "https://www.youtube.com/watch?v=FLHdtmDMmJU" \
        "https://www.youtube.com/watch?v=YHtHhtFNHEg" \
        "https://www.youtube.com/watch?v=peMFXq9WQEQ" \
        "https://www.youtube.com/watch?v=5rMZQ3lWa8A" \
        || echo "[WARN] 部分视频下载失败，请手动检查"
fi

echo ""
echo "== 下载 Baltic 小型 MP3（Free Music Archive）到 ${DEST}/ =="
# Captain Sleepy - Native American Ambient (FMA 公开授权)
declare -A FMA_TRACKS=(
    ["captain_sleepy-beneath-the-buffalo-sky-ambient-native-american-music-285414.mp3"]="https://freemusicarchive.org/music/download/285414"
    ["captain_sleepy-wolf-moon-rising-ambient-native-american-music-285412.mp3"]="https://freemusicarchive.org/music/download/285412"
    ["captain_sleepy-spirit-of-the-wind-ambient-native-american-music-285418.mp3"]="https://freemusicarchive.org/music/download/285418"
    ["captain_sleepy-sacred-earth-dreams-ambient-native-american-music-285420.mp3"]="https://freemusicarchive.org/music/download/285420"
    ["luminouspresence-a-tribute-to-native-americans-212272.mp3"]="https://freemusicarchive.org/music/download/212272"
)
for fname in "${!FMA_TRACKS[@]}"; do
    out="${DEST}/${fname}"
    if [[ -f "$out" ]]; then
        echo "[SKIP] 已存在: $fname"
        continue
    fi
    url="${FMA_TRACKS[$fname]}"
    echo "[GET]  $fname"
    curl -fL --retry 3 --retry-delay 2 -o "$out" "$url" 2>/dev/null \
        || echo "[WARN] 下载失败: $fname  →  $url"
done

echo ""
echo "== 下载 Baltic 民谣 MP3（YouTube 音频提取）到 ${DEST}/ =="
if check_yt_dlp 2>/dev/null; then
    # Ensemble Rasa - Sajāja Brammaņi (Latvian)
    yt-dlp -o "${DEST}/Ensemble Rasa - Sajāja Brammaņi_MP3.%(ext)s" \
        --format "bestaudio[ext=m4a]/bestaudio" \
        --extract-audio --audio-format mp3 --audio-quality 192K \
        "https://www.youtube.com/watch?v=J0Q3e7g6Ldk" \
        || echo "[WARN] Ensemble Rasa 下载失败"

    # Lithuanian ancient folk song - Už ežero ugnys dega
    yt-dlp -o "${DEST}/Lithuanian ancient folk song (Už ežero ugnys dega) by Liucė_MP3.%(ext)s" \
        --format "bestaudio[ext=m4a]/bestaudio" \
        --extract-audio --audio-format mp3 --audio-quality 192K \
        "https://www.youtube.com/watch?v=N_D0EJ5lJTc" \
        || echo "[WARN] Liucė folk song 下载失败"
fi

echo ""
echo "完成。文件已写入: ${DEST}/"
echo "ltu/ 模板所需: uz-ezero-ugnys-dega.mp3, kanteles-sutartine.mp4, baltics-waking-up.mp4"
echo "lu/  模板所需: sajaja-brammani.mp3, jura-gaju-naudas-guti.mp4, rikaz-randa-livonian.mp4"
echo ""
echo "注意：ltu/lu HTML 模板引用的是短名称（如 uz-ezero-ugnys-dega.mp3），"
echo "      下载后需在对应 webroot 目录创建符号链接或重命名。"
