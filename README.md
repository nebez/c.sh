# c-cli

![c-cli hero](assets/c-cli-hero.svg)

Use Codex to help you with CLI command translation. OpenAI-only, because Codex is the whole point.

```bash
$ c "directories ending in .log older than 10 days"

> find . -type d -name '*.log' -mtime +10
```

## Why

I've been using codex so much it's hard to imagine using any other tooling. I even disabled the AI features in my IDE and terminal (but I still use Codex in Zed through ACP). The one thing I missed was asking my terminal for help. So I brought that functionality back to my terminal using `codex`, a shell script, and an alias.

It's a thin wrapper around `codex exec` for command suggestions:

- asks Codex non-interactively
- auto-resumes the last thread in the same directory (within a time window)

I've tested this exclusively on `zsh`. It should work on `bash` too (including macOS versions).

## Requirements

- `codex` CLI in your `PATH`
- `bash`
- `jq` (required for parsing JSON output)

## Install

Just copy [`c.sh`](https://github.com/nebez/c-cli/blob/main/c.sh) somewhere to your liking and invoke it. If that's not enough for you, however, continue reading.

There are no one-line installation instructions and I don't intend on adding one. Open and inspect [`c.sh`](https://github.com/nebez/c-cli/blob/main/c.sh), decide if you like it, then copy+paste it somewhere on your computer. After you've done that, here are a few ways to install it assuming it exists at `/absolute/path/to/c.sh`.

### 1) Simple PATH install

```bash
install -m 0755 /absolute/path/to/c.sh ~/.local/bin/c
```

### 2) Home Manager / Nix

```nix
home.packages = [
  (pkgs.writeShellScriptBin "c" (builtins.readFile /absolute/path/to/c.sh))
  pkgs.jq
  # add the package that provides `codex` in your setup
];
```

### 3) `.bashrc` or `.zshrc`

Put this somewhere in your `~/.zshrc` or `~/.bashrc` file:

```bash
c() {
  bash /absolute/path/to/c.sh "$@"
}
```

## Options

```text
Usage: c [--new] [-v|-vv] <question...>

Options:
  --new                     force a new conversation
  -v, --verbose             show wrapper diagnostics
  -vv                       show full debug output
  -m, --model               model name (default: gpt-5.1-codex-mini)
  -w, --window              auto-resume window in seconds (default: 300)
  -r, --reasoning-effort    model reasoning effort (default: low)
```

Examples:

```bash
c "how do i list files over 100MB?"
c --new "find node processes and show full command lines"
echo "search recursively for TODO comments" | c
```
