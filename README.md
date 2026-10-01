<div align="center">
  <img src="docs/icon.png" width="120" alt="ClaudeHub icon">

# ClaudeHub

**All your Claude Code sessions. One app.**

Browse every Claude Code session per project in a sidebar — click one and it
resumes in an embedded terminal, in the right folder, instantly.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI + SwiftTerm](https://img.shields.io/badge/SwiftUI-%2B%20SwiftTerm-purple)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-green)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/LouisMylle/ClaudeHub)](https://github.com/LouisMylle/ClaudeHub/releases/latest)

<img src="docs/screenshot-1.4.png" alt="ClaudeHub screenshot" width="900">

</div>

> Multi-account switching, usage-limit meters, session deletion, split panes,
> live status dots, git awareness, conversation search, the side-by-side diff,
> and paste memory were contributed by
> [@gillesravyse](https://github.com/gillesravyse). Thank you!

## Why

Getting back into a Claude Code session means remembering where it lived,
`cd`-ing there, and digging the right session out of `claude --resume`.
ClaudeHub reads Claude Code's own session store and turns it into a
launcher: every project, every session, one click to pick up where you left
off.

## Features

- 🗂️ **Sessions per project** — grouped by their real working directory, with
  AI-generated titles and last-activity times, sorted by recency
- ⚡ **One-click resume** — opens the session in an embedded terminal
  ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), already in the
  right folder
- 🧵 **Tabs** — every session gets a tab; terminals stay alive when you switch,
  and **dragging one along its neighbours** orders a project's tabs the way
  the work is rather than the order you happened to open them in
- ✨ **Start a new chat anywhere** — `⌘N` starts a fresh Claude session in the
  current folder, `⇧⌘N` in any folder you pick; the `+` in the toolbar also
  lists your projects, and every project row has its own `+`. `⌘T` opens a
  plain shell in the same folder
- 👤 **Account switching** — the sidebar footer shows which account (and plan)
  you are burning limits on. Hit your 5-hour or weekly cap and one click logs
  you into another: ClaudeHub remembers the addresses you use and hands the
  login to `claude auth login --email …`, so the real browser flow runs and no
  credential is ever stored by the app
- 📊 **Limits always on screen** — two bars in the sidebar footer show your
  5-hour and weekly usage with a live countdown to the reset, green through
  red, and they name the account they belong to. `⌘U` still drops `/usage` into
  the session you are looking at; `/status`, `/context` and `/model` are one
  menu item away
- ⚡ **Instant account switching** — save a `claude setup-token` token per
  account and switch with one click, no browser. The token is checked against
  the API before it is kept, and the menu tells you what that check
  established. Picking an account **moves every open conversation to it** and
  resumes each one where it was; anything mid-answer, or holding a paste you
  have not sent, moves the moment it safely can rather than being cut off.
  Tokens travel per session, so **two tabs can still run as two accounts at
  once** — right-click a session to *Resume as* another account
- 🟢 **Live status dots** — green when a session waits on you, pulsing amber
  while Claude is working, pulsing blue when a permission prompt needs an
  answer. Scan the sidebar to see which session wants you
- 🗑️ **Delete sessions** — remove a chat (or every chat in a project) for good
  from the context menu or with `⌫`. Transcript, tool results, and session env
  go to the **Trash**, so a mis-click is recoverable in Finder
- 🔌 **MCP manager** — see every configured MCP server across user, project
  (`.mcp.json`), and local scopes; add and remove them from the UI (backed by
  the `claude mcp` CLI, so config stays canonical)
- 🙈 **Hide sessions** — declutter the sidebar without deleting anything;
  hidden sessions stay resumable and can be unhidden anytime
- 🌓 **Light & dark** — terminal theme follows the system appearance, live
- 🛟 **Quit protection** — warns you before ⌘Q kills running sessions
- 🔄 **Auto-update** — checks GitHub releases; one click downloads, installs,
  and relaunches
- 🎡 **Flow graphs** — the graph button in the toolbar (or right-click a
  session) draws it live as an agent/tool graph beside the conversation: the
  main agent, the subagents it spawns, the tools each one runs — powered by
  the bundled [zoetrope](https://github.com/furkankly/zoetrope)
- 🔎 **Search the conversation** — `⌘F` searches a session's whole transcript,
  not just what's on screen; ↑/↓ or `⌘G` step through results, each one jumps
  the terminal to the message when it's visible, or opens up to show it
- 🧭 **Side-by-side diff** — from the Changes section: a repository's
  uncommitted work as two aligned columns, changes paired up, files listed
  beside; click a file to open it in VS Code
- 📋 **Paste memory** — switching account restarts tabs; a prompt holding a
  paste or an image carries it across instead of losing it
- 🔔 **Finished-session notifications** — a session that finishes while you're
  in another app says so; click the banner to jump to it (asked once, optional)
- 📎 **Drag anything in** — a file from Finder, an attachment straight from
  Mail or Photos, or a bare image from a browser: drop it on the terminal and
  its escaped path is typed at the prompt, ready to ask about
- 🖱️ **⌘-click paths** — `src/Foo.swift:42` in Claude's output opens in
  VS Code at that line; URLs open in the browser; an image, PDF, or recording
  opens in its own app (Preview), not as a screenful of bytes
- 📌 **Pin chats** — right-click → *Pin Chat to Top* keeps the conversation
  you live in above everything newer work pushes up
- 🔍 Search across projects and session titles, open the folder in VS Code,
  hand-off to Terminal.app, reveal in Finder, copy resume command

## Install

### Homebrew

```sh
brew install --cask --no-quarantine LouisMylle/tap/claudehub
```

`--no-quarantine` is needed because the app is ad-hoc signed (not
notarized) — without it macOS refuses to open it until you clear the
quarantine flag by hand (see below). Update with `brew upgrade --cask
claudehub`, or just let the in-app updater do it.

### Download

1. Grab the latest `ClaudeHub-x.y.z.zip` from
   [Releases](https://github.com/LouisMylle/ClaudeHub/releases/latest)
2. Unzip and drag `ClaudeHub.app` into `/Applications`
3. The app is ad-hoc signed (not notarized), so macOS quarantines it on first
   download. Clear it once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/ClaudeHub.app
   ```

You'll need the [Claude Code](https://claude.com/claude-code) CLI installed —
ClaudeHub is a front-end for it.

### Build from source

```sh
git clone https://github.com/LouisMylle/ClaudeHub.git
cd ClaudeHub
./build_app.sh --install   # builds and copies to /Applications
```

Requires the Xcode command line tools. No Xcode project — it's a plain Swift
package.

## Shortcuts

| Keys | Action |
| --- | --- |
| `⇧↩` | Newline in the Claude Code prompt (instead of submitting) |
| `⌘U` | Usage & limits in the current session (`/usage`) |
| `⇧⌘L` | Switch account (`claude auth login`) |
| `⌘N` | New Claude session in the current folder |
| `⇧⌘N` | New Claude session in a folder you pick |
| `⌘T` | New shell tab in the current folder |
| `⌥⌘N` | New window |
| `⌫` | Delete the selected session (asks first) |
| `⌘⌫` | Same, from the Edit menu |
| `⌘W` | Close tab |
| `⇧⌘W` | Close window |
| `⌘1`–`⌘9` | Jump to tab |
| `⌘R` | Rescan sessions |
| `⌘B` | Show / hide the sidebar |
| `⌘F` | Find in the conversation (↑/↓ or `⌘G` / `⇧⌘G` step results) |
| `⌘\` | Open the current tab beside the others (split) |
| `⌥←` / `⌥→` / `⌥⌫` | Word left / right / delete word in the prompt |
| `⌘+` / `⌘−` / `⌘0` | Terminal text size |
| ⌘-click | Open the clicked file path in VS Code (URLs in the browser) |

## How it works

Claude Code stores each session as a JSONL transcript in
`~/.claude/projects/<encoded-path>/<session-uuid>.jsonl`. ClaudeHub scans
those files for the working directory (`cwd`), the AI-generated title
(`aiTitle`), and uses the file's mtime for recency — bridge stubs and
subagent sidechains are filtered out. Selecting a session spawns

```sh
zsh -l -c "cd <cwd> && exec claude --resume <session-id>"
```

inside a SwiftTerm view that stays alive per tab; a new session is the same
command without `--resume`. Deleting a chat moves its `.jsonl`, its sidecar
`<session-id>/` folder, and `~/.claude/session-env/<session-id>` to the Trash —
nothing is unlinked outright.

Accounts are read with `claude auth status --json` and changed with
`claude auth login` / `logout` in a visible tab, so ClaudeHub never reads Claude
Code's own credentials. Note that logging in swaps the account for the `claude`
CLI everywhere, not just in ClaudeHub; sessions already running keep their
current credentials until they re-authenticate.

Instant switching works differently, and better: you mint a token with
`claude setup-token` and hand it to ClaudeHub, which keeps it in your login
keychain and passes it to sessions you start as that account through
`CLAUDE_CODE_OAUTH_TOKEN`. Because that is per-process, a tab can run as an
account you are not signed in as, and several accounts can run side by side —
which `/login` cannot do, since it changes the one account the CLI uses
machine-wide. Forgetting a profile deletes the keychain item; revoke the token
itself at claude.ai to kill it for good.

ClaudeHub is ad-hoc signed, so every build is a new program as far as the
keychain is concerned and macOS asks permission for the item again after each
update. The tokens are therefore read once per launch, off the main thread, and
a refusal is shown rather than swallowed: a tab that could not get its token
says so on its chip instead of quietly running as whoever is signed in.

A `setup-token` token will not name its account — the OAuth profile endpoint
refuses it for want of scope — but the API does say which organisation it
billed a request to. ClaudeHub compares that with the signed-in account's
organisation, so the account menu can tell you the token really is a different
account, instead of you having to trust the label you typed.

The limit bars are read two ways, because the two kinds of account are told
different things. Signed in, ClaudeHub asks the way you would: it starts a
`claude` session off-screen, sends `/usage` and reads the panel, which runs no
prompt and costs nothing. A token-authenticated session is never shown those
windows — Claude Code runs it as "Claude API", and the panel comes back without
them — so for a saved account the numbers come from the API's own
`anthropic-ratelimit-unified-*` headers instead, read off a one-token request
made at most every three minutes, and only while the window is in front.

Which is why the bars say whose numbers they are: a reading taken before the
token is out of the keychain is the signed-in account's, and a percentage
without an owner is how one account's usage gets mistaken for another's.

Claude Code exposes no "am I busy" signal, so the status dots read the session's
own screen: it prints an `esc to interrupt` hint while it works, and permission
prompts ask `Do you want to …`. Slash commands from the menu are typed into the
session and only submitted when the prompt is provably empty — otherwise they
are left for you to send, so a half-typed message is never mangled. MCP servers are read from
`~/.claude.json` and per-project `.mcp.json` files; all mutations go through
`claude mcp add` / `claude mcp remove` so ClaudeHub never hand-edits your
config.

## Bundled software

The embedded terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
by Miguel de Icaza (MIT), linked into the app; its license ships in the
bundle as `Contents/Resources/SwiftTerm-LICENSE`.

ClaudeHub ships the `zoe` binary from
[zoetrope](https://github.com/furkankly/zoetrope) by
[@furkankly](https://github.com/furkankly) (MIT license), which draws a Claude
Code session as a live flow graph in the terminal. The app bundles the
official release binaries unmodified (as a universal binary); the license and
the release checksums travel inside the app at
`Contents/Resources/zoetrope-LICENSE` and `…-PROVENANCE`. If you already have
`zoe` on your PATH, source builds use that instead.

## Disclaimer

ClaudeHub is an independent community tool and is not affiliated with,
endorsed by, or sponsored by Anthropic. "Claude" is a trademark of Anthropic,
PBC. The app simply drives the official `claude` CLI on your machine.

## License

[Apache 2.0](LICENSE) © 2026 Louis Mylle — see [NOTICE](NOTICE) for
contributor and third-party attributions.
