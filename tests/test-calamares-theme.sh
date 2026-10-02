#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$project_dir/out/calamares-theme}"
mkdir -p "$output_dir"
output_dir="$(realpath -- "$output_dir")"
python3 "$project_dir/scripts/render-calamares-theme.py" --check
python3 "$project_dir/tests/test-calamares-theme.py"
cmake -S "$project_dir/tests/calamares-theme" -B "$output_dir/build" -G Ninja
cmake --build "$output_dir/build" --parallel 2
for variant in dark light; do
  for motion in normal reduced; do
    theme_dir="$output_dir/$variant-$motion"
    options=()
    if [[ "$motion" == reduced ]]; then options+=(--reduced-motion); fi
    python3 "$project_dir/scripts/render-calamares-theme.py" --output "$theme_dir" --variant "$variant" "${options[@]}"
    for scale in 1 1.25 1.5 2; do
      capture_dir="$theme_dir/scale-$scale"
      mkdir -p "$capture_dir"
      QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_STYLE_OVERRIDE=Fusion QT_QUICK_BACKEND=software QT_SCALE_FACTOR="$scale" \
        DEVARIO_THEME_DIR="$theme_dir" DEVARIO_THEME_CAPTURES="$capture_dir" \
        "$output_dir/build/pearl-theme-check" -o "$capture_dir/results.txt",txt
    done
  done
done
