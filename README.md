# jev.nvim

Ask Neovim for something in plain words. It picks an editor action and runs it.

```
jev> split the window vertically
you: split the window vertically
→ split_window {direction=vertical}  92% · 118ms
  ok: vertical split
```

jev.nvim talks to **[Jev](https://docs.typesafe.ai), TypeSafe's System One model**.
Jev is not an LLM. It never writes text, never invents an argument, never runs a
command it made up. It is handed a fixed catalog of editor actions plus your words,
and it answers typed questions: *which action?*, *which option for `direction`?*,
*which words give `path`?* — each with a probability. The plugin decodes those picks
into a call and applies a policy to it. Nothing is generated.

Ported from [sdras/jev-webmcp-extension](https://github.com/sdras/jev-webmcp-extension),
which does the same thing for WebMCP tools in a browser side panel.

## Screenshots

![The jev panel after asking for a vertical split](assets/01-split.png)

`:Jev` opens the panel on the right. *split the window vertically* routes to
`split_window`, the `direction` option is filled from the same request, and the
split is already there.

![A read-only action running unprompted](assets/02-goto-line.png)

*go to line 40* decodes to `goto_line {line=40}` — the 40 is lifted from your own
words, never written by a model. Read-only and above the `auto` threshold, so it
runs without asking.

![The confirm prompt in front of a destructive action](assets/03-confirm.png)

*throw away my changes and reload the file* lands on `reload_file`, which is
marked destructive, so the policy stops at `confirm` and `vim.ui.select` asks
before anything happens.

![No confident match, with the runner-up named](assets/04-none.png)

Nothing in the catalog makes a sandwich, so nothing is invented: the panel says
so and names the runner-up route. Above it, the two requests that did land — the
transcript is one buffer and it keeps its history.

These are captures of the plugin actually running, made by
`node scripts/screenshot.mjs`: it drives a real Neovim over msgpack-rpc and
answers each request from a table of canned, API-shaped responses in
`scripts/shot_init.lua`. No API key, no network call, nothing drawn by hand.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'balazsorban44/nvim-jev-plugin',
  cmd = { 'Jev', 'JevToggle', 'JevAsk' },
  keys = {
    { '<leader>j', '<cmd>JevToggle<cr>', desc = 'Toggle jev' },
  },
  opts = {},
}
```

Requirements: Neovim >= 0.10, `curl`, and a TypeSafe API key from
[console.typesafe.ai/keys](https://console.typesafe.ai/keys). Export it as
`TYPESAFE_API_KEY` and you are done; `opts = {}` is enough.

## Setup

Every option, with its default:

```lua
require('jev').setup({
  api_key = nil,          -- else $TYPESAFE_API_KEY, read at request time
  model = 'jev-latest',
  url = 'https://api.typesafe.ai/v1/systemone',
  timeout_ms = 15000,
  width = 50,             -- panel width
  prompt = 'jev> ',
  always_confirm = false, -- ask before running anything
  thresholds = { route = 0.5, auto = 0.8, confirm = 0.6 },
})
```

## Commands

| Command | What it does |
| --- | --- |
| `:Jev` | Toggle the panel |
| `:JevToggle` | Same, with a name that reads better in a mapping |
| `:JevAsk {text}` | Open the panel if closed, then ask `{text}` |
| `:JevActions` | List the whole action catalog, grouped by category |

In the panel, type on the prompt line and press `<CR>`. The panel is a
`botright vsplit` with a fixed width; the transcript survives a toggle.

## Actions

The catalog is fixed — this is the whole surface Jev can reach. `:JevActions`
lists it inside Neovim; the tables below are generated from the same catalog.

<!-- actions:start -->
131 actions in 18 categories. Regenerate this block with
`nvim -l scripts/gen_actions_md.lua`.

<details>
<summary><b>files</b> — 9 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `save_file` | – | Write the current file to disk. Saves only this buffer, not the others. |  |
| `save_all` | – | Write every modified file to disk at once. |  |
| `save_as` | `path` | Save the current buffer under a new path, and keep editing that new file. |  |
| `open_file` | `path` | Open a file by path in the current window. |  |
| `new_file` | – | Start a new empty unnamed buffer in this window. |  |
| `reload_file` | – | Reload the current file from disk, throwing away unsaved changes in it. | destructive |
| `set_filetype` | `filetype` | Set the filetype of the current buffer, which drives syntax and plugins. |  |
| `show_file_path` | – | Show the full path of the file in this window. | read-only |
| `cd_to_file_dir` | – | Change the working directory to the folder holding the current file. |  |

</details>

<details>
<summary><b>buffers</b> — 7 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `next_buffer` | – | Show the next buffer in the buffer list in this window. | read-only |
| `previous_buffer` | – | Show the previous buffer in the buffer list in this window. | read-only |
| `goto_buffer` | `number` number | Switch this window to the buffer with a given buffer number. | read-only |
| `list_buffers` | – | List the open buffers and their numbers. | read-only |
| `close_buffer` | – | Close the current buffer. Refuses when it has unsaved changes. |  |
| `delete_buffer_force` | – | Close the current buffer even when it has unsaved changes, losing them. | destructive |
| `close_other_buffers` | – | Close every buffer except this one, keeping the unsaved ones open. | destructive |

</details>

<details>
<summary><b>windows</b> — 10 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `split_window` | `direction` horizontal \| vertical | Split the current window in two, side by side or one above the other. |  |
| `close_window` | – | Close the current window or split. Refuses when it is the last one, or when the buffer has unsaved changes. |  |
| `only_window` | – | Close every other split in this tab and leave only the current window. |  |
| `equalize_windows` | – | Give every split in this tab the same size again. |  |
| `maximize_window` | – | Make the current split as tall and wide as it can be. |  |
| `resize_window` | `dimension` height \| width, `size` number | Resize the current split to a given number of lines or columns. |  |
| `swap_window` | – | Swap this split with the next one, exchanging their positions. |  |
| `move_window_to_tab` | – | Move the current split out into a tab page of its own. |  |
| `focus_window` | `direction` down \| left \| right \| up | Move the cursor into the split to the left, right, above or below. | read-only |
| `toggle_diff_mode` | – | Turn diff mode for this window on or off, to compare it with another split. |  |

</details>

<details>
<summary><b>tabs</b> — 7 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `new_tab` | – | Open a new, empty tab page. |  |
| `close_tab` | – | Close the current tab page and its windows. |  |
| `tab_only` | – | Close every other tab page and keep only this one. |  |
| `next_tab` | – | Go to the next tab page. | read-only |
| `previous_tab` | – | Go to the previous tab page. | read-only |
| `goto_tab` | `number` 1..9 | Go to a tab page by its number, counting from the left. | read-only |
| `move_tab` | `direction` left \| right | Move the current tab one place to the left or to the right. |  |

</details>

<details>
<summary><b>navigation</b> — 17 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `goto_line` | `line` number | Move the cursor to a line number in the current buffer. | read-only |
| `goto_top` | – | Jump to the very top of the buffer, the first line. | read-only |
| `goto_bottom` | – | Jump to the very bottom of the buffer, the last line. | read-only |
| `goto_percent` | `percent` number | Jump part of the way through the file, by percentage. | read-only |
| `match_bracket` | – | Jump to the bracket, brace or parenthesis matching the one at the cursor. | read-only |
| `next_paragraph` | – | Move the cursor down to the next blank line, the start of the next paragraph. | read-only |
| `previous_paragraph` | – | Move the cursor up to the previous blank line, the paragraph before this one. | read-only |
| `next_function` | – | Jump forward to the start of the next function or section. | read-only |
| `previous_function` | – | Jump back to the start of the previous function or section. | read-only |
| `scroll_half_page_down` | – | Scroll half a screen down, towards the end of the file. | read-only |
| `scroll_half_page_up` | – | Scroll half a screen up, back towards the start of the file. | read-only |
| `center_cursor_line` | – | Scroll so the line the cursor is on sits in the middle of the screen. | read-only |
| `jump_back` | – | Go back to where the cursor was before the last jump. | read-only |
| `jump_forward` | – | Go forward again to the place you jumped back from. | read-only |
| `goto_last_edit` | – | Jump to the spot where you last changed something in this buffer. | read-only |
| `goto_mark` | `letter` 26 options | Jump to a mark you set earlier, named by a single letter. | read-only |
| `set_mark` | `letter` 26 options | Put a mark named by a letter on the current line, to jump back to later. |  |

</details>

<details>
<summary><b>editing</b> — 19 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `undo` | – | Undo the last change in the current buffer. |  |
| `redo` | – | Redo the change that was last undone. |  |
| `delete_line` | – | Delete the line the cursor is on. |  |
| `duplicate_line` | – | Copy the current line and paste the copy right below it. |  |
| `move_line_up` | – | Move the current line one line up, swapping it with the line above. |  |
| `move_line_down` | – | Move the current line one line down, swapping it with the line below. |  |
| `join_lines` | – | Join the next line onto the end of this one, making them a single line. |  |
| `indent_lines` | `count?` 1..20 | Indent lines at the cursor one step to the right. |  |
| `dedent_lines` | `count?` 1..20 | Unindent lines at the cursor one step to the left. |  |
| `toggle_comment` | – | Comment the current line out, or uncomment it when it is already a comment. |  |
| `uppercase_line` | – | Turn the whole current line into UPPER CASE. |  |
| `lowercase_line` | – | Turn the whole current line into lower case. |  |
| `uppercase_word` | – | Turn the single word under the cursor into UPPER CASE. |  |
| `lowercase_word` | – | Turn the single word under the cursor into lower case. |  |
| `sort_lines` | `order?` ascending \| descending, `unique?` yes/no | Sort every line of the buffer, forwards or backwards, optionally dropping duplicates. |  |
| `reverse_lines` | – | Reverse the order of every line in the buffer, last line first. |  |
| `trim_trailing_whitespace` | – | Strip the spaces and tabs left at the end of lines in this buffer. |  |
| `insert_line_above` | – | Open a new empty line above the current one. |  |
| `insert_line_below` | – | Open a new empty line below the current one. |  |

</details>

<details>
<summary><b>search</b> — 8 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `search` | `pattern` | Search the current buffer for a pattern and jump to the next match. | read-only |
| `search_backward` | `pattern` | Search backwards from the cursor and jump to the match before it. | read-only |
| `search_next` | – | Jump to the next match of the search you already ran. | read-only |
| `search_previous` | – | Jump back to the previous match of the search you already ran. | read-only |
| `clear_search_highlight` | – | Stop highlighting the search matches currently lit up. | read-only |
| `count_matches` | `pattern` | Count how many times a piece of text appears in this buffer. | read-only |
| `replace_in_line` | `find`, `replacement` | Replace one piece of text with another, on the current line only. |  |
| `replace_in_buffer` | `find`, `replacement` | Replace every occurrence of one piece of text with another, in the whole file. | destructive |

</details>

<details>
<summary><b>selection</b> — 4 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `select_all` | – | Select the entire buffer in visual mode. | read-only |
| `select_line` | – | Select the current line in visual mode. | read-only |
| `select_word` | – | Select the word under the cursor in visual mode. | read-only |
| `select_paragraph` | – | Select the paragraph the cursor is inside, up to the blank lines around it. | read-only |

</details>

<details>
<summary><b>clipboard</b> — 4 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `copy_line_to_clipboard` | – | Copy the current line to the system clipboard. | read-only |
| `copy_selection_to_clipboard` | – | Copy the text you last selected to the system clipboard. | read-only |
| `paste_from_clipboard` | – | Paste what is on the system clipboard below the cursor. |  |
| `copy_file_path` | – | Copy this file's full path to the system clipboard. | read-only |

</details>

<details>
<summary><b>folding</b> — 4 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `fold_all` | – | Fold everything shut, collapsing the file to its outermost level. |  |
| `unfold_all` | – | Open every fold, showing the whole file again. |  |
| `toggle_fold` | – | Open or close the one fold the cursor is inside. |  |
| `set_fold_level` | `level` 0..9 | Show folds only from a given nesting depth: 0 closes all, higher opens more. |  |

</details>

<details>
<summary><b>options</b> — 5 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `toggle_option` | `option` 11 options | Turn a window display option on or off. |  |
| `set_tab_width` | `width` 1..8 | Set how many columns wide a tab looks in this buffer. |  |
| `set_shiftwidth` | `width` 1..8 | Set how many columns one indent step adds in this buffer. |  |
| `set_colorscheme` | `name` | Switch to an installed colorscheme by name. |  |
| `set_background` | `mode` dark \| light | Tell Neovim the background is dark or light, so colors suit it. |  |

</details>

<details>
<summary><b>lsp</b> — 11 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `lsp_definition` | – | Jump to where the symbol under the cursor is defined. | read-only |
| `lsp_type_definition` | – | Jump to where the type of the symbol under the cursor is defined. | read-only |
| `lsp_implementation` | – | Jump to the implementations of the interface or method under the cursor. | read-only |
| `lsp_references` | – | List everywhere the symbol under the cursor is used. | read-only |
| `lsp_hover` | – | Show the documentation and type of the symbol under the cursor. | read-only |
| `lsp_signature_help` | – | Show the parameters of the function call the cursor is inside. | read-only |
| `lsp_rename` | `name` | Rename the symbol under the cursor everywhere the language server knows of. | destructive |
| `lsp_code_action` | – | Offer the language server fixes and refactors available here. |  |
| `format_buffer` | – | Reformat the whole buffer with the attached language server. |  |
| `lsp_restart` | – | Stop the language servers on this buffer and let them attach again. |  |
| `lsp_info` | – | Say which language servers are attached to this buffer. | read-only |

</details>

<details>
<summary><b>diagnostics</b> — 5 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `show_diagnostics` | – | Collect the diagnostics for this buffer into the quickfix list and open it. | read-only |
| `next_diagnostic` | – | Jump to the next error or warning below the cursor. | read-only |
| `previous_diagnostic` | – | Jump back to the error or warning above the cursor. | read-only |
| `show_line_diagnostics` | – | Show the full message of the errors on the current line, in a float. | read-only |
| `toggle_virtual_text` | – | Show or hide the diagnostic messages printed beside the code. |  |

</details>

<details>
<summary><b>quickfix</b> — 8 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `quickfix_open` | – | Open the quickfix window with the current result list. | read-only |
| `quickfix_close` | – | Close the quickfix window. | read-only |
| `quickfix_next` | – | Go to the next entry in the quickfix list. | read-only |
| `quickfix_previous` | – | Go back to the previous entry in the quickfix list. | read-only |
| `loclist_open` | – | Open the location list, this window's own result list. | read-only |
| `loclist_close` | – | Close the location list window. | read-only |
| `loclist_next` | – | Go to the next entry in the location list. | read-only |
| `loclist_previous` | – | Go back to the previous entry in the location list. | read-only |

</details>

<details>
<summary><b>terminal</b> — 2 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `open_terminal` | `where?` split \| tab \| vsplit | Open a shell in a terminal buffer, in a split or a new tab. |  |
| `close_terminal` | – | Close the terminal in this window and end the shell running in it. | destructive |

</details>

<details>
<summary><b>help</b> — 3 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `help_topic` | `topic` | Open the built-in help for a topic, command or option. | read-only |
| `show_messages` | – | Show the recent messages Neovim printed, the :messages history. | read-only |
| `show_version` | – | Say which version of Neovim this is. | read-only |

</details>

<details>
<summary><b>spelling</b> — 4 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `next_misspelling` | – | Jump to the next word the spell checker flags. | read-only |
| `previous_misspelling` | – | Jump back to the previous word the spell checker flags. | read-only |
| `spell_suggest` | – | Suggest correct spellings for the word under the cursor. | read-only |
| `spell_add_word` | – | Teach the spell checker the word under the cursor is spelled right. |  |

</details>

<details>
<summary><b>misc</b> — 4 actions</summary>

| Action | Arguments | What it does | Flags |
| --- | --- | --- | --- |
| `quit_all` | – | Quit Neovim entirely, closing every window and tab. | destructive |
| `reload_config` | – | Re-read your init file, applying config changes without restarting. | destructive |
| `redraw` | – | Redraw the screen, clearing whatever garbled it. | read-only |
| `show_cursor_position` | – | Say which line and column the cursor is on, and how long the file is. | read-only |

</details>
<!-- actions:end -->

Every argument of every action is asked in the same request, so a decision never
costs a second round trip. Actions run inside `nvim_win_call` on the window you
came from, wrapped in `pcall`: a failing action prints into the panel and is never
thrown at you.

## Confidence tiers

Each answer carries a probability. A call's **confidence is the lowest** of them —
the route and every argument — because one wrong argument spoils the result. A
product would answer a different question and would punish actions simply for
taking more arguments.

The policy then reads, in order:

| Tier | When | What happens |
| --- | --- | --- |
| `none` | no action fits, or route probability < `route` (0.5) | `? no confident match (best: goto_line 41%)` |
| `incomplete` | a required argument has no usable value | `? missing: path` |
| `confirm` | destructive, or confidence < `confirm` (0.6) | `vim.ui.select` asks first |
| `auto` | read-only and confidence >= `auto` (0.8) | runs |
| `ready` | everything else at or above `confirm` | runs |

`auto` and `ready` both run: you pressed `<CR>`, that was the click. Set
`always_confirm = true` to be asked every time anyway.

## Health

```vim
:checkhealth jev
```

Checks the Neovim version, `curl`, whether a key is configured (it never prints
it), and the size of the catalog.

## Tests

```bash
nvim --headless --clean -u NONE -l tests/run.lua < /dev/null
```

No plenary, no network. `< /dev/null` is required: the stock `vim.ui.select` reads
stdin and will end a headless process outright, so tests monkeypatch it too.

The screenshots above are regenerated the same way — a real editor, a stubbed
client:

```bash
cd scripts && npm install      # once: neovim + playwright-core, not committed
node scripts/screenshot.mjs    # all four scenes into assets/
node scripts/screenshot.mjs 03 # just the one whose name matches
```

Each scene spawns `nvim --embed`, attaches a 120x34 UI, types the request into
the panel, then paints the cell grid Neovim sent back into a PNG. `JEV_NVIM` and
`CHROMIUM_PATH` override the binaries it reaches for.

## License

MIT. See [LICENSE](LICENSE).
