;;; visual-line-mode-org.el --- Wrap prose, clip Org tables -*- lexical-binding: t; -*-

;; Version: 0.1.4
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
(defvar visual-line-mode-org-mode)

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

(defun visual-line-mode-org--hide (start end window)
  "Conceal START to END in WINDOW without changing the buffer text."
  (when (< start end)
    (let ((overlay (make-overlay start end nil nil nil)))
      (overlay-put overlay 'window window)
      (overlay-put overlay 'invisible 'visual-line-mode-org)
      (overlay-put overlay 'visual-line-mode-org t)
      (push overlay visual-line-mode-org--overlays))))

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
         (left (visual-line-mode-org--column-position offset end))
         (available (visual-line-mode-org--row-width window width))
         ;; Measure from the new origin, particularly for tabs after scrolling.
         (motion (compute-motion left '(0 . 0) end (cons available 0)
                                 most-positive-fixnum nil window))
         (right (car motion)))
    (when (and (> (nth 1 motion) available) (> right left))
      (setq right (1- right)))
    (cons left right)))

(defun visual-line-mode-org--row-clips (window offset width)
  "Return clipping ranges for the row at OFFSET and WIDTH in WINDOW."
  (let ((start (line-beginning-position))
        (end (line-end-position))
        (span (visual-line-mode-org--row-span window offset width)))
    (list (list start (car span) window)
          (list (cdr span) end window))))

(defun visual-line-mode-org--refresh (&rest _ignored)
  "Rebuild clipping overlays for windows displaying this buffer."
  (when (and visual-line-mode-org-mode (not visual-line-mode-org--updating))
    (let ((visual-line-mode-org--updating t)
          (ranges nil))
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
                    (setq ranges
                          (nconc (visual-line-mode-org--row-clips
                                  window (if (equal bounds table) offset 0) width)
                                 ranges))))
                (forward-line 1))))))
      ;; Defer overlays until all windows are measured.  Keep Org's own
      ;; invisibility (emphasis, links, folding) intact throughout measurement.
      (dolist (range ranges)
        (apply #'visual-line-mode-org--hide range)))))

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

(defun visual-line-mode-org--restore-line-move ()
  "Restore the navigation setting temporarily changed for a command."
  (when visual-line-mode-org--line-move-state
    (if (car visual-line-mode-org--line-move-state)
        (setq-local line-move-visual (cdr visual-line-mode-org--line-move-state))
      (kill-local-variable 'line-move-visual))
    (setq visual-line-mode-org--line-move-state nil)))

(defun visual-line-mode-org--pre-command ()
  "Let commands operate without this mode's clipping overlays."
  (visual-line-mode-org--restore-line-move)
  (visual-line-mode-org--clear)
  (when (and (memq this-command '(next-line previous-line))
             (visual-line-mode-org--table))
    (setq visual-line-mode-org--line-move-state
          (cons (local-variable-p 'line-move-visual) line-move-visual))
    (setq-local line-move-visual nil)))

(defun visual-line-mode-org--post-command ()
  "Restore normal prose navigation before Emacs adjusts point."
  ;; Do not clip here: point adjustment runs after post-command hooks.
  ;; A hidden emphasis marker could merge with our hidden prefix and make
  ;; backward adjustment jump to the preceding row.  Clip at redisplay.
  (visual-line-mode-org--restore-line-move))

(defun visual-line-mode-org--disable ()
  "Remove hooks and restore display state."
  (visual-line-mode-org--restore-line-move)
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
