;;; visual-line-table-mode.el --- Wrap prose, clip Org and Markdown tables -*- lexical-binding: t; -*-

;; Version: 0.1.8
;; Package-Requires: ((emacs "30.1") (org "9.7"))
;; Keywords: convenience, outlines

;;; Commentary:

;; Experimental minor mode.  Emacs cannot truncate individual buffer lines.
;; This mode instead conceals the parts of Org table rows outside a viewport
;; using window-specific overlays.  Native horizontal scrolling must not be
;; used: it would also truncate prose.  See README.md for limitations.

;;; Code:

(require 'org)
(require 'org-element)
(require 'cl-lib)
(require 'subr-x)

(declare-function markdown-code-block-at-point-p "markdown-mode" (&optional pos))
(declare-function markdown-beginning-of-line "markdown-mode" (&optional n))
(declare-function markdown-end-of-line "markdown-mode" (&optional n))
(defvar markdown-regex-header-atx)
(defvar markdown-regex-list)
(defvar markdown-regex-blockquote)
(defvar markdown-regex-hr)

(defgroup visual-line-table nil
  "Wrap prose and clip tables in Org and Markdown buffers."
  :group 'org-appearance)

(defvar-local visual-line-table--overlays nil)
(defvar-local visual-line-table--markdown-cache nil)
(defvar-local visual-line-table--markdown-tick nil)
(defvar-local visual-line-table--windows nil)
(defvar-local visual-line-table--enabled-visual-line nil)
(defvar-local visual-line-table--updating nil)
(defvar-local visual-line-table--invisibility-state nil)
(defvar-local visual-line-table--owned-invisibility-spec nil)
(defvar-local visual-line-table--line-move-state nil)
(defvar-local visual-line-table--mode-line-state nil)
(defconst visual-line-table--mode-line-form
  '(:eval (visual-line-table--format-mode-line)))
(defvar visual-line-table--navigation-origin nil
  "Buffer, window, text tick and table status before vertical navigation.")
(defvar visual-line-table--line-move-buffer nil
  "Buffer whose navigation setting is temporarily changed for a command.")
(defvar visual-line-table-mode)
(defvar org-pretty-table-mode)

(defun visual-line-table--reset-column-cache ()
  "Invalidate Emacs's cached column without changing point."
  (save-excursion
    (let ((inhibit-field-text-motion t))
      (beginning-of-line)
      (current-column))))

(defun visual-line-table--original-mode-line ()
  "Return this buffer's original, possibly inherited, mode-line format."
  (if (car visual-line-table--mode-line-state)
      (cdr visual-line-table--mode-line-state)
    (default-value 'mode-line-format)))

(defun visual-line-table--format-mode-line ()
  "Render the original mode line using source columns inside tables."
  (let ((buffer-invisibility-spec
         (if (visual-line-table--table) nil buffer-invisibility-spec)))
    (unwind-protect
        (progn
          (visual-line-table--reset-column-cache)
          ;; Fully render deferred fields before restoring invisibility.
          ;; Escape literal percent signs for the outer mode-line renderer.
          (replace-regexp-in-string
           "%" (lambda (match) (concat match match))
           (format-mode-line (visual-line-table--original-mode-line)) t t))
      ;; Do not leak the absolute-column cache into ordinary navigation.
      (visual-line-table--reset-column-cache))))

(defun visual-line-table--install-mode-line ()
  "Keep the existing mode line and scope column calculations to rendering."
  (setq visual-line-table--mode-line-state
        (cons (local-variable-p 'mode-line-format) mode-line-format))
  (when mode-line-format
    (setq-local mode-line-format
                (list visual-line-table--mode-line-form))))

(defun visual-line-table--restore-mode-line ()
  "Remove our wrapper without discarding subsequent layout changes."
  (when visual-line-table--mode-line-state
    (if (equal mode-line-format (list visual-line-table--mode-line-form))
        (if (car visual-line-table--mode-line-state)
            (setq-local mode-line-format
                        (cdr visual-line-table--mode-line-state))
          (kill-local-variable 'mode-line-format))
      (let ((restored
             (cl-subst (visual-line-table--original-mode-line)
                       visual-line-table--mode-line-form mode-line-format
                       :test #'equal)))
        (unless (equal restored mode-line-format)
          (setq-local mode-line-format restored))))
    (setq visual-line-table--mode-line-state nil)))

(defun visual-line-table--clear ()
  "Remove only overlays owned by this mode."
  (mapc #'delete-overlay visual-line-table--overlays)
  (setq visual-line-table--overlays nil))

(defun visual-line-table--width (window)
  "Return usable text columns in WINDOW, excluding line numbers and fringes."
  (max 1 (1- (floor (window-max-chars-per-line window)))))

(defun visual-line-table--state (window)
  "Return or create viewport state for WINDOW."
  (or (gethash window visual-line-table--windows)
      (let ((state (list :start (make-marker) :offset 0
                         :hscroll (window-hscroll window))))
        (puthash window state visual-line-table--windows)
        ;; Native hscroll forces truncation even with `truncate-lines' nil.
        (set-window-hscroll window 0)
        state)))

(defun visual-line-table--markdown-cells ()
  "Return this row's trimmed cells, or nil if it has no unquoted pipes.
Escaped characters and matched backtick code spans cannot delimit cells."
  (let* ((text (buffer-substring-no-properties
                (line-beginning-position) (line-end-position)))
         (length (length text)) (position 0) (start 0) cells)
    (while (< position length)
      (pcase (aref text position)
        (?\\ (setq position (min length (+ position 2))))
        (?`
         (let* ((end (progn (string-match "`+" text position) (match-end 0)))
                (size (- end position)) (search end) close)
           (while (and (not close) (string-match "`+" text search))
             (setq search (match-end 0))
             (when (= (- search (match-beginning 0)) size)
               (setq close search)))
           (setq position (or close end))))
        (?|
         (push (string-trim (substring text start position)) cells)
         (setq position (1+ position) start position))
        (_ (setq position (1+ position)))))
    (when cells
      (push (string-trim (substring text start)) cells)
      (setq cells (nreverse cells))
      (when (equal (car cells) "") (setq cells (cdr cells)))
      (when (equal (car (last cells)) "") (setq cells (butlast cells)))
      cells)))

(defconst visual-line-table--markdown-fence-regexp
  "^ \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)$"
  "A possible Markdown code fence, with fence and info string groups.")

(defun visual-line-table--markdown-skip-fence ()
  "If this line opens a code fence, skip its block and return non-nil.
Handle unclosed fences too: markdown-mode may only mark their opener."
  (when (and (looking-at visual-line-table--markdown-fence-regexp)
             (or (eq (char-after (match-beginning 1)) ?~)
                 (not (string-search "`" (match-string 2)))))
    (let* ((fence (match-string 1))
           (close (format "^ \\{0,3\\}%c\\{%d,\\}[ \t]*$"
                          (aref fence 0) (length fence))))
      (forward-line 1)
      (if (re-search-forward close nil t)
          (forward-line 1)
        (goto-char (point-max))))
    t))

(defun visual-line-table--markdown-row (&optional body)
  "Return cells at point outside Markdown code blocks, or nil.
With BODY, allow a single cell without pipes, but stop at block boundaries."
  (unless (or (looking-at visual-line-table--markdown-fence-regexp)
              (markdown-code-block-at-point-p)
              (looking-at-p "^[ \t]*$")
              (looking-at-p markdown-regex-header-atx)
              (looking-at-p markdown-regex-list)
              (looking-at-p markdown-regex-blockquote)
              (looking-at-p markdown-regex-hr)
              (looking-at-p "^ \\{0,3\\}<[/!a-zA-Z?]"))
    (or (visual-line-table--markdown-cells)
        (when body
          (list (string-trim (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position))))))))

(defun visual-line-table--markdown-tables ()
  "Return cached Markdown table bounds, rebuilding after text edits.
A table needs a header and a matching delimiter row.  Body rows may
have fewer or more cells, as in GFM.  Bounds exclude the following line."
  (unless (eql visual-line-table--markdown-tick (buffer-chars-modified-tick))
    (save-excursion
      (save-restriction
        (widen)
        (save-match-data
          ;; markdown-mode records fenced and indented code during this pass.
          (syntax-propertize (point-max))
          (goto-char (point-min))
          (let (previous previous-start tables)
            (while (not (eobp))
              (if (visual-line-table--markdown-skip-fence)
                  (setq previous nil previous-start nil)
                (let ((cells (visual-line-table--markdown-row)))
                  (if (and previous cells (= (length previous) (length cells))
                           (cl-every (lambda (cell)
                                       (string-match-p "\\`:?-\\{3,\\}:?\\'" cell))
                                     cells))
                      (let ((start previous-start))
                        (forward-line 1)
                        (while (and (not (eobp)) (visual-line-table--markdown-row t))
                          (forward-line 1))
                        (push (cons start (point)) tables)
                        (setq previous nil previous-start nil))
                    (setq previous cells previous-start (point))
                    (forward-line 1)))))
            (setq visual-line-table--markdown-cache (nreverse tables)
                  visual-line-table--markdown-tick (buffer-chars-modified-tick)))))))
  visual-line-table--markdown-cache)

(defun visual-line-table--table ()
  "Return bounds of the Org or Markdown table at point, or nil.
Table-looking lines in code blocks are not tables."
  (if (derived-mode-p 'markdown-mode)
      (let ((position (point)))
        (cl-find-if (lambda (bounds)
                      (and (<= (car bounds) position)
                           (or (< position (cdr bounds))
                               (and (= position (cdr bounds) (point-max))
                                    (not (bolp))))))
                    (visual-line-table--markdown-tables)))
    (when (org-at-table-p)
      (let ((table (org-element-lineage (org-element-context) '(table) t)))
        (when (and table
                   (eq (org-element-property :type table) 'org))
          (cons (org-element-property :begin table)
                (org-element-property :end table)))))))

(defun visual-line-table--overlay (start end window)
  "Create an owned overlay from START to END in WINDOW."
  (when (< start end)
    (let ((overlay (make-overlay start end nil nil nil)))
      (overlay-put overlay 'window window)
      (overlay-put overlay 'visual-line-table t)
      (push overlay visual-line-table--overlays)
      overlay)))

(defun visual-line-table--hide (start end window)
  "Conceal START to END in WINDOW without changing the buffer text."
  (when-let* ((overlay (visual-line-table--overlay start end window)))
    (overlay-put overlay 'invisible 'visual-line-table)))

(defun visual-line-table--pretty-runs (start end)
  "Return length-preserving org-pretty-table display runs in START..END.
Each entry is (BEGIN END STRING).  Other display specifications are left alone."
  (when (bound-and-true-p org-pretty-table-mode)
    (let ((position start) runs)
      (while (< position end)
        (let ((next (next-single-property-change position 'display nil end))
              (display (get-text-property position 'display)))
          (when (and (stringp display)
                     (= (length display) (- next position))
                     (= (string-width display) (length display))
                     (string-match-p "\\`[-+|]+\\'"
                                     (buffer-substring-no-properties position next)))
            (push (list position next display) runs))
          (setq position next)))
      (nreverse runs))))

(defun visual-line-table--pretty-view (left right window runs)
  "Show only the visible part LEFT..RIGHT of pretty display RUNS in WINDOW."
  (dolist (run runs)
    (let* ((begin (nth 0 run)) (end (nth 1 run)) (display (nth 2 run))
           (mask (visual-line-table--overlay begin end window)))
      ;; A non-replacing display spec shadows the underlying replacement.
      ;; Invisible overlays can then hide the parts outside the viewport.
      (overlay-put mask 'display '(when nil . ""))
      (overlay-put mask 'priority 1)
      (let ((position (max begin left)) (limit (min end right)))
        (while (< position limit)
          (let ((glyph (visual-line-table--overlay position (1+ position) window)))
            (overlay-put glyph 'display (substring display (- position begin)
                                                  (1+ (- position begin))))
            (overlay-put glyph 'priority 2))
          (setq position (1+ position)))))))

(defun visual-line-table--column-position (column end)
  "Find a position at or before COLUMN, no later than END.
Do not split a wide character or tab across the viewport edge."
  (move-to-column column)
  (when (and (> (current-column) column) (> (point) (line-beginning-position)))
    (backward-char))
  (min (point) end))

(defun visual-line-table--row-width (window width)
  "Return usable WIDTH for the current row in WINDOW, excluding its prefix."
  (let ((prefix (get-char-property (line-beginning-position) 'line-prefix window)))
    (max 1 (- width (if (stringp prefix) (string-width prefix) 0)))))

(defun visual-line-table--row-span (window offset width)
  "Return visible bounds of this row at OFFSET and WIDTH in WINDOW."
  (let* ((end (line-end-position))
         (available (visual-line-table--row-width window width))
         (runs (visual-line-table--pretty-runs (line-beginning-position) end))
         masks)
    (unwind-protect
        (progn
          ;; Pretty replacements are one glyph per source character, but a
          ;; whole dash run is otherwise treated as one indivisible object.
          (dolist (run runs)
            (let ((mask (make-overlay (car run) (cadr run))))
              (overlay-put mask 'display '(when nil . ""))
              (overlay-put mask 'priority 1)
              (push mask masks)))
          (let* ((left (visual-line-table--column-position offset end))
                 (motion (compute-motion left '(0 . 0) end (cons available 0)
                                         most-positive-fixnum nil window))
                 (right (car motion)))
            (when (and (> (nth 1 motion) available) (> right left))
              (setq right (1- right)))
            (cons left right)))
      (mapc #'delete-overlay masks))))

(defun visual-line-table--refresh (&rest _ignored)
  "Rebuild clipping overlays for windows displaying this buffer."
  (when (and visual-line-table-mode (not visual-line-table--updating))
    (let ((visual-line-table--updating t)
          (ranges nil)
          (pretty-views nil))
      (visual-line-table--clear)
      (maphash (lambda (window state)
                 (unless (and (window-live-p window)
                              (eq (window-buffer window) (current-buffer)))
                   (set-marker (plist-get state :start) nil)
                   (remhash window visual-line-table--windows)))
               visual-line-table--windows)
      (save-excursion
        (save-restriction
          (widen)
          (when (bound-and-true-p org-pretty-table-mode)
            (font-lock-ensure))
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (let* ((state (visual-line-table--state window))
                   (width (visual-line-table--width window))
                   (cursor (window-point window))
                   (table (progn (goto-char cursor)
                                 (visual-line-table--table)))
                   (marker (plist-get state :start))
                   (offset (plist-get state :offset)))
              (unless (and table (equal (marker-position marker) (car table)))
                (set-marker marker (car table))
                (setq offset 0))
              (when table
                (goto-char cursor)
                (let ((column (current-column))
                      (available (visual-line-table--row-width window width)))
                  ;; Leave one column for the cursor, including at end of line.
                  (cond ((< column offset) (setq offset column))
                        ((>= column (+ offset available))
                         (setq offset (max 0 (- column available -1)))))))
              (when table
                (goto-char cursor)
                (let ((span (visual-line-table--row-span window offset width)))
                  ;; Tabs, wide characters and line prefixes may shorten the
                  ;; viewport.  Keep point visible against the actual bounds.
                  (when (or (< cursor (car span))
                            (and (>= cursor (cdr span))
                                 (< cursor (line-end-position))))
                    (goto-char cursor)
                    (setq offset (current-column)))))
              (setf (plist-get state :offset) offset)
              (goto-char (point-min))
              (while (re-search-forward (if (derived-mode-p 'markdown-mode)
                                           "^." org-table-line-regexp) nil t)
                (beginning-of-line)
                (let ((bounds (visual-line-table--table)))
                  (when bounds
                    (let* ((start (line-beginning-position))
                           (end (line-end-position))
                           (runs (visual-line-table--pretty-runs start end))
                           (span (visual-line-table--row-span
                                  window (if (equal bounds table) offset 0) width)))
                      (push (list start (car span) window) ranges)
                      (push (list (cdr span) end window) ranges)
                      (when runs
                        (push (list (car span) (cdr span) window runs) pretty-views)))))
                (forward-line 1))))))
      ;; Defer overlays until all windows are measured.  Keep Org's own
      ;; invisibility (emphasis, links, folding) intact throughout measurement.
      (dolist (range ranges)
        (apply #'visual-line-table--hide range))
      (dolist (view pretty-views)
        (apply #'visual-line-table--pretty-view view)))))

(defun visual-line-table-scroll-left (&optional columns)
  "Reveal COLUMNS more columns to the right in the table at point.
With a negative argument, reveal columns to the left instead.
This moves point into the viewport so automatic following does not undo it."
  (interactive "P")
  (unless visual-line-table-mode
    (user-error "Enable visual-line-table-mode first"))
  (unless (visual-line-table--table)
    (user-error "Point is not in a table"))
  (visual-line-table--refresh)
  (let* ((window (selected-window))
         (state (visual-line-table--state window))
         (width (visual-line-table--width window))
         (step (if columns (prefix-numeric-value columns) (max 1 (/ width 2))))
         (_unclip (visual-line-table--clear))
         (last-column (save-excursion (end-of-line) (current-column)))
         (offset (min (max 0 (1- last-column))
                      (max 0 (+ (plist-get state :offset) step)))))
    (setf (plist-get state :offset) offset)
    (move-to-column offset)
    (visual-line-table--refresh)))

(defun visual-line-table-scroll-right (&optional columns)
  "Reveal COLUMNS more columns to the left in the table at point."
  (interactive "P")
  (visual-line-table-scroll-left
   (- (if columns (prefix-numeric-value columns)
        (max 1 (/ (visual-line-table--width (selected-window)) 2))))))

(defun visual-line-table-beginning-of-line (&optional n)
  "Run the major mode's beginning-of-line, using logical lines in tables.
With N, move forward N - 1 lines first."
  (interactive "^p")
  (let ((visual-line-mode (and visual-line-mode
                               (not (visual-line-table--table)))))
    (if (derived-mode-p 'markdown-mode)
        (markdown-beginning-of-line n)
      (org-beginning-of-line n))))

(defun visual-line-table-end-of-line (&optional n)
  "Run the major mode's end-of-line, using logical lines in tables.
With N, move forward N - 1 lines first."
  (interactive "^p")
  (let ((visual-line-mode (and visual-line-mode
                               (not (visual-line-table--table)))))
    (if (derived-mode-p 'markdown-mode)
        (markdown-end-of-line n)
      (org-end-of-line n))))

(defun visual-line-table-move-beginning-of-line (&optional n)
  "Handle native beginning-of-line bindings without changing prose behavior."
  (interactive "^p")
  (if (visual-line-table--table)
      (visual-line-table-beginning-of-line n)
    (let ((visual-line-table-mode nil))
      (funcall (or (command-remapping #'move-beginning-of-line)
                   #'move-beginning-of-line)
               n))))

(defun visual-line-table-move-end-of-line (&optional n)
  "Handle native end-of-line bindings without changing prose behavior."
  (interactive "^p")
  (if (visual-line-table--table)
      (visual-line-table-end-of-line n)
    (let ((visual-line-table-mode nil))
      (funcall (or (command-remapping #'move-end-of-line) #'move-end-of-line) n))))

(defun visual-line-table--scroll-page (command arg)
  "Run native scroll COMMAND with ARG using the rendered table geometry."
  (if (not (and visual-line-table-mode (visual-line-table--table)))
      (funcall command arg)
    (let* ((state (visual-line-table--state (selected-window)))
           (offset (plist-get state :offset))
           (column (let ((buffer-invisibility-spec nil)) (current-column)))
           (visual-column (current-column)))
      ;; Native scrolling miscalculates backward pages from a concealed row
      ;; prefix.  Measure the page with a zero-offset table viewport instead.
      (beginning-of-line)
      (visual-line-table--refresh)
      (unwind-protect
          (funcall command arg)
        (visual-line-table--clear)
        (setf (plist-get state :offset) offset)
        (if (visual-line-table--table)
            (if goal-column
                (move-to-column goal-column)
              (let ((buffer-invisibility-spec nil)) (move-to-column column)))
          (vertical-motion (cons visual-column 0)))))))

(defun visual-line-table-scroll-up-command (&optional arg)
  "Scroll a rendered page up, accepting the native prefix ARG."
  (interactive "^P")
  (visual-line-table--scroll-page #'scroll-up-command arg))

(defun visual-line-table-scroll-down-command (&optional arg)
  "Scroll a rendered page down, accepting the native prefix ARG."
  (interactive "^P")
  (visual-line-table--scroll-page #'scroll-down-command arg))

(put 'visual-line-table-scroll-up-command 'scroll-command t)
(put 'visual-line-table-scroll-down-command 'scroll-command t)

(defvar visual-line-table-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c <right>") #'visual-line-table-scroll-left)
    (define-key map (kbd "C-c <left>") #'visual-line-table-scroll-right)
    map)
  "Keymap for `visual-line-table-mode'.")

;; Install outside `defvar' so reloading an already loaded package updates it.
(define-key visual-line-table-mode-map [remap org-beginning-of-line]
            #'visual-line-table-beginning-of-line)
(define-key visual-line-table-mode-map [remap org-end-of-line]
            #'visual-line-table-end-of-line)
(define-key visual-line-table-mode-map [remap markdown-beginning-of-line]
            #'visual-line-table-beginning-of-line)
(define-key visual-line-table-mode-map [remap markdown-end-of-line]
            #'visual-line-table-end-of-line)
;; Remapping is not recursive: the usual Home/End bindings name these
;; commands, which Org itself remaps.  Handle the original commands too.
(define-key visual-line-table-mode-map [remap move-beginning-of-line]
            #'visual-line-table-move-beginning-of-line)
(define-key visual-line-table-mode-map [remap move-end-of-line]
            #'visual-line-table-move-end-of-line)
(define-key visual-line-table-mode-map [remap scroll-up-command]
            #'visual-line-table-scroll-up-command)
(define-key visual-line-table-mode-map [remap scroll-down-command]
            #'visual-line-table-scroll-down-command)

(defun visual-line-table--restore-line-move ()
  "Restore navigation in the originating buffer, even after a buffer switch."
  (when (buffer-live-p visual-line-table--line-move-buffer)
    (with-current-buffer visual-line-table--line-move-buffer
      (when visual-line-table--line-move-state
        (if (car visual-line-table--line-move-state)
            (setq-local line-move-visual (cdr visual-line-table--line-move-state))
          (kill-local-variable 'line-move-visual))
        (setq visual-line-table--line-move-state nil))))
  (setq visual-line-table--line-move-buffer nil)
  (remove-hook 'post-command-hook #'visual-line-table--restore-line-move))

(defun visual-line-table--vertical-command-p ()
  "Whether this is vertical keyboard navigation, excluding active search."
  (and (not (bound-and-true-p isearch-mode))
       (or (memq this-command '(next-line previous-line
                               scroll-up-command scroll-down-command
                               visual-line-table-scroll-up-command
                               visual-line-table-scroll-down-command))
           ;; Page keys may call user-defined functions or anonymous lambdas.
           (and last-command-event
                (memq (event-basic-type last-command-event)
                      '(up down prior next kp-up kp-down kp-prior kp-next))))))

(defun visual-line-table--reset-boundary-column ()
  "Reset the column after vertical navigation across a table boundary."
  (let ((origin visual-line-table--navigation-origin))
    (setq visual-line-table--navigation-origin nil)
    (when (and origin
               (eq (nth 0 origin) (current-buffer))
               (eq (nth 1 origin) (selected-window))
               (= (nth 2 origin) (buffer-chars-modified-tick))
               (not (eq (nth 3 origin)
                        (and (visual-line-table--table) t))))
      (visual-line-table--clear)
      (beginning-of-line)
      (setq goal-column nil
            temporary-goal-column 0))))

(defun visual-line-table--pre-command ()
  "Let commands operate without this mode's clipping overlays."
  (visual-line-table--restore-line-move)
  (setq visual-line-table--navigation-origin
        (when (visual-line-table--vertical-command-p)
          (list (current-buffer) (selected-window) (buffer-chars-modified-tick)
                (and (visual-line-table--table) t))))
  ;; Page scrolling needs the clipped geometry, including when starting in
  ;; prose with a table elsewhere in the same window.
  (unless (memq this-command '(scroll-up-command scroll-down-command
                              visual-line-table-scroll-up-command
                              visual-line-table-scroll-down-command))
    (visual-line-table--clear))
  ;; User commands may call `next-line' or `previous-line' indirectly (for
  ;; example, PageDown bound to a lambda that moves 35 lines).
  (when (visual-line-table--table)
    (setq visual-line-table--line-move-state
          (cons (local-variable-p 'line-move-visual) line-move-visual))
    (setq visual-line-table--line-move-buffer (current-buffer))
    (setq-local line-move-visual nil)
    ;; The command may switch buffers, so a local post-command hook alone
    ;; cannot guarantee restoration.  This global hook lasts one command.
    (add-hook 'post-command-hook #'visual-line-table--restore-line-move)))

(defun visual-line-table--post-command ()
  "Restore normal prose navigation before Emacs adjusts point."
  ;; Do not clip here: point adjustment runs after post-command hooks.
  ;; A hidden emphasis marker could merge with our hidden prefix and make
  ;; backward adjustment jump to the preceding row.  Clip at redisplay.
  (visual-line-table--restore-line-move)
  (visual-line-table--reset-boundary-column))

(defun visual-line-table--disable ()
  "Remove hooks and restore display state."
  (setq visual-line-table--navigation-origin nil)
  (visual-line-table--restore-line-move)
  (visual-line-table--restore-mode-line)
  (remove-hook 'pre-command-hook #'visual-line-table--pre-command t)
  (remove-hook 'post-command-hook #'visual-line-table--post-command t)
  (remove-hook 'pre-redisplay-functions #'visual-line-table--refresh t)
  (remove-hook 'after-change-functions #'visual-line-table--refresh t)
  (remove-hook 'window-size-change-functions #'visual-line-table--refresh t)
  (remove-hook 'window-buffer-change-functions #'visual-line-table--refresh t)
  (remove-hook 'change-major-mode-hook #'visual-line-table--disable t)
  (visual-line-table--clear)
  (when visual-line-table--windows
    (maphash (lambda (window state)
               (set-marker (plist-get state :start) nil)
               (when (and (window-live-p window)
                          (eq (window-buffer window) (current-buffer)))
                 (set-window-hscroll window (plist-get state :hscroll))))
             visual-line-table--windows))
  (setq visual-line-table--windows nil
        visual-line-table--markdown-cache nil
        visual-line-table--markdown-tick nil)
  (when visual-line-table--invisibility-state
    (if (equal buffer-invisibility-spec
               visual-line-table--owned-invisibility-spec)
        (if (car visual-line-table--invisibility-state)
            (setq-local buffer-invisibility-spec
                        (cdr visual-line-table--invisibility-state))
          (kill-local-variable 'buffer-invisibility-spec))
      ;; Preserve categories other owners added while this mode was active.
      (unless (or (eq (cdr visual-line-table--invisibility-state) t)
                  (member 'visual-line-table
                          (cdr visual-line-table--invisibility-state)))
        (remove-from-invisibility-spec 'visual-line-table)))
    (setq visual-line-table--invisibility-state nil
          visual-line-table--owned-invisibility-spec nil))
  (when visual-line-table--enabled-visual-line
    (visual-line-mode -1)
    (setq visual-line-table--enabled-visual-line nil)))

;;;###autoload
(define-minor-mode visual-line-table-mode
  "Wrap prose while displaying Org or Markdown tables in a clipped viewport.
Use \\[visual-line-table-scroll-left] and
\\[visual-line-table-scroll-right] to scroll tables, not native hscroll.
Experimental: intended for fixed-pitch text without other table overlays."
  :lighter " VLTable"
  :keymap visual-line-table-mode-map
  :group 'visual-line-table
  (if (not visual-line-table-mode)
      (visual-line-table--disable)
    (unless (derived-mode-p 'org-mode 'markdown-mode)
      (setq visual-line-table-mode nil)
      (user-error "This mode requires an Org or Markdown buffer"))
    (unless visual-line-table--windows
      (setq visual-line-table--windows (make-hash-table :test #'eq)
            visual-line-table--enabled-visual-line (not visual-line-mode))
      (setq visual-line-table--invisibility-state
            (cons (local-variable-p 'buffer-invisibility-spec)
                  (copy-tree buffer-invisibility-spec)))
      (add-to-invisibility-spec 'visual-line-table)
      (setq visual-line-table--owned-invisibility-spec
            (copy-tree buffer-invisibility-spec))
      (when visual-line-table--enabled-visual-line (visual-line-mode 1))
      (visual-line-table--install-mode-line)
      (add-hook 'pre-command-hook #'visual-line-table--pre-command nil t)
      (add-hook 'post-command-hook #'visual-line-table--post-command nil t)
      (add-hook 'pre-redisplay-functions #'visual-line-table--refresh nil t)
      (add-hook 'after-change-functions #'visual-line-table--refresh nil t)
      (add-hook 'window-size-change-functions #'visual-line-table--refresh nil t)
      (add-hook 'window-buffer-change-functions #'visual-line-table--refresh nil t)
      (add-hook 'change-major-mode-hook #'visual-line-table--disable nil t))
    (visual-line-table--refresh)))

(provide 'visual-line-table-mode)
;;; visual-line-table-mode.el ends here
