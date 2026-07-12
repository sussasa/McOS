# McOS 1.0

A modular desktop operating environment for **CC:Tweaked** advanced computers and monitors.

McOS 1.0 includes a desktop, Start menu, taskbar, touch-monitor support, file management, McNet networking, redstone automation, peripheral tools, notifications, recovery, backups, and installable Lua applications.

## Requirements

- CC:Tweaked
- Advanced Computer
- Advanced Monitor recommended for touch mode
- Modem required for McNet
- HTTP enabled if using McStore downloads

## Installation

1. Copy `installer.lua` to the CC:Tweaked computer.
2. Run:

```lua
installer.lua
```

3. Reboot:

```lua
reboot
```

The installer backs up an existing system before replacing it and attempts rollback if installation fails.

## Main features

- Desktop, Start menu, taskbar, app search, and lock screen
- Mouse and Advanced Monitor touch controls
- Files with copy, cut, paste, rename, search, favorites, history, and Recycle Bin
- McNet device discovery, messaging, file transfer, ping, and optional trusted remote controls
- Redstone Center with analog levels, pulses, timers, scenes, rules, and bundled redstone
- Peripheral Manager for monitors, modems, speakers, printers, inventories, drives, turtles, and other peripherals
- Notification Center and persistent system logs
- Backups, transactional recovery, and safe-mode tools
- McStore HTTPS Lua application installer
- Calculator, Notes, Clock, Paint, Music Player, Printer Center, Inventory Viewer, Turtle Control, and Task Manager
- Fully English interface and startup guide

## Source layout

```text
startup.lua              Bootstrap loader
mcos/system/main.lua     McOS kernel and built-in applications
mcos/apps/               External application directory
installer.lua            Standalone installer
AUDIT.md                  Static audit and repair report
CHANGELOG.md              Release notes
```

## Security notes

McNet trusted computer IDs are an access-control convenience, not cryptographic authentication. Rednet traffic is not encrypted. McStore applications are ordinary Lua programs and are not sandboxed, so only install code from sources you trust.

## Version

Current public release: **1.0.0**

The public version line starts at 1.0.0.
