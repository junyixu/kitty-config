#!/usr/bin/bash
self="$(readlink -f "$0")"

# preview 子模式(不变)
if [[ $1 == --preview ]]; then
    for w in ${2//,/ }; do
        printf '\033[2m──── window id:%s ────\033[0m\n' "$w"
        txt=$(kitty @ get-text --ansi --match "id:$w")
        printf '%s\n' "$txt" | head -n 20
        printf '\033[0m\n'
    done
    exit 0
fi

# 来时的那个 tab(新 fzf tab 是 recent:0,原 tab 是 recent:1)
prev_tab=$(kitty @ ls --match-tab recent:1 2>/dev/null | jq -r '.[].tabs[].id')

kitty @ ls | jq -r --arg prev "$prev_tab" '
  .[].tabs[]
  | select(.is_focused == false)          # 排除当前 fzf tab
  | select((.id|tostring) != $prev)        # 排除来时的 tab
  | (.windows | map(.id | tostring) | join(",")) as $wids
  | "\(.id) \($wids) \(.title)"
' | fzf --ansi \
        --with-nth 3.. \
        --preview "'$self' --preview {2}" \
        --preview-window 'right:60%' \
        --bind 'enter:execute-silent(kitty @ focus-tab -m id:{1})+accept' \
        > /dev/null
