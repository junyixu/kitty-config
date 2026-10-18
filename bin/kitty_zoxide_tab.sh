#!/usr/bin/zsh
# Kitty 新 Tab: 使用 zoxide + fzf 选择目录并直接在当前这个新 Tab 中进入
# - Enter : 在当前新 Tab 中 cd 到该目录并启动 zsh
# - Alt-a : 在当前新 Tab 中 cd 到该目录并直接进入 `zmx attach <目录名>` (detach 后留在当前目录的 zsh)
# - Esc   : 取消时自动关闭这个新 Tab

export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:$PATH"
[[ -f ~/.config/zsh/zshrc.d/44-fzf-options.zsh ]] && source ~/.config/zsh/zshrc.d/44-fzf-options.zsh

local out key dir name
local -a lines

out=$(zoxide query -l 2>/dev/null | fzf \
  --ansi \
  --expect=alt-a \
  --prompt="zoxide> " \
  --header=$'enter:cd & zsh  M-a:cd & zmx attach' \
  --preview='eza -1 --color=always --icons {} 2>/dev/null || ls -la --color=always {}' \
  --preview-window='right:55%') || exit 0

lines=("${(@f)out}")
key=${lines[1]}
dir=${lines[2]}
[[ -z $dir ]] && exit 0

builtin cd -- "$dir" || exit 1
zoxide add "$dir" 2>/dev/null || true
name=${dir:t}

if [[ $key == "alt-a" ]]; then
  exec zsh -ic "zmx attach ${(q)name}; exec zsh"
else
  exec zsh
fi
