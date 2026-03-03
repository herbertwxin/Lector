# Lector
A MacOS native academic PDF reader derived from Sioyek(https://github.com/ahrm/sioyek)

## Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15+

## Build
```bash
brew install xcodegen
xcodegen generate
open Lector.xcodeproj   # then ⌘B
```

---

## Keyboard Shortcuts

### Navigation
| Key | Action |
|-----|--------|
| `j` | Scroll down |
| `k` | Scroll up |
| `⌃d` | Scroll down (half page) |
| `⌃u` | Scroll up (half page) |
| `Space` | Next page |
| `Shift+Space` | Previous page |
| `gg` | Go to beginning |
| `G` | Go to end |
| `{n}gg` | Go to page n |
| `Backspace` | Navigate back |
| `Shift+Backspace` | Navigate forward |

### Zoom
| Key | Action |
|-----|--------|
| `+` | Zoom in |
| `-` | Zoom out |
| `=` | Fit to width |
| `0` | Actual size |

### Search
| Key | Action |
|-----|--------|
| `/` | Open search bar |
| `n` | Next result |
| `N` | Previous result |
| `Esc` | Close search |

### Bookmarks
| Key | Action |
|-----|--------|
| `b` | Add bookmark at current position |
| `db` | Delete bookmark at current position |
| `gb` | List bookmarks (current document) |
| `gB` | List bookmarks (all documents) |

### Highlights
| Key | Action |
|-----|--------|
| `h` + char | Highlight selection (`a` = yellow, `b` = green, `c` = blue, `d` = red) |
| `dh` | Delete highlight at current position |
| `gh` | List highlights |
| `gnh` | Jump to next highlight |
| `gNh` | Jump to previous highlight |

### Marks
| Key | Action |
|-----|--------|
| `m` + char | Set local mark (lowercase = per-document, uppercase = global) |
| `` ` `` + char | Jump to mark |
| `gm` | List marks |

### Portals
| Key | Action |
|-----|--------|
| `p` | Set portal source (press once), then navigate and press again to create |
| `dp` | Delete portal at current position |

### Web Search
| Key | Action |
|-----|--------|
| `⌃f` | Search selected text on Google Scholar |
| `⌥f` | Search selected text on Google |

### UI
| Key | Action |
|-----|--------|
| `t` | Toggle table of contents |
| `:` | Command mode (e.g. `:dark`, `:page 42`, `:quit`) |
| `o` | Open document |
| `F8` | Toggle dark mode |
| `q` | Quit |

### Command Mode (`:`)
| Command | Action |
|---------|--------|
| `:dark` | Enable dark mode |
| `:light` | Enable light mode |
| `:toc` | Toggle table of contents |
| `:page {n}` | Go to page n |
| `:open` | Open document picker |
| `:quit` / `:q` | Quit |
