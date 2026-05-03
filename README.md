# GuildMainTagger

Displays the main character name in guild chat messages for known alts.

## How it works

The addon resolves the main character for each guild member using the following priority:

1. **Officer note** — scanned for the pattern (highest priority)
2. **Public note** — scanned for the pattern
3. **Local database** — populated automatically from notes, or set manually

The pattern can be placed anywhere in the note alongside other content, e.g.:

```
Alchemy / Herbalism <Main Foobar>
```

The default pattern is `<Main CharName>`. It can be changed per user via `/gmt pattern`.

## Sync

Guild members using the addon automatically share their local databases in the background. On login, the addon broadcasts its entries and requests entries from others — throttled and silent.

Priority during sync merges:
- Note-based entries always win over synced entries
- Manual entries win over synced entries
- For equal-priority entries, the newest timestamp wins

## Commands

| Command | Description |
|---------|-------------|
| `/gmt set <alt> <main>` | Manually assign an alt to a main |
| `/gmt remove <alt>` | Remove an assignment |
| `/gmt list` | Show all active assignments with source and last editor |
| `/gmt sync` | Manually trigger sync with other addon users |
| `/gmt update` | Refresh guild roster |
| `/gmt pattern` | Show current search pattern |
| `/gmt pattern <LuaPattern>` | Change search pattern |
| `/gmt pattern reset` | Restore default pattern |
| `/gmt debug [on\|off]` | Toggle debug mode (or toggle without argument) |
| `/gmt info` | Show detailed status (note cache, DB entries, pattern, queue) |

## Pattern Examples

| Pattern | Matches |
|---------|---------|
| `<Main%s+(.-)>` | `<Main Foobar>` (default) |
| `<Alt of%s+(.-)>` | `<Alt of Foobar>` |
| `%[Main:%s*(.-)%]` | `[Main: Foobar]` |

## SavedVariables

`GuildMainTaggerDB` stores:
- `entries` — map of `altName → { main, ts, source, author }` where source is `note`, `manual`, or `sync`, and author is the character name of whoever last set the entry
- `pattern` — current search pattern
- `debug` — debug mode flag
