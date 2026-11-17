# Markdown table viewport

This paragraph demonstrates normal wrapping. Enable `visual-line-mode-org-mode` in `markdown-mode` or `gfm-mode`: prose should wrap to the window width while every table row remains on a single screen line. Use `C-c <right>` and `C-c <left>` inside a table to reveal hidden columns.

Name | Description | Notes
:--- | :--- | ---:
alpha | A deliberately long description to demonstrate horizontal clipping in a narrow window without changing the document or wrapping this table row across multiple screen lines. | first
beta | Another deliberately long description to demonstrate that all rows in the active table share the same horizontal offset, independently in each window. | second

| Name | Literal pipes | Code |
| --- | --- | --- |
| escaped | a\|b | `x|y` |
| backticks | c\|d | ``x`|y`` |

The following is a code block, not a table viewport:

```text
Name | Description
--- | ---
example | This table-looking text remains ordinary code block content and is not clipped by visual-line-mode-org-mode, even when the text is wider than the window.
```
