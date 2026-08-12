# kitty session 文件笔记

针对 `save_as_session` 生成的 session 文件（尤其是走 `kitten ssh` 的远程 tab）踩过的坑。
行号对应 kitty 0.46.2（`/usr/lib/kitty/kitty/`）。

## 1. `kitty-unserialize-data={"id": N}` 是什么

保存时该窗口的 kitty window id，只作为**文件内的 key**，数值本身无意义。

`set_layout_state` 那串 JSON 用旧 window id 描述布局结构（`window_groups[].window_ids`、
`active_group_history`）。恢复时 kitty 用 `serialized_id` 建映射（`layout/base.py:221-226`）：

```python
def create_window_id_map_for_unserialize(all_windows):
    window_id_map = {}
    for w in all_windows:
        if w.serialized_id:
            window_id_map[w.serialized_id] = w.id   # 旧 id -> 新建窗口 id
    return window_id_map
```

要求：`{"id": N}` 必须和同 tab `set_layout_state` 里的 `"window_ids": [N]` 对得上。

### 删掉会怎样

`window_list.py:206-209` 开头直接卡掉：

```python
if set(window_id_map.values()) != set(self.id_map):
    return None      # -> unserialize() 返回 False -> 整条 set_layout_state 被丢弃
```

没有 id → 映射表为空 → 不相等 → **`set_layout_state` 整行失效**（`main_bias` 等不再应用）。
窗口照常启动，`kitten ssh` 不受影响。

单窗口 tab + `layout tall:bias=70;full_size=1` 的情况下，`set_layout_state` 本来就没额外贡献，
删了看不出区别。真要精简就把 `kitty-unserialize-data=` 和对应的 `set_layout_state` **成对删**，
只删一个会留下一条静默失效的行。

## 2. `The SSH kitten is meant for interactive use only, STDIN must be a terminal`

powerlevel10k instant prompt 造成的，本地、远端各有一层。

### 本地：不要用 `cmd_at_shell_startup` 形式

`save_as_session --use-foreground-process` 会把 ssh 命令存成：

```
launch 'kitty-unserialize-data={"id": 5, "cmd_at_shell_startup": ["/usr/bin/kitten", "ssh", ...]}'
```

这种形式下 kitty **不** exec `kitten ssh`，而是启动本地 zsh 并导出
`KITTY_SI_RUN_COMMAND_AT_STARTUP`（`child.py:325-332`），由 shell integration 在 precmd 里 eval
（`shell-integration/zsh/kitty-integration:354-357`）：

```zsh
if [[ -n "$krcs" ]]; then
    builtin eval "$krcs"
fi
```

而 p10k instant prompt 在 source 时就已经把 fd 0 换成 `/dev/null`
（`~/.cache/p10k-instant-prompt-$USER.zsh`）：

```zsh
exec {__p9k_fd_0}<&0 {__p9k_fd_1}>&1 {__p9k_fd_2}>&2 0<&$fd_null 1>$__p9k_instant_prompt_output
```

kitty 的 `_ksi_deferred_init` 在 `.zshrc` 之前注册，排在 p10k 的 precmd 前面 → eval 时 stdin 仍是
`/dev/null` → ssh kitten 撞 `kittens/ssh/main.go:872` 的 `!tty.IsTerminal(os.Stdin.Fd())`。

**修法**：session 里直接写命令，让 kitty 把窗口 pty 给 kitten：

```
launch 'kitty-unserialize-data={"id": 5}' /usr/bin/kitten ssh --kitten=cwd=/path benbr
```

### 远端：启动命令要自己接回 tty

远端 `benbr` 同样开着 p10k instant prompt，远端 shell integration eval
`KITTY_SI_RUN_COMMAND_AT_STARTUP` 时 fd 0 也是 `/dev/null`，于是 `nvi`、`zmx attach` 起不来。

**试过但无效**：在远端 `~/.zshrc` 末尾重排钩子

```zsh
precmd_functions=(${precmd_functions:#_ksi_deferred_init} _ksi_deferred_init)
```

实测重排确实生效（`_ksi_deferred_init` 已排到最后），但探针仍拿到 `stdin: /dev/null` ——
远端 p10k 是在 precmd 钩子**之后**才还原 fd 的。（本地 p10k 走 precmd 路径，同样的重排在本地有效。）

**有效修法**：`$krcs` 是被 `eval` 的，shell 重定向直接生效，在命令里把 tty 接回来：

```
'--kitten=env=KITTY_SI_RUN_COMMAND_AT_STARTUP=zmx attach claude-code < /dev/tty > /dev/tty 2>&1'
```

探针验证：`tty0: YES`、`stdin: /dev/tty`。

### 注意

再次 `save_as_session` 覆盖同一文件，会把上面两处手改**全部退回**成 kitty 的默认写法，需要重新改。
新增 tab 也一样是旧格式。

## 3. `new_window_with_cwd` 会把远端启动命令一起继承

在跑着 `nvi` 的 ssh 窗口里按 `kitty_mod+enter`，新窗口又是 `nvi` 而不是 zsh。

原因：对 ssh 窗口，`window.py:177 modify_argv_for_launch_with_cwd` 把整条 kitten ssh cmdline
**原样复制**，只替换 cwd 和 server args：

```python
argv[:] = ssh_kitten_cmdline          # 含 --kitten=env=KITTY_SI_RUN_COMMAND_AT_STARTUP=nvi ...
set_cwd_in_cmdline(reported_cwd, argv)
set_server_args_in_cmdline(server_args, argv, allocate_tty=not run_shell)
```

试过在命令里加 clone 判据 `[[ -z "$KITTY_IS_CLONE_LAUNCH" ]] && nvi ...`：**无效**，
探针显示远端两次都是 `clone=[] strat=[]`，kitty 的 clone 标记不会传到远端。

唯一能挡住的做法是给绑定加显式命令（`new_window_with_cwd zsh`）：`server_args` 非空 → 远端 bootstrap
不走 `exec_login_shell`，改走带命令的分支。

### 为什么带命令就没有 shell integration

`shell-integration/ssh/bootstrap.sh` 末尾是两条互斥分支：

```sh
prepare_for_exec
# If a command was passed to SSH execute it here
EXEC_CMD          # 带命令时替换成: unset KITTY_SHELL_INTEGRATION; exec "$login_shell" -c 'zsh'
...
exec_login_shell  # 不带命令时走这里
```

integration 只在 `exec_login_shell` → `exec_zsh_with_integration`（`bootstrap-utils.sh:102-115`）里装配：

```sh
export KITTY_ORIG_ZDOTDIR="$zdotdir"
export ZDOTDIR="$shell_integration_dir/zsh"
exec "$login_shell" "-l"
```

带命令的分支既 unset 了 `KITTY_SHELL_INTEGRATION`、又不设 `ZDOTDIR`、还是 `-c` 而非 `-l`。
所以同时失去 integration **和** login shell。

### 实测对比（同一 ssh 窗口开出的两个新窗口）

|  | `new_window_with_cwd` | `new_window_with_cwd zsh` |
| --- | --- | --- |
| 窗口内容 | 继承 `nvi` | zsh |
| `[[ -o login ]]` | `Y` | `N` |
| `precmd_functions` 里 `_ksi` 个数 | `1` | `0` |
| `alias edit-in-kitty` | `Y` | `N` |
| `kitten @ get-text --extent=last_cmd_output` | 有输出 | 空 |
| 再按一次 `kitty_mod+enter` | 远端窗口 + 远端 cwd | **本地 `/bin/zsh`**，cwd 掉回本地 |
| 窗口标题 | 当前运行的命令 | grml 的 `user@host: ~/path` |

带 `zsh` 具体丢掉：

1. 链式开窗断在第二跳（OSC 7 不上报 → `modify_argv_for_launch_with_cwd` 拿不到 `reported_cwd`
   → 不走 ssh 分支 → 新窗口变本地 shell）。
2. OSC 133 prompt marks 全没：`show_last_command_output`、`scroll_to_prompt`、
   `get-text --extent=last_cmd_output|last_visited_cmd_output`、点击 prompt 定位光标。
3. `edit-in-kitty` alias 没了（远端文件用本地 kitty 编辑）。
4. `clone-in-kitty` 不可用。
5. `sudo` 的 TERMINFO 包装（`kitty-integration:405+`）没了 → `sudo nvim` 可能撞 terminfo 缺失。
6. 标题不再随当前命令更新。
7. 非 login shell → `/etc/zsh/zprofile`（会 `dsource /etc/zsh/zprofile.d`）不执行。

想用 `env KITTY_SHELL_INTEGRATION=enabled ZDOTDIR=...` 把 integration 补回来也失败：
`$HOME` 不展开，ZDOTDIR 变成字面量，掉回 grml prompt。不要走这条路。

### 结论

绑定保持 `map kitty_mod+enter new_window_with_cwd`（不带 `zsh`）。宁可新窗口继承 `nvi`，
也不丢上面 7 项。要干净的远端 shell，用 `ben: shell` 那个 tab，或在 nvi 里 `:q` 退回 zsh。

## 4. `ControlSocket ... already exists, disabling multiplexing`

良性，可忽略。

session 同时开多个到同一主机的窗口，ssh kitten 给每条连接加

```
-o ControlMaster=auto -o ControlPath=/run/user/1000/kssh-<kitty-pid>-%C -o ControlPersist=yes
```

多个 ssh 几乎同时启动 → 第一个建 socket，其余发现文件已存在但 master 尚未 accept → OpenSSH 打印该行
并退回独立连接。后果只是各自一条 TCP + 各自认证，启动稍慢。

想消掉：`~/.config/kitty/ssh.conf` 里

```
hostname benbr
share_connections no
```

复用也随之关闭；且 `forward_remote_control=yes` 依赖 ControlMaster，与之互斥。

## 5. 调试手法备忘

- 解析 session 文件而不真的开窗：

  ```bash
  kitty +runpy '
  from kitty.config import load_config
  from kitty.session import parse_session
  for s in parse_session(open("<file>").read(), load_config()):
      for t in s.tabs:
          for w in t.windows:
              print(t.name, w.serialized_id, w.launch_spec.args, w.run_command_at_shell_startup)
  '
  ```

- `--session` 传**绝对路径**。相对路径会被判成 `The startup session was invalid`，kitty 静默退回默认窗口。
- 无头测试：`kitty --start-as=minimized -o allow_remote_control=yes --listen-on unix:@tag --session <abs>`，
  再用 `kitten @ --to unix:@tag ls` / `get-text --match id:N` / `send-text` 观察。
- 查某条启动命令拿到的是不是 tty：把 `KITTY_SI_RUN_COMMAND_AT_STARTUP` 换成探针脚本，脚本里写
  `[ -t 0 ]` 和 `readlink /proc/self/fd/0` 到文件。
