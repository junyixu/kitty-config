#!/usr/bin/env bash
fzf --with-nth 2.. --bind 'enter:execute-silent(kitty @ focus-tab -m id:{1})+accept' > /dev/null \
    <<<$(kitty @ ls | jq -r '.[] | .tabs[] | select(.is_focused == false) | (.id|tostring) + " " + .title')
