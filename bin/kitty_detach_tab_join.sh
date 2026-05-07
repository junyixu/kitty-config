#! /bin/bash

# 获取当前 OS Window ID
current_os_window=$(kitty @ ls | jq -r '
	.[] | select(.tabs[] | .windows[] | .is_self == true) | .id
')

# 获取其他 OS Window 的 tabs
target_tab=$(kitty @ ls | jq -r --arg curr "$current_os_window" '
	.[] | select(.id != ($curr | tonumber)) | .tabs[] |
	"Tab \(.id) | \(.title)"
' | fzf --prompt="Select target tab to join: " --height=40% --reverse)

# 提取 tab id
if [[ -n "$target_tab" ]]; then
	tab_id=$(echo "$target_tab" | awk -F'|' '{print $1}' | awk '{print $2}')
	kitty @ detach-tab --target-tab "id:$tab_id"
fi
