# Docs

The [main README](../README.md) shows each feature in a screenshot or two. These pages go deeper.

## Overview

| Doc | What |
| --- | --- |
| [INSTALL.md](INSTALL.md) | Building and installing, permissions, updating, uninstalling, and where Cortex keeps its data |
| [DEVELOPMENT.md](DEVELOPMENT.md) | The make targets, the tests and how the README's screenshots are made |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the app is built: the host, the module system, the shared core package and how they fit together |
| [SYNC.md](SYNC.md) | The sync protocol between the Macs and the server: records, encryption, conflicts, the server API |

## Modules

One page per module: what it does, how it works and where its code is.

| Doc | What |
| --- | --- |
| [modules/CLIPBOARD.md](modules/CLIPBOARD.md) | Clipboard history: recording, search, pasting, sensitive clips, retention |
| [modules/SNIPPETS.md](modules/SNIPPETS.md) | Snippets: placeholders, keyword expansion, Raycast import |
| [modules/READING_LIST.md](modules/READING_LIST.md) | The reading list behind `+` |
| [modules/KNOWLEDGE.md](modules/KNOWLEDGE.md) | The knowledge base: Markdown files, the index, to-dos, imports, `cortex-mcp`, filing with AI |
| [modules/ACTIONS.md](modules/ACTIONS.md) | Quick actions: built-in, TOML-defined, file actions, Shortcuts |
| [modules/COMMANDS.md](modules/COMMANDS.md) | `$` commands and their form |
| [modules/AI.md](modules/AI.md) | AI actions, providers and usage |
| [modules/EMOJI.md](modules/EMOJI.md) | Emoji search and skin tones |
| [modules/SYMBOLS.md](modules/SYMBOLS.md) | SF Symbols search |
| [modules/CALCULATOR.md](modules/CALCULATOR.md) | The calculator and unit conversion behind `=` |
| [modules/COLOR_PICKER.md](modules/COLOR_PICKER.md) | The eyedropper and colour swatches |
| [modules/TEXT_RECOGNITION.md](modules/TEXT_RECOGNITION.md) | Searching text in screenshots and capturing text from the screen |
| [modules/SCROLLING.md](modules/SCROLLING.md) | Per-device scroll direction |
| [modules/SYNC.md](modules/SYNC.md) | The sync module: setup, what syncs, status, the app side of the protocol |

## Guides

| Doc | What |
| --- | --- |
| [ADDING_A_MODULE.md](ADDING_A_MODULE.md) | Checklist for adding a module |
| [ADDING_ACTIONS.md](ADDING_ACTIONS.md) | Adding a built-in quick action or a `$` command |
| [ADDING_AI_PROVIDER.md](ADDING_AI_PROVIDER.md) | Adding an AI provider |
| [MANUAL_TESTS.md](MANUAL_TESTS.md) | The checks the automated tests cannot do, to run after macOS updates and larger changes |

The sync server has its own README: [../sync-server/README.md](../sync-server/README.md).
