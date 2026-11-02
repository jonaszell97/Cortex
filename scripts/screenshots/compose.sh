#!/bin/zsh
# Puts the raw renders of ReadmeScreenshots (CortexTests/Screenshots) on
# colourful wallpapers, as macOS would show them: the palette's frosted
# backdrop is the wallpaper behind it blurred and tinted, windows get rounded
# corners and a shadow. Writes docs/images/*.webp and docs/images/demo.gif.
#
#   scripts/screenshots/compose.sh <raw folder> <output folder>
#
# Needs ImageMagick 7 and ffmpeg (brew install imagemagick ffmpeg). Run by
# `make screenshots`; see docs/DEVELOPMENT.md, "Screenshots".
set -euo pipefail

raw=${1:?raw folder}
out=${2:?output folder}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# Final width of a screenshot in pixels (the renders are at 2x).
width=1400
# Space around the panel or window, in render pixels.
pad_x=170
pad_y=140

# A wallpaper: soft colour fields on a base colour, drawn small, blurred and
# scaled up so it stays smooth. Arguments: name, base colour, then four
# "colour x y radius" blobs in percent of the size.
wallpaper() {
  local name=$1 base=$2
  shift 2
  local draws=()
  for blob in "$@"; do
    local parts=(${=blob})
    draws+=(-fill "${parts[1]}" -draw "circle $((parts[2] * 3)),$((parts[3] * 2)) $((parts[2] * 3 + parts[4] * 3)),$((parts[3] * 2))")
  done
  magick -size 300x200 "xc:$base" "${draws[@]}" -blur 0x28 "$work/wallpaper-$name.png"
}

wallpaper sunset  '#2a1660' '#ff5f87 85 20 30' '#ffb347 95 95 28' '#7c5cff 10 85 35' '#ff7a59 45 105 22'
wallpaper ocean   '#0a2466' '#00c2ff 90 15 32' '#3a7bff 15 90 34' '#00e0b8 70 100 26' '#8a5cff 5 5 25'
wallpaper aurora  '#0d2238' '#2ee6a6 15 20 30' '#00b4d8 85 80 32' '#6c63ff 60 5 26' '#b6ff7a 5 95 18'
wallpaper peach   '#ff8f7e' '#ff5c8a 10 15 30' '#ffd29d 90 90 34' '#b46cf0 90 10 28' '#ffa36c 30 100 22'
wallpaper grape   '#3a0ca3' '#f72585 90 85 32' '#4361ee 10 10 34' '#4cc9f0 85 5 22' '#b5179e 15 95 26'
wallpaper citrus  '#ff7e5f' '#ffd452 15 10 34' '#ff4e88 90 90 30' '#7b5cff 95 10 26' '#ffb26b 40 100 22'
wallpaper lagoon  '#073b4c' '#06d6a0 90 20 30' '#118ab2 10 80 34' '#ffd166 95 100 18' '#7f5af0 5 5 22'

# A rounded-rectangle mask, white on black.
mask() { # width height radius file
  magick -size "$1x$2" xc:black -fill white -draw "roundrectangle 0,0 $(($1 - 1)),$(($2 - 1)) $3,$3" "$4"
}

# The palette on a wallpaper. Arguments: render, wallpaper, output.
palette() {
  local render=$1 paper=$2 output=$3
  local w h
  read w h <<< "$(magick identify -format '%w %h' "$render")"
  local cw=$((w + 2 * pad_x)) ch=$((h + 2 * pad_y))
  local tint='rgba(28,28,34,0.58)'
  [[ $render == *.light.png ]] && tint='rgba(246,246,250,0.55)'

  magick "$work/wallpaper-$paper.png" -resize "${cw}x${ch}!" "$work/bg.png"
  mask "$w" "$h" 52 "$work/mask.png"
  # The frosted backdrop: what is behind the panel, blurred and tinted.
  magick "$work/bg.png" -crop "${w}x${h}+${pad_x}+${pad_y}" +repage -resize 25% -blur 0x9 -resize "${w}x${h}!" -modulate 100,150 \
    \( -size "${w}x${h}" "xc:$tint" \) -composite \
    "$render" -composite \
    "$work/mask.png" -alpha off -compose CopyOpacity -composite "$work/pane.png"
  shadowed "$work/pane.png" "$work/mask.png" "$output"
}

# A window on a wallpaper: the content render under a title bar with the
# traffic lights, rounded corners and a light rim. Arguments: render,
# wallpaper, output, title.
window() {
  local render=$1 paper=$2 output=$3 title=$4
  local dark=0
  [[ $render == *.dark.* ]] && dark=1
  local bar_height=64 rim='rgba(0,0,0,0.12)' line='rgba(0,0,0,0.08)' text='#3c3c3c'
  (( dark )) && { rim='rgba(255,255,255,0.16)'; line='rgba(0,0,0,0.6)'; text='#dedede'; }
  # The title bar takes the content's own background colour.
  local fill
  fill=$(magick "$render" -format '%[pixel:p{6,6}]' info:)
  local cw ch
  read cw ch <<< "$(magick identify -format '%w %h' "$render")"
  local w=$cw h=$((ch + bar_height))
  magick -size "${w}x${bar_height}" "xc:$fill" \
    -fill '#ff5f57' -draw 'circle 40,32 52,32' \
    -fill '#febc2e' -draw 'circle 80,32 92,32' \
    -fill '#28c840' -draw 'circle 120,32 132,32' \
    -font /System/Library/Fonts/SFNS.ttf -pointsize 26 -weight 600 -fill "$text" \
    -gravity center -annotate +0+0 "$title" \
    -gravity northwest -fill "$line" -draw "line 0,$((bar_height - 1)) $w,$((bar_height - 1))" \
    "$render" -append "$work/window.png"
  read w h <<< "$(magick identify -format '%w %h' "$work/window.png")"
  cw=$((w + 2 * pad_x)) ch=$((h + 2 * pad_y))
  magick "$work/wallpaper-$paper.png" -resize "${cw}x${ch}!" "$work/bg.png"
  mask "$w" "$h" 32 "$work/mask.png"
  magick "$work/window.png" -alpha off "$work/mask.png" -compose CopyOpacity -composite \
    \( -size "${w}x${h}" xc:none -fill none -stroke "$rim" -strokewidth 2 \
       -draw "roundrectangle 1,1 $((w - 2)),$((h - 2)) 31,31" \) -compose Over -composite "$work/pane.png"
  shadowed "$work/pane.png" "$work/mask.png" "$output"
}

# Puts a pane with a soft window shadow on bg.png, rounds the picture's
# corners and scales it to the final width.
shadowed() { # pane mask output
  local pane=$1 m=$2 output=$3
  magick "$m" -background black -alpha shape -fill black -colorize 100 \
    -channel A -evaluate multiply 0.55 +channel \
    -bordercolor none -border 120 -resize 25% -blur 0x8.5 -resize 400% "$work/shadow.png"
  local cw ch
  read cw ch <<< "$(magick identify -format '%w %h' "$work/bg.png")"
  mask "$cw" "$ch" 44 "$work/canvas-mask.png"
  magick "$work/bg.png" \
    "$work/shadow.png" -geometry "+$((pad_x - 120))+$((pad_y - 120 + 26))" -composite \
    "$pane" -geometry "+${pad_x}+${pad_y}" -composite \
    "$work/canvas-mask.png" -alpha off -compose CopyOpacity -composite \
    -filter Lanczos -resize "${width}x" -quality 90 -define webp:alpha-quality=100 "$output"
  echo "wrote $output"
}

cp "$raw/icon.png" "$out/icon.png"

# render, wallpaper, output. The README shows these.
palette "$raw/clipboard.dark.png" sunset "$out/clipboard.webp"
palette "$raw/snippets.light.png" peach "$out/snippets.webp"
palette "$raw/reading-list.dark.png" ocean "$out/reading-list.webp"
palette "$raw/knowledge.dark.png" aurora "$out/knowledge.webp"
palette "$raw/todos.light.png" lagoon "$out/todos.webp"
palette "$raw/actions.dark.png" grape "$out/actions.webp"
palette "$raw/commands.light.png" citrus "$out/commands.webp"
palette "$raw/ai.dark.png" sunset "$out/ai.webp"
palette "$raw/emoji.light.png" peach "$out/emoji.webp"
palette "$raw/symbols.dark.png" lagoon "$out/symbols.webp"
palette "$raw/calculator.dark.png" grape "$out/calculator.webp"
palette "$raw/color.light.png" citrus "$out/color.webp"
palette "$raw/text-recognition.dark.png" aurora "$out/text-recognition.webp"
window "$raw/settings-sync.dark.window.png" ocean "$out/sync.webp" "Cortex Settings"
window "$raw/settings-scrolling.dark.window.png" sunset "$out/scrolling.webp" "Cortex Settings"

# The demo GIF: every frame on the same wallpaper, narrower than the
# screenshots to keep the file small. SKIP_GIF=1 leaves it as it is.
if [[ -f "$raw/gif/frames.txt" && -z ${SKIP_GIF:-} ]]; then
  local_width=$width
  width=800
  : > "$work/concat.txt"
  index=0
  while read -r file seconds; do
    frame="$work/frame-$(printf %04d $index).png"
    palette "$raw/$file" grape "$frame" > /dev/null
    print "file '$frame'\nduration $seconds" >> "$work/concat.txt"
    last=$frame
    index=$((index + 1))
  done < "$raw/gif/frames.txt"
  # The concat demuxer ignores the last duration unless the frame repeats.
  print "file '$last'" >> "$work/concat.txt"
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$work/concat.txt" \
    -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
    -loop 0 "$out/demo.gif"
  echo "wrote $out/demo.gif"
  width=$local_width
fi
