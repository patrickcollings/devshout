# Installing devshout: steps for a coding agent

You are installing devshout, a macOS menu bar dictation app, for the person you are working with. It takes one
command and then a few clicks that only they can do.

## 1. Check the Mac

```bash
uname -m                    # must be arm64 (Apple silicon)
sw_vers -productVersion     # must be 14 or later
```

If either is wrong, stop and say so. Xcode is not needed.

## 2. Install

```bash
curl -fsSL https://raw.githubusercontent.com/patrickcollings/devshout/main/install.sh | bash
```

From a clone of the repo, `./install.sh` does the same. It downloads the latest release, puts `devshout.app` in
`/Applications`, and opens it. Read the script first if the person wants to know what it does: it is short.

If the download fails because the repository is private, the script falls back to the GitHub CLI
(`gh release download`), which needs `gh auth login` and access to the repository.

Do not build from source unless the person asks: that needs Xcode 26 (`scripts/install-from-source.sh`).

## 3. Hand over to the person

devshout is now in the menu bar and its set-up window is open. Tell them to do these there. You cannot do them:
macOS requires a person to click.

1. **Microphone:** click Allow on the macOS prompt.
2. **Accessibility:** the window opens System Settings → Privacy & Security → Accessibility; switch devshout on.
3. **Speech model:** wait for the download (a few hundred MB).
4. **Claude:** connect their Claude plan. This uses the Claude Code CLI (`claude`), which they already have if they
   are talking to you through it. Do not run `claude setup-token` for them and do not read or handle the token.
5. Press **⌥Space** and talk.

## 4. Check it worked

```bash
pgrep -x devshout                                   # prints a process id
defaults read /Applications/devshout.app/Contents/Info CFBundleShortVersionString
```

## Updating and removing

- **Update:** run the install command again. Afterwards macOS may need Accessibility re-added (remove devshout
  with −, add it again with +) and may ask once for the login password to read the Claude token.
- **Remove:** quit devshout, delete `/Applications/devshout.app`, and delete
  `~/Library/Application Support/devshout` (models, recordings, settings, glossary). Ask before deleting the
  second: it holds their recordings and glossary.
