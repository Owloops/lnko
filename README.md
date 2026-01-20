<div align="center">

<img src="assets/lnko.svg" alt="lnko logo" width="128"/>

# lnko

Simple stow-like dotfile linker.

<p align="center">
  <img src="assets/demo.gif" alt="lnko demo" width="600"/>
</p>

[![CI](https://github.com/luanvil/lnko/actions/workflows/ci.yml/badge.svg)](https://github.com/luanvil/lnko/actions/workflows/ci.yml)
[![LuaRocks](https://img.shields.io/luarocks/v/luanvil/lnko?color=1e3a8a)](https://luarocks.org/modules/luanvil/lnko)
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
curl -fsSL https://raw.githubusercontent.com/luanvil/lnko/main/install.sh | bash
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

| Option | Description |
|--------|-------------|
| `-d, --dir <dir>` | Source directory containing packages (default: cwd) |
| `-t, --target <dir>` | Target directory (default: $HOME) |
| `-n, --dry-run` | Show what would be done |
| `-v, --verbose` | Show debug output |
| `-b, --backup` | Auto-backup conflicts to `<target>/.lnko-backup/` |
| `-s, --skip` | Auto-skip conflicts |
| `-f, --force` | Auto-overwrite conflicts (dangerous) |
| `--ignore <pattern>` | Ignore files matching pattern (can be repeated) |
| `--no-folding` | Don't fold directories into symlinks |
| `--remove-orphans` | Auto-remove orphan symlinks (for `clean` command) |
| `--keep-orphans` | Auto-keep orphan symlinks (for `clean` command) |

### Conflict Handling

When lnko encounters existing files, it prompts for action:

- **[b]ackup** - Move existing file to `.lnko-backup/`
- **[s]kip** - Leave existing file, skip this link
- **[o]verwrite** - Replace existing file
- **[d]iff** - Show diff between source and target
- **[q]uit** - Abort operation

Use `-b`, `-s`, or `-f` flags to auto-resolve conflicts.

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
