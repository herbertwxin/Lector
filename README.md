# Lector
A MacOS native academic PDF reader derived from Sioyek(https://github.com/ahrm/sioyek)

## Install

### Homebrew (recommended)
```bash
brew tap herbertwxin/lector
brew install --cask lector
```

To update when a new version is released:
```bash
brew upgrade --cask lector
```

### Manual
Download `Lector.dmg` from [Releases](https://github.com/herbertwxin/Lector/releases), open it, and drag Lector to Applications.

> **First launch:** right-click Lector.app → Open, then click Open in the dialog. This is a one-time step because the app is not yet notarized with Apple.

## Build from source

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15+

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
| `j` / `↓` | Scroll down |
| `k` / `↑` | Scroll up |
| `⌃d` | Scroll down (large step) |
| `⌃u` | Scroll up (large step) |
| `Space` | Next page |
| `Shift+Space` | Previous page |
| `gg` | Go to beginning |
| `G` | Go to end |
| `{n}gg` | Go to page n (e.g. `42gg`) |
| `⌫` | Navigate back |
| `Shift+⌫` | Navigate forward |

### Zoom
| Key | Action |
|-----|--------|
| `+` | Zoom in |
| `-` | Zoom out |
| `=` | Fit to width |
| `0` | Actual size (100%) |

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
| `h` + char | Highlight selection — `a` yellow · `b` green · `c` blue · `d` red |
| `dh` | Delete highlight at current position |
| `gh` | List highlights |
| `gnh` | Jump to next highlight |
| `gNh` | Jump to previous highlight |

### Marks
| Key | Action |
|-----|--------|
| `m` + char | Set mark — lowercase = per-document, uppercase = global across docs |
| `` ` `` + char | Jump to mark |
| `gm` | List marks |

### Portals
| Key | Action |
|-----|--------|
| `p` | First press: set source · Second press: create portal to current location |
| `dp` | Delete portal nearest to current position |

### Web Search
| Key | Action |
|-----|--------|
| `⌃f` | Search selected text on Google Scholar |
| `⌥f` | Search selected text on Google |

### UI
| Key | Action |
|-----|--------|
| `t` | Toggle table of contents |
| `:` | Open command mode |
| `o` | Open document picker |
| `F8` | Cycle appearance: Auto → Dark → Light → Auto |
| `q` | Quit |

---

## Command Mode (`:`)

Press `:` to enter command mode, type a command, press `Enter`.

### Appearance
| Command | Action |
|---------|--------|
| `:dark` | Force dark mode |
| `:light` | Force light mode |
| `:auto` / `:system` | Follow system appearance (default) |
| `:toggledark` | Cycle Auto → Dark → Light |

### Navigation
| Command | Action |
|---------|--------|
| `:page 42` | Jump to page 42 |
| `:beginning` | Go to first page |
| `:end` | Go to last page |
| `:nextpage` | Next page |
| `:prevpage` | Previous page |
| `:back` | Navigate back in history |
| `:forward` | Navigate forward in history |
| `:nextchapter` | Jump to next outline chapter |
| `:prevchapter` | Jump to previous outline chapter |

### Zoom
| Command | Action |
|---------|--------|
| `:zoom 150` | Set zoom to 150% |
| `:zoomin` | Zoom in |
| `:zoomout` | Zoom out |
| `:fit` / `:fitwidth` | Fit to width |
| `:actualsize` | Reset to 100% |

### Search
| Command | Action |
|---------|--------|
| `:search keyword` | Search for keyword |
| `:next` | Next search result |
| `:prev` | Previous search result |

### Bookmarks
| Command | Action |
|---------|--------|
| `:bookmark` | Add bookmark (auto-labelled) |
| `:bookmark My note` | Add bookmark with custom label |
| `:deletebookmark` | Delete bookmark at current position |
| `:bookmarks` | Show bookmarks panel |
| `:allbookmarks` | Show bookmarks across all documents |

### Highlights
| Command | Action |
|---------|--------|
| `:highlight a` | Highlight selection (a/b/c/d → yellow/green/blue/red) |
| `:deletehighlight` | Delete highlight at current position |
| `:highlights` | Show highlights panel |
| `:nexthighlight` | Jump to next highlight |
| `:prevhighlight` | Jump to previous highlight |

### Marks
| Command | Action |
|---------|--------|
| `:mark a` | Set mark 'a' at current position |
| `:goto a` | Jump to mark 'a' |
| `:marks` | Show marks panel |

### Portals
| Command | Action |
|---------|--------|
| `:portal` | Set portal source / create portal |
| `:deleteportal` | Delete nearest portal |
| `:gotoportal` | Jump to nearest portal destination |

### Web Search
| Command | Action |
|---------|--------|
| `:scholar deep learning` | Search phrase on Google Scholar |
| `:scholar` | Search current selection on Google Scholar |
| `:google gradient descent` | Search phrase on Google |
| `:google` | Search current selection on Google |

### Misc
| Command | Action |
|---------|--------|
| `:copy` | Copy selected text to clipboard |
| `:rotate` | Rotate all pages 90° clockwise |
| `:rotate ccw` | Rotate all pages 90° counter-clockwise |
| `:fullscreen` | Toggle full screen |
| `:toc` | Toggle table of contents |
| `:open` / `:o` | Open document picker |
| `:recent` | Show recent documents panel |
| `:quit` / `:q` | Quit |
