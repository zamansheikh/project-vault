# Project Vault

This folder is managed by **Project Vault**
(<https://github.com/zamansheikh/project-vault>). It holds a versioned backup of
the files your projects need to run but git does not keep: `.env` files,
Firebase configs, Android keystores and `key.properties`, iOS signing files,
and anything listed in `extras.txt`.

- Projects folder: `@ROOT@`
- This vault: `@VAULT@`

## What is where

| Path | What it holds |
|---|---|
| `current/` | The latest copy of every file, at the **same path as in the projects folder**. |
| `history/` | Older versions, at the same paths: `.env.v1_2026-11-23_1405` is version 1, last edited at that time. |
| `INDEX.md` | Every project, its files, their version, last edit, and whether the project still has them. |
| `extras.txt` | Extra files or folders to back up. |
| `exclude.txt` | Paths never to back up. |
| `offsite.conf` | Where encrypted copies go (after `vault offsite setup`). |
| `logs/changes.log` | One line per added, changed or restored file and per encrypted copy. |

Names starting with a dot (`.env`) are hidden in Finder: press **Cmd + Shift + .** to show them.

## Quick reference

| I want to… | Do this |
|---|---|
| Open the window | **Project Vault** app (Launchpad or Spotlight), or `vault ui` |
| Back up right now | `vault sync`, or **Sync now** in the window |
| Get a lost project's files back | clone it again, then `vault restore <project>` |
| Get an older version of a file | `vault history <file>`, then `vault restore <file> --version N` |
| Check the background backup | `vault service` |
| Stop / start the background backup | `vault stop` / `vault start` |
| Keep encrypted copies off this Mac | `vault offsite setup` |
| See every command | `vault help` |

Nothing in this folder is ever deleted by Project Vault. If a project or file
disappears, its copy stays here and `INDEX.md` lists it under "Source missing".

## Safety

Only your macOS user can open this folder. It holds every project secret in one
place: never put it inside a git repo, and never share it unencrypted. Use
`vault offsite setup` for encrypted copies.
