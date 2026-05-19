# Better CMD

Automatic setup for a styled Windows terminal: **Windows Terminal** (Catppuccin Mocha theme, transparency, Nerd Font) + **Fastfetch** on PowerShell startup.

Inspired by [SleepyCatHey](https://www.youtube.com/)'s tutorial — this repo bundles everything into a single clickable script.

## Preview

![Preview of the terminal configured by Better CMD](./preview.png)

## What the script does

When you run `Better-CMD.bat`, the script:

| Step | Action |
|--------|--------|
| **winget** | Checks for `winget`; installs it via App Installer if needed |
| **Fastfetch** | Installs [Fastfetch](https://github.com/fastfetch-cli/fastfetch) and copies the config (`fastfetch/`) to `%USERPROFILE%\.config\fastfetch` |
| **Fonts** | Installs **all** `.ttf` / `.otf` files from the `fonts/` folder for the current user (copy + registry + cache refresh) |
| **Windows Terminal** | Deploys `LocalState/settings.json` (profiles, colors, JetBrainsMono Nerd Font Mono, acrylic, etc.) |
| **PowerShell** | Adds `fastfetch` to the user profile so it runs on every launch |
| **Restart** | Restarts Windows Terminal to apply the changes |

Backups of the previous `settings.json` are stored in:

`%USERPROFILE%\.better-cmd-backups\`

## Requirements

- **Windows 10/11**
- **[Windows Terminal](https://aka.ms/terminal)** (Microsoft Store)
- Internet connection recommended (winget / Fastfetch installation)
- **Administrator** rights on first run (via UAC elevation from `Better-CMD.bat`)

## Installation

1. Clone or download this repository.
2. Make sure the `fonts/` folder contains your fonts (JetBrains Mono Nerd Font, etc.).
3. Double-click **`Better-CMD.bat`** and accept the UAC elevation prompt.
4. Wait for the script to finish — Windows Terminal will reopen with the new config.

### Command line

```powershell
# Install
.\Better-CMD.ps1

# Uninstall (restores settings.json + removes fastfetch from profile)
.\Better-CMD.ps1 -Uninstall
```

Or use **`Better-CMD-Uninstall.bat`** for restoration without manually running PowerShell.

> **Note:** Uninstall does not remove fonts or Fastfetch from the system — it only restores the Windows Terminal config (from backup) and removes the `fastfetch` entry from the PowerShell profile.

## Project structure

```
Better-CMD/
├── Better-CMD.bat              # Launcher (admin) — use this first
├── Better-CMD.ps1              # Main script
├── Better-CMD-Uninstall.bat    # Quick restore
├── preview.png                 # Screenshot for this README
├── fonts/                      # .ttf / .otf fonts installed automatically
├── fastfetch/
│   ├── config.jsonc            # Fastfetch config (Catppuccin theme)
│   └── ascii.txt               # ASCII logo displayed on the left
└── LocalState/
    └── settings.json           # Windows Terminal profiles and appearance
```

## Customization

- **Terminal**: Edit `LocalState/settings.json`, then run `Better-CMD.bat` again.
- **Fastfetch**: Edit `fastfetch/config.jsonc` or replace `fastfetch/ascii.txt`.
- **Fonts**: Add or remove files in `fonts/`, then rerun the script — only new fonts will be copied.

Default font in Windows Terminal: **JetBrainsMono Nerd Font Mono**.

## Troubleshooting

| Issue | Suggestion |
|----------|--------|
| `winget` not found | Rerun `Better-CMD.bat` after installing App Installer, or install [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) |
| Broken icons in Fastfetch | Make sure Nerd Fonts are in `fonts/` and that the script installed them |
| Font missing in WT menu | Fully close Windows Terminal, rerun the script, or restart your session |
| Restore previous terminal | `Better-CMD-Uninstall.bat` |

## Credits

- Original tutorial: **SleepyCatHey**
- [Fastfetch](https://github.com/fastfetch-cli/fastfetch)
- [JetBrains Mono Nerd Font](https://github.com/ryanoasis/nerd-fonts)
- **Catppuccin Mocha** theme

## License

Project provided as-is, without warranty. Third-party fonts and tools remain subject to their respective licenses.
