#!/bin/bash
# Download ALL word-by-word audio for all 114 surahs, zip, upload to R2
# Usage: ./download_and_upload_all.sh

set -e

WORK_DIR="/tmp/bayan_wbw"
R2_ENDPOINT="https://f75282147e3ed4d03bd89b924efa0d4d.r2.cloudflarestorage.com"
R2_BUCKET="bayan"
CDN_BASE="https://audio.qurancdn.com/wbw"

export AWS_ACCESS_KEY_ID="8bda012c0e31aa327eafe740e7722f3a"
export AWS_SECRET_ACCESS_KEY="1758547a89d7f663b7b9b553bd22291cb9a1dd1cfcf76195d9a41fe9444ef88c"

# Verse counts per surah
VERSES=(0 7 286 200 176 120 165 206 75 129 109 123 111 43 52 99 128 111 110 98 135 112 78 118 64 77 227 93 88 69 60 34 30 73 54 45 83 182 88 75 85 54 53 89 59 37 35 38 88 52 45 60 49 62 55 78 96 29 22 24 13 14 11 11 18 12 12 30 52 52 44 28 28 20 56 40 31 50 40 46 42 29 19 36 25 22 17 19 26 30 20 15 21 11 8 8 19 5 8 8 11 11 8 3 9 5 4 7 3 6 3 5 4 5 6)

mkdir -p "$WORK_DIR"

total_words=0
total_surahs=0

for surah in $(seq 1 114); do
    surah_pad=$(printf "%03d" $surah)
    surah_dir="$WORK_DIR/$surah_pad"
    zip_file="$WORK_DIR/surah_${surah_pad}.zip"
    verses=${VERSES[$surah]}
    
    # Skip if already uploaded
    if aws s3 ls "s3://$R2_BUCKET/wbw/surah_${surah_pad}.zip" --endpoint-url "$R2_ENDPOINT" 2>/dev/null | grep -q "surah_"; then
        echo "[$surah/114] Already uploaded, skipping"
        total_surahs=$((total_surahs + 1))
        continue
    fi
    
    mkdir -p "$surah_dir"
    word_count=0
    
    for ayah in $(seq 1 $verses); do
        ayah_pad=$(printf "%03d" $ayah)
        for word in $(seq 1 30); do
            word_pad=$(printf "%03d" $word)
            f="${surah_pad}_${ayah_pad}_${word_pad}.mp3"
            
            if [ -f "$surah_dir/$f" ]; then
                word_count=$((word_count + 1))
                continue
            fi
            
            # Download (follow redirects, fail silently on 404)
            if curl -sf -o "$surah_dir/$f" "$CDN_BASE/$f" 2>/dev/null; then
                word_count=$((word_count + 1))
            else
                rm -f "$surah_dir/$f"
                break
            fi
        done
    done
    
    # Zip the surah
    if [ $word_count -gt 0 ]; then
        (cd "$surah_dir" && zip -j "$zip_file" *.mp3 > /dev/null 2>&1)
        zip_size=$(du -h "$zip_file" | cut -f1)
        
        # Upload to R2
        aws s3 cp "$zip_file" "s3://$R2_BUCKET/wbw/surah_${surah_pad}.zip" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "application/zip" \
            --quiet 2>/dev/null
        
        total_words=$((total_words + word_count))
        total_surahs=$((total_surahs + 1))
        echo "[$surah/114] ${VERSES[$surah]} ayahs, $word_count words, $zip_size uploaded"
        
        # Clean up extracted files to save disk
        rm -rf "$surah_dir"
    fi
done

echo ""
echo "Done! $total_surahs surahs, $total_words total words"
echo "R2 URL: https://pub-28e518d8beea4b8fb9791feeb4933ff9.r2.dev/wbw/surah_XXX.zip"
