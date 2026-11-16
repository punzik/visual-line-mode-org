# visual-line-mode-org

Wrap prose without wrapping Org tables.

`visual-line-mode-org-mode` is an experimental Emacs minor mode that keeps
paragraphs wrapped to the window width while displaying each Org table row on a
single screen line. Wide tables are clipped at the window edge; move through the
table or use the scrolling keys below to reveal the remaining columns.

Only the display changes. Your file is not reformatted, and no line breaks are
inserted.

## Project goals

- Make prose and wide tables comfortable to read in the same Org buffer.
- Work with existing Emacs and Org installations, without patching either.
- Keep document contents unchanged, including when viewing read-only buffers.
- Update the table view as you edit or resize a window, with independent views
  when the same buffer is shown in multiple windows.
- Provide predictable keyboard navigation and access to off-screen columns.
- Preserve familiar Org features, including indentation, hidden emphasis
  markers, and supported table borders from `org-pretty-table-mode`.
- Be easy to enable and disable, restoring the previous display settings when
  disabled.

## Requirements

- Emacs **30.1 or newer**.
- Org **9.7 or newer**.
- A **monospaced font** for table text.

Tested with Emacs 30.2 and Org 9.8.8 in both graphical and terminal Emacs.
`org-pretty-table-mode` is optional; compatibility has been tested with version
1.0.0 and its standard single- and double-line borders.

## Installation

Download [`visual-line-mode-org.el`](visual-line-mode-org.el), or clone this
repository. Place the file in a directory on your Emacs `load-path`, for example:

```text
~/.emacs.d/lisp/visual-line-mode-org/visual-line-mode-org.el
```

Add this to your Emacs configuration:

```elisp
(add-to-list 'load-path
             (expand-file-name "~/.emacs.d/lisp/visual-line-mode-org/"))
(require 'visual-line-mode-org)
```

Restart Emacs or evaluate those forms. In an Org buffer, run:

```text
M-x visual-line-mode-org-mode
```

To enable it automatically in Org buffers, also add:

```elisp
(add-hook 'org-mode-hook #'visual-line-mode-org-mode)
```

You do not need to enable `visual-line-mode` separately: this mode enables it
when necessary.

### Try it without changing your configuration

1. Run `M-x load-file` and select `visual-line-mode-org.el`.
2. Open an Org file, such as the included [`example.org`](example.org).
3. Run `M-x visual-line-mode-org-mode`.

Run the same command again to disable the mode. Any `visual-line-mode` setting
that was already enabled remains enabled; otherwise, the previous display
settings are restored.

## Scrolling wide tables

With the cursor inside a table:

| Key | Action |
| --- | --- |
| `C-c <right>` | Reveal columns farther to the right. |
| `C-c <left>` | Reveal columns farther to the left. |
| `C-u 20 C-c <right>` | Scroll right by 20 text columns. |
| `C-u 20 C-c <left>` | Scroll left by 20 text columns. |

Without a numeric prefix, scrolling moves roughly half a window at a time.
These commands also move the cursor into the visible area.

The view follows the cursor when it moves beyond the visible columns. All rows
of the current table scroll together; other tables and surrounding prose do not
shift horizontally. Leaving the table resets its horizontal offset. Each window
has its own table view.

**Use these keys instead of Emacs's native `scroll-left` and `scroll-right`.**
Native horizontal scrolling disables wrapping for the entire window, including
prose.

## Keyboard navigation

With standard Org bindings, no additional key configuration is needed:

| Keys | Inside a table |
| --- | --- |
| Up / Down, `C-p` / `C-n` | Move by table rows, preserving the column. |
| Home / End | Move to the beginning or end of the underlying table row. |
| PageUp / PageDown | Scroll using the clipped table layout. |

Custom PageUp/PageDown commands that call `next-line` or `previous-line` with a
line count are also supported: inside tables they count actual table rows,
not wrapped screen lines.

Outside tables, normal Org and Visual Line navigation is retained, with one
intentional boundary rule:

> When Up/Down or PageUp/PageDown moves between a table and ordinary text, the
> cursor moves to the beginning of the destination's **logical line**, and its
> remembered movement column is reset.

A logical line is a line in the file, even if it wraps across several screen
lines. Blank lines count as ordinary text. The boundary rule does not apply to
mouse clicks or search, and does not reset the column when moving within a
table or within ordinary text.

## Compatibility and limitations

This is an experimental package. It uses window-specific overlays to clip rows,
because Emacs does not provide a per-line `truncate-lines` setting. It does not
open a separate table-editing window or modify the contents of your document.

- **Supported Org features:** `org-indent-mode`, hidden emphasis markers,
  tabs, wide characters, and line numbers are covered by tests. Table-like
  lines inside source or example blocks are not treated as tables.
- **Pretty table borders:** `org-pretty-table-mode` works with its standard
  single- and double-line monospaced borders. Enable the modes in either order;
  disabling this mode leaves the pretty-table formatting intact. Neither
  `org-pretty-table` itself nor its original formatting properties are modified.
- **Fonts and display changes:** proportional fonts, differently scaled text
  within a table, arbitrary display replacements, other table-rendering
  packages, and Org's shrunk columns are not supported.
- **Mouse and search:** the boundary-reset rule deliberately leaves them alone,
  but full mouse and incremental-search integration with clipped text has not
  been verified.
- **Large documents:** table views are rebuilt across the buffer after commands
  and edits. Performance has not yet been optimized for very large files.

If the display looks wrong, disable `visual-line-mode-org-mode` to return to the
previous display settings. When reporting a problem, include your Emacs and Org
versions, relevant modes and keybindings, and a small example table.

## License

GNU GPL version 3. See [LICENSE](LICENSE).
