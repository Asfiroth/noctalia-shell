#!/bin/bash
set -euo pipefail

SCREEN_NAME=${1:-}
WALLPAPER_PATH=${2:-}

if [[ -z "$SCREEN_NAME" || -z "$WALLPAPER_PATH" ]]; then
  echo "Usage: $0 <screen> <wallpaper_path>" >&2
  exit 1
fi

# -----------------------------------------------------------
# Configuration and prerequisites
# -----------------------------------------------------------
SETTINGS_FILE="$HOME/.config/noctalia/settings.json"
HYPRPAPER_CONFIG_FILE=${HYPRPAPER_CONFIG:-"$HOME/.config/hypr/hyprpaper.conf"}

if ! command -v jq >/dev/null; then
  echo "Error: jq is required" >&2
  exit 1
fi

# -----------------------------------------------------------
# Read JSON configuration
# -----------------------------------------------------------
enabled=$(jq -r '.wallpaper.enabled' "$SETTINGS_FILE")
[[ "$enabled" == "true" ]] || { echo "Wallpaper disabled in settings.json"; exit 0; }

engine=$(jq -r '.wallpaper.engine // "hyprpaper"' "$SETTINGS_FILE")
default_wallpaper=$(jq -r '.wallpaper.defaultWallpaper' "$SETTINGS_FILE")
fill_mode=$(jq -r '.wallpaper.fillMode' "$SETTINGS_FILE")
fill_color=$(jq -r '.wallpaper.fillColor' "$SETTINGS_FILE")
transition_type=$(jq -r '.wallpaper.transitionType' "$SETTINGS_FILE")
duration_ms=$(jq -r '.wallpaper.transitionDuration' "$SETTINGS_FILE")
smoothness=$(jq -r '.wallpaper.transitionEdgeSmoothness' "$SETTINGS_FILE")

[[ "$default_wallpaper" == "null" ]] && default_wallpaper=""

if [[ ! -f "$WALLPAPER_PATH" ]]; then
  if [[ -n "$default_wallpaper" && -f "$default_wallpaper" ]]; then
    echo "Warning: wallpaper '$WALLPAPER_PATH' not found, using default '$default_wallpaper'" >&2
    WALLPAPER_PATH="$default_wallpaper"
  else
    echo "Error: wallpaper '$WALLPAPER_PATH' not found" >&2
    exit 1
  fi
fi

# convert duration from ms → s
duration=$(awk "BEGIN {print $duration_ms/1000}")

# -----------------------------------------------------------
# Helpers
# -----------------------------------------------------------
random_transition() {
  local types=("fade" "wipe" "grow" "outer" "wave" "left" "right" "top" "bottom" "center")
  echo "${types[$((RANDOM % ${#types[@]}))]}"
}

# Map legacy transition names to modern ones
case "$transition_type" in
  disc) transition_type="center" ;;
  stripes) transition_type="wave" ;;
esac

# Validate transition type
valid_transitions=("simple" "fade" "left" "right" "top" "bottom" "wipe" "grow" "center" "outer" "random" "wave")
if [[ ! " ${valid_transitions[*]} " =~ " $transition_type " ]]; then
  echo "Warning: invalid transition '${transition_type}', falling back to 'fade'"
  transition_type="fade"
fi

# Normalize color (# removed)
fill_color_clean="${fill_color#\#}"

# Convert smoothness float (0.05) to integer percentage (5)
if [[ "$smoothness" =~ ^0\.[0-9]+$ ]]; then
  smoothness=$(awk "BEGIN {print int($smoothness * 100)}")
fi

# -----------------------------------------------------------
# swww engine
# -----------------------------------------------------------
apply_with_swww() {
  local screen="$1"
  local wallpaper="$2"

  if ! command -v swww >/dev/null; then
    echo "Error: swww not installed" >&2
    exit 1
  fi

  WAYLAND_NS="${WAYLAND_DISPLAY:-wayland-1}"

  # Start GPU-safe daemon if not running
  if ! pgrep -x swww-daemon >/dev/null; then
    echo "Starting swww-daemon with GPU-safe flags (namespace: $WAYLAND_NS)..."
    export WLR_DRM_NO_ATOMIC=1
    swww-daemon --no-cache --namespace "$WAYLAND_NS" &
    sleep 1
  fi

  # Detect proper resize flag
  if swww img --help 2>&1 | grep -q -- '--resize'; then
    FILL_FLAG="--resize"
  else
    FILL_FLAG="--fill" # for older versions
  fi

  local transition_flag="$transition_type"
  case "$transition_type" in
    none) transition_flag="none" ;;
    random) transition_flag=$(random_transition) ;;
    *) transition_flag="$transition_type" ;;
  esac

  echo "Applying '$wallpaper' on '$screen' using swww (namespace: $WAYLAND_NS)"
  swww img "$wallpaper" \
    --namespace "$WAYLAND_NS" \
    --outputs "$screen" \
    "$FILL_FLAG" "$fill_mode" \
    --fill-color "$fill_color_clean" \
    --transition-type "$transition_flag" \
    --transition-duration "$duration" \
    --transition-fps 60 \
    --transition-step "$smoothness" \
    --transition-pos "0.5,0.5"
}

# -----------------------------------------------------------
# hyprpaper engine
# -----------------------------------------------------------
apply_with_hyprpaper() {
  local screen="$1"
  local wallpaper="$2"

  local tmp_file
  tmp_file=$(mktemp)
  trap '[[ -n "${tmp_file:-}" ]] && rm -f "${tmp_file}"' EXIT

  declare -a preserved_lines=()
  declare -a preload_lines=()
  declare -a wallpaper_lines=()
  declare -A seen_preload=()
  local screen_found=0

  if [[ -f "$HYPRPAPER_CONFIG_FILE" ]]; then
    while IFS= read -r line; do
      if [[ $line =~ ^[[:space:]]*preload[[:space:]]*= ]]; then
        local value=${line#*=}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        preload_lines+=("$line")
        [[ -n "$value" ]] && seen_preload["$value"]=1
      elif [[ $line =~ ^[[:space:]]*wallpaper[[:space:]]*= ]]; then
        local rest=${line#*=}
        rest=${rest#"${rest%%[![:space:]]*}"}
        local current_screen=${rest%%,*}
        current_screen=${current_screen#"${current_screen%%[![:space:]]*}"}
        current_screen=${current_screen%"${current_screen##*[![:space:]]}"}
        local current_path=${rest#*,}
        current_path=${current_path#"${current_path%%[![:space:]]*}"}
        current_path=${current_path%"${current_path##*[![:space:]]}"}

        if [[ "$current_screen" == "$screen" ]]; then
          screen_found=1
          continue
        fi

        wallpaper_lines+=("$line")
        [[ -n "$current_path" ]] && seen_preload["$current_path"]=1
      else
        preserved_lines+=("$line")
      fi
    done <"$HYPRPAPER_CONFIG_FILE"
  fi

  if [[ -z "${seen_preload[$wallpaper]+x}" ]]; then
    preload_lines+=("preload = $wallpaper")
  fi

  wallpaper_lines+=("wallpaper = $screen,$wallpaper")
  if [[ $screen_found -eq 0 ]]; then
    echo "Creating hyprpaper entry for '$screen'"
  fi

  {
    for line in "${preserved_lines[@]}"; do
      printf '%s\n' "$line"
    done
    for line in "${preload_lines[@]}"; do
      printf '%s\n' "$line"
    done
    for line in "${wallpaper_lines[@]}"; do
      printf '%s\n' "$line"
    done
  } >"$tmp_file"

  mkdir -p "$(dirname "$HYPRPAPER_CONFIG_FILE")"
  mv "$tmp_file" "$HYPRPAPER_CONFIG_FILE"
  trap - EXIT

  echo "Restarting hyprpaper with new configuration..."
  if pgrep -x hyprpaper >/dev/null; then
    pkill -x hyprpaper
  fi
  nohup hyprpaper >/dev/null 2>&1 &
}

# -----------------------------------------------------------
# Main selector — ensure only one engine active
# -----------------------------------------------------------
if [[ "$engine" != "swww" ]]; then
  if pgrep -x swww-daemon >/dev/null; then
    echo "Detected non-swww engine ('$engine'), stopping running swww-daemon..."
    pkill -x swww-daemon
    sleep 0.5
  fi
fi

case "$engine" in
  swww)
    echo "Using swww engine..."
    apply_with_swww "$SCREEN_NAME" "$WALLPAPER_PATH"
    ;;
  hyprpaper|*)
    echo "Using hyprpaper engine..."
    apply_with_hyprpaper "$SCREEN_NAME" "$WALLPAPER_PATH"
    ;;
esac
