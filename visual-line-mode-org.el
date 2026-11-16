;;; visual-line-mode-org.el --- Wrap prose, clip Org tables -*- lexical-binding: t; -*-

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

(defgroup visual-line-mode-org nil
  "Wrap prose and clip tables in Org buffers."
  :group 'org-appearance)

(defvar-local visual-line-mode-org--overlays nil)
(defvar-local visual-line-mode-org--windows nil)
(defvar-local visual-line-mode-org--enabled-visual-line nil)
(defvar-local visual-line-mode-org--updating nil)
(defvar-local visual-line-mode-org--invisibility-state nil)
(defvar-local visual-line-mode-org--owned-invisibility-spec nil)
(defvar-local visual-line-mode-org--line-move-state nil)
(defvar-local visual-line-mode-org--mode-line-state nil)
(defconst visual-line-mode-org--mode-line-form
  '(:eval (visual-line-mode-org--format-mode-line)))
(defvar visual-line-mode-org--navigation-origin nil
  "Buffer, window, text tick and table status before vertical navigation.")
(defvar visual-line-mode-org--line-move-buffer nil
  "Buffer whose navigation setting is temporarily changed for a command.")
(defvar visual-line-mode-org-mode)
(defvar org-pretty-table-mode)

(defun visual-line-mode-org--reset-column-cache ()
  "Invalidate Emacs's cached column without changing point."
  (save-excursion
    (let ((inhibit-field-text-motion t))
      (beginning-of-line)
      (current-column))))

(defun visual-line-mode-org--original-mode-line ()
  "Return this buffer's original, possibly inherited, mode-line format."
  (if (car visual-line-mode-org--mode-line-state)
      (cdr visual-line-mode-org--mode-line-state)
    (default-value 'mode-line-format)))

(defun visual-line-mode-org--format-mode-line ()
  "Render the original mode line using source columns inside tables."
  (let ((buffer-invisibility-spec
         (if (visual-line-mode-org--table) nil buffer-invisibility-spec)))
    (unwind-protect
        (progn
          (visual-line-mode-org--reset-column-cache)
          ;; Fully render deferred fields before restoring invisibility.
          ;; Escape literal percent signs for the outer mode-line renderer.
          (replace-regexp-in-string
           "%" (lambda (match) (concat match match))
           (format-mode-line (visual-line-mode-org--original-mode-line)) t t))
      ;; Do not leak the absolute-column cache into ordinary navigation.
      (visual-line-mode-org--reset-column-cache))))

(defun visual-line-mode-org--install-mode-line ()
  "Keep the existing mode line and scope column calculations to rendering."
  (setq visual-line-mode-org--mode-line-state
        (cons (local-variable-p 'mode-line-format) mode-line-format))
  (when mode-line-format
    (setq-local mode-line-format
                (list visual-line-mode-org--mode-line-form))))

(defun visual-line-mode-org--restore-mode-line ()
  "Remove our wrapper without discarding subsequent layout changes."
  (when visual-line-mode-org--mode-line-state
    (if (equal mode-line-format (list visual-line-mode-org--mode-line-form))
        (if (car visual-line-mode-org--mode-line-state)
            (setq-local mode-line-format
                        (cdr visual-line-mode-org--mode-line-state))
          (kill-local-variable 'mode-line-format))
      (let ((restored
             (cl-subst (visual-line-mode-org--original-mode-line)
                       visual-line-mode-org--mode-line-form mode-line-format
                       :test #'equal)))
        (unless (equal restored mode-line-format)
          (setq-local mode-line-format restored))))
    (setq visual-line-mode-org--mode-line-state nil)))

(defun visual-line-mode-org--clear ()
  "Remove only overlays owned by this mode."
  (mapc #'delete-overlay visual-line-mode-org--overlays)
  (setq visual-line-mode-org--overlays nil))

(defun visual-line-mode-org--width (window)
  "Return usable text columns in WINDOW, excluding line numbers and fringes."
  (max 1 (1- (floor (window-max-chars-per-line window)))))

(defun visual-line-mode-org--state (window)
  "Return or create viewport state for WINDOW."
  (or (gethash window visual-line-mode-org--windows)
      (let ((state (list :start (make-marker) :offset 0
                         :hscroll (window-hscroll window))))
        (puthash window state visual-line-mode-org--windows)
        ;; Native hscroll forces truncation even with `truncate-lines' nil.
        (set-window-hscroll window 0)
        state)))

(defun visual-line-mode-org--table ()
  "Return bounds of the Org table at point, or nil.
Table-looking lines in source and example blocks are not tables."
  (when (org-at-table-p)
    (let ((table (org-element-lineage (org-element-context) '(table) t)))
      (when (and table
                 (eq (org-element-property :type table) 'org))
        (cons (org-element-property :begin table)
              (org-element-property :end table))))))

(defun visual-line-mode-org--overlay (start end window)
  "Create an owned overlay from START to END in WINDOW."
  (when (< start end)
    (let ((overlay (make-overlay start end nil nil nil)))
      (overlay-put overlay 'window window)
      (overlay-put overlay 'visual-line-mode-org t)
      (push overlay visual-line-mode-org--overlays)
      overlay)))

(defun visual-line-mode-org--hide (start end window)
  "Conceal START to END in WINDOW without changing the buffer text."
  (when-let* ((overlay (visual-line-mode-org--overlay start end window)))
    (overlay-put overlay 'invisible 'visual-line-mode-org)))

(defun visual-line-mode-org--pretty-runs (start end)
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

(defun visual-line-mode-org--pretty-view (left right window runs)
  "Show only the visible part LEFT..RIGHT of pretty display RUNS in WINDOW."
  (dolist (run runs)
    (let* ((begin (nth 0 run)) (end (nth 1 run)) (display (nth 2 run))
           (mask (visual-line-mode-org--overlay begin end window)))
      ;; A non-replacing display spec shadows the underlying replacement.
      ;; Invisible overlays can then hide the parts outside the viewport.
      (overlay-put mask 'display '(when nil . ""))
      (overlay-put mask 'priority 1)
      (let ((position (max begin left)) (limit (min end right)))
        (while (< position limit)
          (let ((glyph (visual-line-mode-org--overlay position (1+ position) window)))
            (overlay-put glyph 'display (substring display (- position begin)
                                                  (1+ (- position begin))))
            (overlay-put glyph 'priority 2))
          (setq position (1+ position)))))))

(defun visual-line-mode-org--column-position (column end)
  "Find a position at or before COLUMN, no later than END.
Do not split a wide character or tab across the viewport edge."
  (move-to-column column)
  (when (and (> (current-column) column) (> (point) (line-beginning-position)))
    (backward-char))
  (min (point) end))

(defun visual-line-mode-org--row-width (window width)
  "Return usable WIDTH for the current row in WINDOW, excluding its prefix."
  (let ((prefix (get-char-property (line-beginning-position) 'line-prefix window)))
    (max 1 (- width (if (stringp prefix) (string-width prefix) 0)))))

(defun visual-line-mode-org--row-span (window offset width)
  "Return visible bounds of this row at OFFSET and WIDTH in WINDOW."
  (let* ((end (line-end-position))
         (available (visual-line-mode-org--row-width window width))
         (runs (visual-line-mode-org--pretty-runs (line-beginning-position) end))
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
          (let* ((left (visual-line-mode-org--column-position offset end))
                 (motion (compute-motion left '(0 . 0) end (cons available 0)
                                         most-positive-fixnum nil window))
                 (right (car motion)))
            (when (and (> (nth 1 motion) available) (> right left))
              (setq right (1- right)))
            (cons left right)))
      (mapc #'delete-overlay masks))))

(defun visual-line-mode-org--refresh (&rest _ignored)
  "Rebuild clipping overlays for windows displaying this buffer."
  (when (and visual-line-mode-org-mode (not visual-line-mode-org--updating))
    (let ((visual-line-mode-org--updating t)
          (ranges nil)
          (pretty-views nil))
      (visual-line-mode-org--clear)
      (maphash (lambda (window state)
                 (unless (and (window-live-p window)
                              (eq (window-buffer window) (current-buffer)))
                   (set-marker (plist-get state :start) nil)
                   (remhash window visual-line-mode-org--windows)))
               visual-line-mode-org--windows)
      (save-excursion
        (save-restriction
          (widen)
          (when (bound-and-true-p org-pretty-table-mode)
            (font-lock-ensure))
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (let* ((state (visual-line-mode-org--state window))
                   (width (visual-line-mode-org--width window))
                   (cursor (window-point window))
                   (table (progn (goto-char cursor)
                                 (visual-line-mode-org--table)))
                   (marker (plist-get state :start))
                   (offset (plist-get state :offset)))
              (unless (and table (equal (marker-position marker) (car table)))
                (set-marker marker (car table))
                (setq offset 0))
              (when table
                (goto-char cursor)
                (let ((column (current-column))
                      (available (visual-line-mode-org--row-width window width)))
                  ;; Leave one column for the cursor, including at end of line.
                  (cond ((< column offset) (setq offset column))
                        ((>= column (+ offset available))
                         (setq offset (max 0 (- column available -1)))))))
              (when table
                (goto-char cursor)
                (let ((span (visual-line-mode-org--row-span window offset width)))
                  ;; Tabs, wide characters and line prefixes may shorten the
                  ;; viewport.  Keep point visible against the actual bounds.
                  (when (or (< cursor (car span))
                            (and (>= cursor (cdr span))
                                 (< cursor (line-end-position))))
                    (goto-char cursor)
                    (setq offset (current-column)))))
              (setf (plist-get state :offset) offset)
              (goto-char (point-min))
              (while (re-search-forward org-table-line-regexp nil t)
                (beginning-of-line)
                (let ((bounds (visual-line-mode-org--table)))
                  (when bounds
                    (let* ((start (line-beginning-position))
                           (end (line-end-position))
                           (runs (visual-line-mode-org--pretty-runs start end))
                           (span (visual-line-mode-org--row-span
                                  window (if (equal bounds table) offset 0) width)))
                      (push (list start (car span) window) ranges)
                      (push (list (cdr span) end window) ranges)
                      (when runs
                        (push (list (car span) (cdr span) window runs) pretty-views)))))
                (forward-line 1))))))
      ;; Defer overlays until all windows are measured.  Keep Org's own
      ;; invisibility (emphasis, links, folding) intact throughout measurement.
      (dolist (range ranges)
        (apply #'visual-line-mode-org--hide range))
      (dolist (view pretty-views)
        (apply #'visual-line-mode-org--pretty-view view)))))

(defun visual-line-mode-org-scroll-left (&optional columns)
  "Reveal COLUMNS more columns to the right in the table at point.
With a negative argument, reveal columns to the left instead.
This moves point into the viewport so automatic following does not undo it."
  (interactive "P")
  (unless visual-line-mode-org-mode
    (user-error "Enable visual-line-mode-org-mode first"))
  (unless (visual-line-mode-org--table)
    (user-error "Point is not in an Org table"))
  (visual-line-mode-org--refresh)
  (let* ((window (selected-window))
         (state (visual-line-mode-org--state window))
         (width (visual-line-mode-org--width window))
         (step (if columns (prefix-numeric-value columns) (max 1 (/ width 2))))
         (_unclip (visual-line-mode-org--clear))
         (last-column (save-excursion (end-of-line) (current-column)))
         (offset (min (max 0 (1- last-column))
                      (max 0 (+ (plist-get state :offset) step)))))
    (setf (plist-get state :offset) offset)
    (move-to-column offset)
    (visual-line-mode-org--refresh)))

(defun visual-line-mode-org-scroll-right (&optional columns)
  "Reveal COLUMNS more columns to the left in the table at point."
  (interactive "P")
  (visual-line-mode-org-scroll-left
   (- (if columns (prefix-numeric-value columns)
        (max 1 (/ (visual-line-mode-org--width (selected-window)) 2))))))

(defun visual-line-mode-org-beginning-of-line (&optional n)
  "Run `org-beginning-of-line', using logical lines inside tables.
With N, move forward N - 1 lines first."
  (interactive "^p")
  (let ((visual-line-mode (and visual-line-mode
                               (not (visual-line-mode-org--table)))))
    (org-beginning-of-line n)))

(defun visual-line-mode-org-end-of-line (&optional n)
  "Run `org-end-of-line', using logical lines inside tables.
With N, move forward N - 1 lines first."
  (interactive "^p")
  (let ((visual-line-mode (and visual-line-mode
                               (not (visual-line-mode-org--table)))))
    (org-end-of-line n)))

(defun visual-line-mode-org-move-beginning-of-line (&optional n)
  "Handle native beginning-of-line bindings without changing prose behavior."
  (interactive "^p")
  (if (visual-line-mode-org--table)
      (visual-line-mode-org-beginning-of-line n)
    (let ((visual-line-mode-org-mode nil))
      (funcall (or (command-remapping #'move-beginning-of-line)
                   #'move-beginning-of-line)
               n))))

(defun visual-line-mode-org-move-end-of-line (&optional n)
  "Handle native end-of-line bindings without changing prose behavior."
  (interactive "^p")
  (if (visual-line-mode-org--table)
      (visual-line-mode-org-end-of-line n)
    (let ((visual-line-mode-org-mode nil))
      (funcall (or (command-remapping #'move-end-of-line) #'move-end-of-line) n))))

(defun visual-line-mode-org--scroll-page (command arg)
  "Run native scroll COMMAND with ARG using the rendered table geometry."
  (if (not (and visual-line-mode-org-mode (visual-line-mode-org--table)))
      (funcall command arg)
    (let* ((state (visual-line-mode-org--state (selected-window)))
           (offset (plist-get state :offset))
           (column (let ((buffer-invisibility-spec nil)) (current-column)))
           (visual-column (current-column)))
      ;; Native scrolling miscalculates backward pages from a concealed row
      ;; prefix.  Measure the page with a zero-offset table viewport instead.
      (beginning-of-line)
      (visual-line-mode-org--refresh)
      (unwind-protect
          (funcall command arg)
        (visual-line-mode-org--clear)
        (setf (plist-get state :offset) offset)
        (if (visual-line-mode-org--table)
            (if goal-column
                (move-to-column goal-column)
              (let ((buffer-invisibility-spec nil)) (move-to-column column)))
          (vertical-motion (cons visual-column 0)))))))

(defun visual-line-mode-org-scroll-up-command (&optional arg)
  "Scroll a rendered page up, accepting the native prefix ARG."
  (interactive "^P")
  (visual-line-mode-org--scroll-page #'scroll-up-command arg))

(defun visual-line-mode-org-scroll-down-command (&optional arg)
  "Scroll a rendered page down, accepting the native prefix ARG."
  (interactive "^P")
  (visual-line-mode-org--scroll-page #'scroll-down-command arg))

(put 'visual-line-mode-org-scroll-up-command 'scroll-command t)
(put 'visual-line-mode-org-scroll-down-command 'scroll-command t)

(defvar visual-line-mode-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c <right>") #'visual-line-mode-org-scroll-left)
    (define-key map (kbd "C-c <left>") #'visual-line-mode-org-scroll-right)
    map)
  "Keymap for `visual-line-mode-org-mode'.")

;; Install outside `defvar' so reloading an already loaded package updates it.
(define-key visual-line-mode-org-mode-map [remap org-beginning-of-line]
            #'visual-line-mode-org-beginning-of-line)
(define-key visual-line-mode-org-mode-map [remap org-end-of-line]
            #'visual-line-mode-org-end-of-line)
;; Remapping is not recursive: the usual Home/End bindings name these
;; commands, which Org itself remaps.  Handle the original commands too.
(define-key visual-line-mode-org-mode-map [remap move-beginning-of-line]
            #'visual-line-mode-org-move-beginning-of-line)
(define-key visual-line-mode-org-mode-map [remap move-end-of-line]
            #'visual-line-mode-org-move-end-of-line)
(define-key visual-line-mode-org-mode-map [remap scroll-up-command]
            #'visual-line-mode-org-scroll-up-command)
(define-key visual-line-mode-org-mode-map [remap scroll-down-command]
            #'visual-line-mode-org-scroll-down-command)

(defun visual-line-mode-org--restore-line-move ()
  "Restore navigation in the originating buffer, even after a buffer switch."
  (when (buffer-live-p visual-line-mode-org--line-move-buffer)
    (with-current-buffer visual-line-mode-org--line-move-buffer
      (when visual-line-mode-org--line-move-state
        (if (car visual-line-mode-org--line-move-state)
            (setq-local line-move-visual (cdr visual-line-mode-org--line-move-state))
          (kill-local-variable 'line-move-visual))
        (setq visual-line-mode-org--line-move-state nil))))
  (setq visual-line-mode-org--line-move-buffer nil)
  (remove-hook 'post-command-hook #'visual-line-mode-org--restore-line-move))

(defun visual-line-mode-org--vertical-command-p ()
  "Whether this is vertical keyboard navigation, excluding active search."
  (and (not (bound-and-true-p isearch-mode))
       (or (memq this-command '(next-line previous-line
                               scroll-up-command scroll-down-command
                               visual-line-mode-org-scroll-up-command
                               visual-line-mode-org-scroll-down-command))
           ;; Page keys may call user-defined functions or anonymous lambdas.
           (and last-command-event
                (memq (event-basic-type last-command-event)
                      '(up down prior next kp-up kp-down kp-prior kp-next))))))

(defun visual-line-mode-org--reset-boundary-column ()
  "Reset the column after vertical navigation across a table boundary."
  (let ((origin visual-line-mode-org--navigation-origin))
    (setq visual-line-mode-org--navigation-origin nil)
    (when (and origin
               (eq (nth 0 origin) (current-buffer))
               (eq (nth 1 origin) (selected-window))
               (= (nth 2 origin) (buffer-chars-modified-tick))
               (not (eq (nth 3 origin)
                        (and (visual-line-mode-org--table) t))))
      (visual-line-mode-org--clear)
      (beginning-of-line)
      (setq goal-column nil
            temporary-goal-column 0))))

(defun visual-line-mode-org--pre-command ()
  "Let commands operate without this mode's clipping overlays."
  (visual-line-mode-org--restore-line-move)
  (setq visual-line-mode-org--navigation-origin
        (when (visual-line-mode-org--vertical-command-p)
          (list (current-buffer) (selected-window) (buffer-chars-modified-tick)
                (and (visual-line-mode-org--table) t))))
  ;; Page scrolling needs the clipped geometry, including when starting in
  ;; prose with a table elsewhere in the same window.
  (unless (memq this-command '(scroll-up-command scroll-down-command
                              visual-line-mode-org-scroll-up-command
                              visual-line-mode-org-scroll-down-command))
    (visual-line-mode-org--clear))
  ;; User commands may call `next-line' or `previous-line' indirectly (for
  ;; example, PageDown bound to a lambda that moves 35 lines).
  (when (visual-line-mode-org--table)
    (setq visual-line-mode-org--line-move-state
          (cons (local-variable-p 'line-move-visual) line-move-visual))
    (setq visual-line-mode-org--line-move-buffer (current-buffer))
    (setq-local line-move-visual nil)
    ;; The command may switch buffers, so a local post-command hook alone
    ;; cannot guarantee restoration.  This global hook lasts one command.
    (add-hook 'post-command-hook #'visual-line-mode-org--restore-line-move)))

(defun visual-line-mode-org--post-command ()
  "Restore normal prose navigation before Emacs adjusts point."
  ;; Do not clip here: point adjustment runs after post-command hooks.
  ;; A hidden emphasis marker could merge with our hidden prefix and make
  ;; backward adjustment jump to the preceding row.  Clip at redisplay.
  (visual-line-mode-org--restore-line-move)
  (visual-line-mode-org--reset-boundary-column))

(defun visual-line-mode-org--disable ()
  "Remove hooks and restore display state."
  (setq visual-line-mode-org--navigation-origin nil)
  (visual-line-mode-org--restore-line-move)
  (visual-line-mode-org--restore-mode-line)
  (remove-hook 'pre-command-hook #'visual-line-mode-org--pre-command t)
  (remove-hook 'post-command-hook #'visual-line-mode-org--post-command t)
  (remove-hook 'pre-redisplay-functions #'visual-line-mode-org--refresh t)
  (remove-hook 'after-change-functions #'visual-line-mode-org--refresh t)
  (remove-hook 'window-size-change-functions #'visual-line-mode-org--refresh t)
  (remove-hook 'window-buffer-change-functions #'visual-line-mode-org--refresh t)
  (remove-hook 'change-major-mode-hook #'visual-line-mode-org--disable t)
  (visual-line-mode-org--clear)
  (when visual-line-mode-org--windows
    (maphash (lambda (window state)
               (set-marker (plist-get state :start) nil)
               (when (and (window-live-p window)
                          (eq (window-buffer window) (current-buffer)))
                 (set-window-hscroll window (plist-get state :hscroll))))
             visual-line-mode-org--windows))
  (setq visual-line-mode-org--windows nil)
  (when visual-line-mode-org--invisibility-state
    (if (equal buffer-invisibility-spec
               visual-line-mode-org--owned-invisibility-spec)
        (if (car visual-line-mode-org--invisibility-state)
            (setq-local buffer-invisibility-spec
                        (cdr visual-line-mode-org--invisibility-state))
          (kill-local-variable 'buffer-invisibility-spec))
      ;; Preserve categories other owners added while this mode was active.
      (unless (or (eq (cdr visual-line-mode-org--invisibility-state) t)
                  (member 'visual-line-mode-org
                          (cdr visual-line-mode-org--invisibility-state)))
        (remove-from-invisibility-spec 'visual-line-mode-org)))
    (setq visual-line-mode-org--invisibility-state nil
          visual-line-mode-org--owned-invisibility-spec nil))
  (when visual-line-mode-org--enabled-visual-line
    (visual-line-mode -1)
    (setq visual-line-mode-org--enabled-visual-line nil)))

;;;###autoload
(define-minor-mode visual-line-mode-org-mode
  "Wrap prose while displaying Org table rows in a clipped viewport.
Use \\[visual-line-mode-org-scroll-left] and
\\[visual-line-mode-org-scroll-right] to scroll tables, not native hscroll.
Experimental: intended for fixed-pitch text without other table overlays."
  :lighter " VLOrg"
  :keymap visual-line-mode-org-mode-map
  :group 'visual-line-mode-org
  (if (not visual-line-mode-org-mode)
      (visual-line-mode-org--disable)
    (unless (derived-mode-p 'org-mode)
      (setq visual-line-mode-org-mode nil)
      (user-error "This mode requires an Org buffer"))
    (unless visual-line-mode-org--windows
      (setq visual-line-mode-org--windows (make-hash-table :test #'eq)
            visual-line-mode-org--enabled-visual-line (not visual-line-mode))
      (setq visual-line-mode-org--invisibility-state
            (cons (local-variable-p 'buffer-invisibility-spec)
                  (copy-tree buffer-invisibility-spec)))
      (add-to-invisibility-spec 'visual-line-mode-org)
      (setq visual-line-mode-org--owned-invisibility-spec
            (copy-tree buffer-invisibility-spec))
      (when visual-line-mode-org--enabled-visual-line (visual-line-mode 1))
      (visual-line-mode-org--install-mode-line)
      (add-hook 'pre-command-hook #'visual-line-mode-org--pre-command nil t)
      (add-hook 'post-command-hook #'visual-line-mode-org--post-command nil t)
      (add-hook 'pre-redisplay-functions #'visual-line-mode-org--refresh nil t)
      (add-hook 'after-change-functions #'visual-line-mode-org--refresh nil t)
      (add-hook 'window-size-change-functions #'visual-line-mode-org--refresh nil t)
      (add-hook 'window-buffer-change-functions #'visual-line-mode-org--refresh nil t)
      (add-hook 'change-major-mode-hook #'visual-line-mode-org--disable nil t))
    (visual-line-mode-org--refresh)))

(provide 'visual-line-mode-org)
;;; visual-line-mode-org.el ends here
