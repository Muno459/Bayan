#!/bin/bash
# Download all word-by-word audio files from audio.qurancdn.com
# Usage: ./download_wbw_audio.sh [output_dir]
#
# Downloads ~77,000 MP3 files (~3.3GB total)
# Format: {surah}_{ayah}_{word}.mp3
# Source: https://audio.qurancdn.com/wbw/

OUTPUT_DIR="${1:-./wbw_audio}"
BASE_URL="https://audio.qurancdn.com/wbw"

# Verse counts per surah (1-indexed)
VERSE_COUNTS=(0 7 286 200 176 120 165 206 75 129 109 123 111 43 52 99 128 111 110 98 135 112 78 118 64 77 227 93 88 69 60 34 30 73 54 45 83 182 88 75 85 54 53 89 59 37 35 38 88 52 45 60 49 62 55 78 96 29 22 24 13 14 11 11 18 12 12 30 52 52 44 28 28 20 56 40 31 50 40 46 42 29 19 36 25 22 17 19 26 30 20 15 21 11 8 8 19 5 8 8 11 11 8 3 9 5 4 7 3 6 3 5 4 5 6)

mkdir -p "$OUTPUT_DIR"

TOTAL=0
DOWNLOADED=0
FAILED=0

echo "Starting download to $OUTPUT_DIR..."

for surah in $(seq 1 114); do
    verses=${VERSE_COUNTS[$surah]}
    surah_padded=$(printf "%03d" $surah)

    for ayah in $(seq 1 $verses); do
        ayah_padded=$(printf "%03d" $ayah)

        # Try up to 30 words per verse (most have fewer)
        for word in $(seq 1 30); do
            word_padded=$(printf "%03d" $word)
            filename="${surah_padded}_${ayah_padded}_${word_padded}.mp3"
            url="${BASE_URL}/${filename}"
            output_path="${OUTPUT_DIR}/${filename}"

            if [ -f "$output_path" ]; then
                TOTAL=$((TOTAL + 1))
                continue
            fi

            # Check if file exists on CDN
            status=$(curl -sI -o /dev/null -w "%{http_code}" "$url")

            if [ "$status" = "200" ]; then
                curl -s -o "$output_path" "$url"
                TOTAL=$((TOTAL + 1))
                DOWNLOADED=$((DOWNLOADED + 1))

                if [ $((DOWNLOADED % 100)) -eq 0 ]; then
                    echo "  Downloaded $DOWNLOADED files (surah $surah, ayah $ayah)..."
                fi
            else
                # No more words for this verse
                break
            fi
        done
    done

    echo "Surah $surah complete ($verses verses)"
done

echo ""
echo "Done! Total: $TOTAL files, Downloaded: $DOWNLOADED, Skipped (existing): $((TOTAL - DOWNLOADED))"
echo "Upload to R2: aws s3 sync $OUTPUT_DIR s3://bayan/wbw/ --endpoint-url https://f75282147e3ed4d03bd89b924efa0d4d.r2.cloudflarestorage.com"
