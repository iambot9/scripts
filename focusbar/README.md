# FocusBar

A small Pomodoro timer for the macOS menu bar. It shows a countdown, asks for
the one task you are working on, lets you park distractions for the break,
keeps a history of what you finished, counts sessions per day, and rings a
chime when a focus session or break ends.

## Install

Needs macOS 14 or later and Apple's command line tools
(`xcode-select --install` if you don't have them).

```bash
mkdir -p ~/Applications/focusbar && cd ~/Applications/focusbar
curl -fsSLO https://raw.githubusercontent.com/iambot9/scripts/main/focusbar/FocusBar.swift
curl -fsSLO https://raw.githubusercontent.com/iambot9/scripts/main/focusbar/make_icon.swift
curl -fsSLO https://raw.githubusercontent.com/iambot9/scripts/main/focusbar/build.sh
chmod +x build.sh
./build.sh run
```

This builds `FocusBar.app` on your machine, runs a self-test and starts it.
Look for the tomato in the menu bar.

- **Notifications:** allow them when macOS asks, to get a banner at the end
  of each period. The chime plays either way.
- **Start at login:** add `FocusBar.app` under System Settings → General →
  Login Items.
- **Update:** run the same commands again.

## Using it

Name the one task you are working on and press Start. A five second lead-in
ticks down before focus begins, so you can settle rather than being dropped
straight into the clock; cancel it if you started by mistake.

While focus runs the panel shows the task and a quote. Anything that pulls at
your attention goes in the park field, and the parked list opens by itself at
the break, when it is time to deal with it.

Finished sessions are kept under **History**, with the task, when it finished
and how long it ran. **Copy all** gives you the list oldest first, which is
what you want for a timesheet or a standup note. The last 50 are kept.

Pick the focus and break length from the menu in the footer. The presets all
run a 5:1 ratio:

| Preset | Focus | Break |
|---|---|---|
| 10 / 2 | 10 min | 2 min |
| 15 / 3 | 15 min | 3 min |
| 25 / 5 | 25 min | 5 min |
| 45 / 9 | 45 min | 9 min |
| 50 / 10 | 50 min | 10 min |

A change applies from the next session, not the running one.

## Hacking on it

`./build.sh` builds and runs the self-test; `./build.sh run` also launches it.
The self-test drives the timer with simulated time and touches no real
settings, so it is safe to run anywhere:

```bash
./FocusBar.app/Contents/MacOS/FocusBar --selftest
```

`make_icon.swift` draws `FocusBar.icns` with CoreGraphics, rendering each of
the ten sizes macOS asks for natively rather than downsampling one of them.
`build.sh` runs it on the first build and again only when the generator
changes. Both the `.icns` and the `.app` are build output and are gitignored.

Settings, parked items and history are stored in `UserDefaults` under
`local.focusbar`, which lives in `~/Library/Preferences/local.focusbar.plist`.
Quit the app before editing or deleting it, or `cfprefsd` will write its
cached copy back over your change.
