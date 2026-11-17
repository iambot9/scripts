# scripts

Small utility scripts.

## focusbar/

FocusBar, a Pomodoro timer for the macOS menu bar. See
[focusbar/README.md](focusbar/README.md) for download and install steps.

## obsidian/obsidian-attachments.sh

Tidies an Obsidian vault on macOS: creates an `attachments` folder, moves
`Pasted image *.png` files from the vault root into it, and sets it as the
default location for new attachments.

```bash
# Quit Obsidian first
./obsidian/obsidian-attachments.sh "/path/to/vault"
```

The vault path is optional when only one vault is registered.
