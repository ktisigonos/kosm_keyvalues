# kosm_keyvalues

Valve's KeyValues for kosm: the `keyvalues` adapter, which edits `.res` and `.vdf` files (any
other KeyValues file with `.lang = "keyvalues"`), such as a GoldSrc or Source game's
`TrackerScheme.res`.

A file is keys, each followed by a value or a `{ ... }` block of more keys; paths step through
the blocks: `Scheme.Colors.BaseText`, `Scheme.Fonts.*.*.name`. Keys and values may be quoted or
bare, `//` comments, `[$WIN32]` conditionals and `#base` / `#include` lines are read and kept.
A key written twice is two entries, so `set` refuses to pick one and `setAll` sets both.

Values are written quoted. Colors default to `r g b a` (`"4 28 38 255"`) and booleans to `1` /
`0`. Text holding a quote or a line break, or ending in a backslash, is refused.

Only `edit` is supported: KeyValues files belong to their programs, so kosm changes values in
place and never writes a whole file.
