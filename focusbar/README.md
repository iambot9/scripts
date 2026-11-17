# FocusBar

A small Pomodoro timer for the macOS menu bar. It shows a countdown, asks for
the one task you are working on, lets you park distractions for the break,
counts sessions per day, and rings a chime when a focus session or break ends.

## Install

Needs macOS 14 or later and Apple's command line tools
(`xcode-select --install` if you don't have them).

```bash
mkdir -p ~/Applications/focusbar && cd ~/Applications/focusbar
curl -fsSLO https://raw.githubusercontent.com/iambot9/scripts/main/focusbar/FocusBar.swift
curl -fsSLO https://raw.githubusercontent.com/iambot9/scripts/main/focusbar/build.sh
chmod +x build.sh
./build.sh run
```

This builds `FocusBar.app` on your machine, runs a self-test and starts it.
Look for 🍅 in the menu bar.

- **Notifications:** allow them when macOS asks, to get a banner at the end
  of each period. The chime plays either way.
- **Start at login:** add `FocusBar.app` under System Settings → General →
  Login Items.
- **Update:** run the same commands again.
