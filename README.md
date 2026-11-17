# visual-line-table-mode

Wrap prose without wrapping Org or Markdown tables.

`visual-line-table-mode` is an experimental Emacs minor mode that keeps
paragraphs wrapped to the window width while displaying each table row on a
single screen line. Wide tables are clipped at the window edge; move through the
table or use the scrolling keys below to reveal the remaining columns.

It works in `org-mode`, `markdown-mode`, and `gfm-mode`.

Only the display changes. Your file is not reformatted, and no line breaks are
inserted.

## Project goals

- Make prose and wide tables comfortable to read in the same Org or Markdown buffer.
- Work with existing Emacs major modes, without patching them.
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
- Org **9.7 or newer** (bundled with supported Emacs versions).
- [`markdown-mode`](https://github.com/jrblevin/markdown-mode) for Markdown
  buffers; it is not needed when using this package only with Org.
- A **monospaced font** for table text.

Tested with Emacs 30.2, Org 9.8.8, and Markdown mode 2.9-alpha in both graphical
and terminal Emacs.
`org-pretty-table-mode` is optional; compatibility has been tested with version
1.0.0 and its standard single- and double-line borders.

## Installation

Download [`visual-line-table-mode.el`](visual-line-table-mode.el), or clone this
repository. Place the file in a directory on your Emacs `load-path`, for example:

```text
~/.emacs.d/lisp/visual-line-table-mode/visual-line-table-mode.el
```

Add this to your Emacs configuration:

```elisp
(add-to-list 'load-path
             (expand-file-name "~/.emacs.d/lisp/visual-line-table-mode/"))
(require 'visual-line-table-mode)
```

Restart Emacs or evaluate those forms. In an Org or Markdown buffer, run:

```text
M-x visual-line-table-mode
```

To enable it automatically in Org buffers, also add:

```elisp
(add-hook 'org-mode-hook #'visual-line-table-mode)
```

For Markdown (including `gfm-mode`, which also runs `markdown-mode-hook`):

```elisp
(add-hook 'markdown-mode-hook #'visual-line-table-mode)
```

You do not need to enable `visual-line-mode` separately: this mode enables it
when necessary.

### Try it without changing your configuration

1. Run `M-x load-file` and select `visual-line-table-mode.el`.
2. Open an Org file, such as [`example.org`](example.org), or a Markdown file
   with pipe tables, such as [`example.md`](example.md).
3. Run `M-x visual-line-table-mode`.

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

With standard Org or Markdown bindings, no additional key configuration is needed:

| Keys | Inside a table |
| --- | --- |
| Up / Down, `C-p` / `C-n` | Move by table rows, preserving the column. |
| Home / End | Move to the beginning or end of the underlying table row. |
| PageUp / PageDown | Scroll using the clipped table layout. |

Custom PageUp/PageDown commands that call `next-line` or `previous-line` with a
line count are also supported: inside tables they count actual table rows,
not wrapped screen lines.

Outside tables, normal major-mode and Visual Line navigation is retained, with one
intentional boundary rule:

> When Up/Down or PageUp/PageDown moves between a table and ordinary text, the
> cursor moves to the beginning of the destination's **logical line**, and its
> remembered movement column is reset.

A logical line is a line in the file, even if it wraps across several screen
lines. Blank lines count as ordinary text. The boundary rule does not apply to
mouse clicks or search, and does not reset the column when moving within a
table or within ordinary text.

## Mode-line column numbers

Column indicators in the standard mode line and Doom Modeline show the absolute
column in the original table row, not the column within its visible portion.
Table source markup is included in this count, and tabs use their usual column
widths. Your zero-based or one-based numbering preference is preserved.

The existing mode-line layout is retained. Outside tables, normal column
reporting is unchanged. If you replace your mode-line layout while this mode is
active, toggle `visual-line-table-mode` off and on to attach the new layout.

## Markdown tables

Both `markdown-mode` and `gfm-mode` support pipe tables with or without outer
pipes:

```markdown
Name | Description
:--- | ---:
one  | A wide cell
```

A table must have a header and a delimiter row with the same number of cells.
Each delimiter cell contains at least three dashes, optionally surrounded by
alignment colons. Escaped pipes (`\|`) and pipes inside matched backtick code
spans are not cell separators. Body rows may have missing or extra cells,
including a single cell without pipes. A blank line or a new block, such as a
heading, list, or code fence, ends the table.

Fenced code blocks (including unclosed fences) and indented code blocks are not
tables. Tables nested inside lists or blockquotes, HTML tables, grid tables, and
third-party Markdown table renderers are not supported. The package does not
change Markdown's table-editing commands; recognition here may be broader than
that provided by the major mode.

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
- **Markdown display:** pipe tables use the same clipping and scrolling as Org
  tables. Markdown-specific markup-hiding and table-rendering packages have not
  been verified.
- **Fonts and display changes:** proportional fonts, differently scaled text
  within a table, arbitrary display replacements, other table-rendering
  packages, and Org's shrunk columns are not supported.
- **Mouse and search:** the boundary-reset rule deliberately leaves them alone,
  but full mouse and incremental-search integration with clipped text has not
  been verified.
- **Large documents:** table views are rebuilt across the buffer after commands
  and edits. Performance has not yet been optimized for very large files.

If the display looks wrong, disable `visual-line-table-mode` to return to the
previous display settings. When reporting a problem, include your Emacs and Org
versions (and Markdown mode version when applicable), relevant modes and
keybindings, and a small example table.

## Tests

Run the ERT suite from the repository root:

```sh
emacs -Q --batch -L . -l test/visual-line-table-mode-test.el \
  -f ert-run-tests-batch-and-exit
```

With `-Q`, add `-L /path/to/markdown-mode` to include Markdown tests; otherwise
those tests are skipped if the library is unavailable. Interactive keyboard,
mode-line, and screen-coordinate tests are skipped in batch. To run them, load
the package and test file in an interactive Emacs and use `M-x ert` with selector
`t`. Page-navigation tests assume a sufficiently large frame (for example, a
120-column, 50-row terminal).

## License

GNU GPL version 3. See [LICENSE](LICENSE).
