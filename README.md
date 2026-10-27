<div align="center">

<img src="assets/lnko.svg" alt="lnko logo" width="128"/>

# lnko

Simple stow-like dotfile linker.

<p align="center">
  <img src="assets/demo.gif" alt="lnko demo" width="600"/>
</p>

[![CI](https://github.com/Owloops/lnko/actions/workflows/ci.yml/badge.svg)](https://github.com/Owloops/lnko/actions/workflows/ci.yml)
[![LuaRocks](https://img.shields.io/luarocks/v/owloops/lnko?color=1e3a8a)](https://luarocks.org/modules/owloops/lnko)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-000080)](LICENSE)

</div>

## Features

<table>
<tr>
<td width="50%">

**Conflict handling**

Interactive prompt with backup, skip, overwrite, and diff options when files already exist.

</td>
<td width="50%">

**Orphan cleanup**

`lnko clean` removes stale symlinks pointing to non-existent targets.

</td>
</tr>
<tr>
<td width="50%">

**Stow-compatible**

Works with existing GNU Stow symlinks. Supports tree folding for cleaner directory structures.

</td>
<td width="50%">

**Relative symlinks**

Portable across machines. Symlinks use relative paths, not absolute.

</td>
</tr>
</table>

## Installation

### Standalone binary (recommended)

Downloads a self-contained binary with no dependencies:

```bash
curl -fsSL https://raw.githubusercontent.com/Owloops/lnko/main/install.sh | bash
```

### LuaRocks

Installs as a Lua module (requires Lua and LuaFileSystem):

```bash
luarocks --local install lnko
```

## Usage

```bash
# Link packages from current directory to $HOME
lnko link bash git nvim

# Specify source and target directories
lnko link -d ~/dotfiles/config -t ~ bash git nvim

# Unlink packages
lnko unlink bash

# Show status of all packages
lnko status

# Remove orphan symlinks
lnko clean
```

### Options

Options are scoped per command (`--backup` applies to `link`, `--json` to `status`, etc.). Run `lnko <command> --help` to see the exact set. Unknown options are rejected with a suggestion.

| Option | Commands | Description |
|--------|----------|-------------|
| `-d, --dir <dir>` | all | Source directory containing packages (default: cwd) |
| `-t, --target <dir>` | all | Target directory (default: $HOME) |
| `-n, --dry-run` | link, unlink, clean | Show what would be done |
| `-v, --verbose` | all | Show debug output |
| `-b, --backup` | link | Auto-backup conflicts to `<target>/.lnko-backup/` |
| `-s, --skip` | link | Auto-skip conflicts |
| `-f, --force` | link | Auto-overwrite conflicts (dangerous) |
| `--ignore <glob>` | link | Ignore files matching glob (can be repeated; use `/` for path-scoped globs, basename otherwise) |
| `--no-folding` | link | Don't fold directories into symlinks |
| `--json` | status | Output JSON |
| `--remove-orphans` | clean | Auto-remove orphan symlinks |
| `--keep-orphans` | clean | Auto-keep orphan symlinks |
| `-h, --help` | all | Show help |
| `--version` | all | Show version |

### Config File

An optional `.lnkorc` in the source directory provides defaults so you don't repeat flags. It's a Lua file returning a table:

```lua
return {
  dir = "~/dotfiles/config",
  target = "~",
  ignore = { ".git", "*.swp" },
  packages = os.getenv("TERMUX_VERSION")
      and { "bash", "git", "termux", "nvim" }
      or { "bash", "git", "fedora", "nvim", "tmux" },
}
```

- Keys map to options: `dir`, `target`, `ignore`, `no_folding`, and `packages` (defaults for a bare `lnko link`).
- Explicit command-line flags always win over config values.
- The file is executable Lua, so per-host logic (like the `TERMUX_VERSION` check above) lives in the config, not in lnko.
- Override the location with `--config <file>` or the `LNKO_CONFIG` environment variable.

### Conflict Handling

When lnko encounters existing files, it prompts for action:

- **[b]ackup** - Move existing file to `.lnko-backup/`
- **[s]kip** - Leave existing file, skip this link
- **[o]verwrite** - Replace existing file
- **[d]iff** - Show diff between source and target
- **[q]uit** - Abort operation

Use `-b`, `-s`, or `-f` flags to auto-resolve conflicts.

### Status

`lnko status` classifies each package into one state:

| Status | Meaning |
|--------|---------|
| `ok` | every package path is linked |
| `partial` | some paths linked, some missing |
| `occupied` | no paths linked here; existing symlinks are owned by sibling packages from the same source dir |
| `not linked` | nothing linked and targets missing |
| `conflict` | a path is a real file or a symlink pointing outside the source dir |

Multi-host setups typically show host packages (e.g. `fedora`, `termux`) as `occupied` on other machines.

Use `lnko status --json` for machine-readable output:

```json
[{"package":"termux","status":"occupied","total":2,"linked":0,"missing":0,"occupied":2,"conflict":0}]
```

## How It Works

lnko creates relative symlinks from a source directory (containing "packages") to a target directory. Each package is a directory whose contents mirror the target structure.

```
dotfiles/
  bash/
    .bashrc
    .bash_profile
  git/
    .gitconfig
```

Running `lnko link -d dotfiles -t ~ bash git` creates:

```
~/.bashrc -> ../dotfiles/bash/.bashrc
~/.bash_profile -> ../dotfiles/bash/.bash_profile
~/.gitconfig -> ../dotfiles/git/.gitconfig
```

## Example

See [pgagnidze/dotfiles](https://github.com/pgagnidze/dotfiles) for a real-world example using lnko.

## Comparison with GNU Stow

Both use relative symlinks, tree folding, ignore patterns, and dry-run mode. lnko adds:

| Feature | Description |
|---------|-------------|
| Interactive conflicts | Prompt with backup, skip, overwrite, diff |
| Orphan cleanup | Find and remove broken symlinks |
| Status command | See state of all packages |

See [GNU Stow documentation](https://www.gnu.org/software/stow/manual/) for additional Stow features.

## Development

```bash
# Run from source
./bin/lnko.lua --help

# Run linter
luacheck lnko/ bin/ spec/

# Run tests
busted spec/
```

## License

[GPL-3.0](LICENSE)
