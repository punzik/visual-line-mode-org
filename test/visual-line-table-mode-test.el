;;; visual-line-table-mode-test.el --- Prototype tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'isearch)
(require 'visual-line-table-mode)

(defvar org-pretty-table-mode)
(defvar org-pretty-table-charset)
(defvar doom-modeline-icon)
(defvar doom-modeline-column-zero-based)

(defmacro vltable-test--buffer (text &rest body)
  "Run BODY with TEXT displayed in an isolated Org buffer."
  (declare (indent 1) (debug t))
  `(save-window-excursion
     (with-temp-buffer
       (org-mode)
       (insert ,text)
       (goto-char (point-min))
       (set-window-buffer (selected-window) (current-buffer))
       (set-window-hscroll (selected-window) 0)
       (set-window-start (selected-window) (point-min))
       (unwind-protect
           (progn ,@body)
         (when visual-line-table-mode (visual-line-table-mode -1))))))

(defun vltable-test--one-screen-row-p ()
  "Whether the current logical line occupies one screen row."
  (let ((next (save-excursion (forward-line 1) (point))))
    (save-excursion
      (beginning-of-line)
      (= (progn (vertical-motion 1) (point)) next))))

(defconst vltable-test--text
  (concat (apply #'concat (make-list 70 "prose ")) "\n\n"
          "| " (make-string 220 ?x) " |\n"
          "| " (make-string 220 ?y) " |\n\nAfter.\n"))

(ert-deftest vltable-prose-wraps-table-does-not ()
  (vltable-test--buffer vltable-test--text
    (visual-line-table-mode 1)
    (should-not (vltable-test--one-screen-row-p))
    (forward-line 2)
    (should (vltable-test--one-screen-row-p))
    (forward-line 1)
    (should (vltable-test--one-screen-row-p))
    (should (= (window-hscroll) 0))))

(ert-deftest vltable-restores-settings-and-buffer ()
  (vltable-test--buffer vltable-test--text
    (setq-local truncate-lines t)
    (setq-local word-wrap nil)
    (setq-local truncate-partial-width-windows 45)
    (set-buffer-modified-p nil)
    (let ((text (buffer-string))
          (undo buffer-undo-list)
          (tick (buffer-chars-modified-tick)))
      (visual-line-table-mode 1)
      (should visual-line-mode)
      (should-not truncate-lines)
      (should-not (buffer-modified-p))
      (visual-line-table-mode -1)
      (should truncate-lines)
      (should-not word-wrap)
      (should (= truncate-partial-width-windows 45))
      (should-not visual-line-mode)
      (should-not (memq #'visual-line-table--refresh pre-redisplay-functions))
      (should-not visual-line-table--overlays)
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not (buffer-modified-p)))))

(ert-deftest vltable-preserves-existing-visual-line-mode ()
  (vltable-test--buffer vltable-test--text
    (visual-line-mode 1)
    (let ((state (copy-tree visual-line--saved-state)))
      (visual-line-table-mode 1)
      (visual-line-table-mode -1)
      (should visual-line-mode)
      (should (equal state visual-line--saved-state)))))

(ert-deftest vltable-scrolls-only-the-table ()
  (vltable-test--buffer vltable-test--text
    (visual-line-table-mode 1)
    (forward-line 2)
    (visual-line-table-scroll-left 100)
    (should (= (let ((buffer-invisibility-spec nil)) (current-column)) 100))
    (should (= (plist-get (visual-line-table--state (selected-window)) :offset) 100))
    (should (vltable-test--one-screen-row-p))
    (should (= (window-hscroll) 0))
    (goto-char (point-min))
    (should-not (vltable-test--one-screen-row-p))
    (forward-line 2)
    (let ((buffer-invisibility-spec nil)) (move-to-column 100))
    (visual-line-table-scroll-right 50)
    (should (= (let ((buffer-invisibility-spec nil)) (current-column)) 50))
    (should (vltable-test--one-screen-row-p))))

(ert-deftest vltable-follows-point ()
  (vltable-test--buffer vltable-test--text
    (visual-line-table-mode 1)
    (forward-line 2)
    (end-of-line)
    (visual-line-table--refresh)
    (let ((state (visual-line-table--state (selected-window))))
      (should (> (plist-get state :offset) 0))
      (should (vltable-test--one-screen-row-p))
      (beginning-of-line)
      (visual-line-table--refresh)
      (should (= (plist-get state :offset) 0)))))

(ert-deftest vltable-updates-after-edit ()
  (vltable-test--buffer (concat "text " (make-string 220 ?x) "\n")
    (visual-line-table-mode 1)
    (should-not visual-line-table--overlays)
    (insert "| ")
    (should visual-line-table--overlays)
    (should (vltable-test--one-screen-row-p))
    (delete-region (point-min) (+ 2 (point-min)))
    (should-not visual-line-table--overlays)
    (should-not (vltable-test--one-screen-row-p))))

(ert-deftest vltable-ignores-block-contents ()
  (vltable-test--buffer
      (concat "#+begin_src text\n| " (make-string 220 ?x)
              "\n#+end_src\n\n#+begin_example\n| " (make-string 220 ?y)
              "\n#+end_example\n")
    (visual-line-table-mode 1)
    (should-not visual-line-table--overlays)))

(ert-deftest vltable-two-window-widths ()
  (vltable-test--buffer vltable-test--text
    (delete-other-windows)
    (let ((second (split-window-right)))
      (visual-line-table-mode 1)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (goto-char (point-min))
          (forward-line 2)
          (should (vltable-test--one-screen-row-p))))
      (window-resize second -5 t)
      (visual-line-table--refresh)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (goto-char (point-min))
          (forward-line 2)
          (should (vltable-test--one-screen-row-p)))))))

(ert-deftest vltable-read-only-and-foreign-overlays ()
  (vltable-test--buffer vltable-test--text
    (let ((foreign (make-overlay 1 3)))
      (setq buffer-read-only t)
      (visual-line-table-mode 1)
      (visual-line-table-mode -1)
      (should (overlay-buffer foreign)))))

(ert-deftest vltable-enable-idempotent ()
  (vltable-test--buffer vltable-test--text
    (visual-line-table-mode 1)
    (let ((count (length visual-line-table--overlays)))
      (visual-line-table-mode 1)
      (should (= count (length visual-line-table--overlays))))))

(ert-deftest vltable-empty-and-non-org ()
  (vltable-test--buffer ""
    (visual-line-table-mode 1)
    (should-not visual-line-table--overlays))
  (with-temp-buffer
    (should-error (visual-line-table-mode 1) :type 'user-error)
    (should-not visual-line-table-mode)))

(ert-deftest vltable-cleanup-on-major-mode-change ()
  (vltable-test--buffer vltable-test--text
    (visual-line-table-mode 1)
    (let ((overlays (copy-sequence visual-line-table--overlays)))
      (fundamental-mode)
      (should-not (cl-some #'overlay-buffer overlays)))))

(ert-deftest vltable-restores-horizontal-scroll ()
  (vltable-test--buffer vltable-test--text
    (set-window-hscroll (selected-window) 5)
    (visual-line-table-mode 1)
    (should (= (window-hscroll) 0))
    (visual-line-table-mode -1)
    (should (= (window-hscroll) 5))))

(ert-deftest vltable-tabs-and-wide-characters ()
  (dolist (row (list (concat "|\t" (apply #'concat (make-list 50 "xx\t")) "|\n")
                     (concat "| " (make-string 150 ?界) " |\n")))
    (vltable-test--buffer row
      (visual-line-table-mode 1)
      (should (vltable-test--one-screen-row-p))
      (visual-line-table-scroll-left 13)
      (should (vltable-test--one-screen-row-p)))))

(ert-deftest vltable-org-indent ()
  (vltable-test--buffer (concat "*** Heading\n| " (make-string 220 ?x) " |\n")
    (org-indent-mode 1)
    (font-lock-ensure)
    (visual-line-table-mode 1)
    (forward-line 1)
    (should (vltable-test--one-screen-row-p))))

(ert-deftest vltable-follow-point-after-tab ()
  (vltable-test--buffer (concat "|\t" (make-string 200 ?x) "\n")
    (visual-line-table-mode 1)
    (let ((buffer-invisibility-spec nil))
      (move-to-column (+ 3 (window-body-width))))
    (visual-line-table--refresh)
    (should-not (invisible-p (point)))
    (should (vltable-test--one-screen-row-p))))

(ert-deftest vltable-preserves-other-invisibility-owners ()
  (vltable-test--buffer vltable-test--text
    (visual-line-table-mode 1)
    (add-to-invisibility-spec 'other-owner)
    (visual-line-table-mode -1)
    (should (memq 'other-owner buffer-invisibility-spec))
    (should-not (memq 'visual-line-table buffer-invisibility-spec))))

(ert-deftest vltable-org-table-editing ()
  (let* ((text (concat "| a | " (make-string 180 ?x) " |\n| b | short |\n"))
         (expected (with-temp-buffer
                     (org-mode)
                     (insert text)
                     (goto-char (point-min))
                     (org-table-align)
                     (buffer-string))))
    (vltable-test--buffer text
      (visual-line-table-mode 1)
      (org-table-align)
      (should (equal (buffer-string) expected))
      (visual-line-table-scroll-left 40)
      (org-table-next-field)
      (visual-line-table--refresh)
      (should-not (invisible-p (point))))))

(defconst vltable-test--reported-table
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "reported-table.org"
                       (file-name-directory (or load-file-name buffer-file-name))))
    (buffer-string)))

(ert-deftest vltable-reported-table-with-line-numbers ()
  (vltable-test--buffer (concat "*** Table\n" vltable-test--reported-table)
    (setq-local display-line-numbers t
                org-hide-emphasis-markers t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (unless noninteractive (redisplay t))
    (visual-line-table-mode 1)
    (forward-line 1)
    (while (not (eobp))
      (should (vltable-test--one-screen-row-p))
      (forward-line 1))))

(ert-deftest vltable-keyboard-navigation-keeps-goal-column ()
  (skip-unless (not noninteractive))
  (vltable-test--buffer
      (concat "| " (make-string 150 ?a) " |\n| x |\n| "
              (make-string 150 ?c) " |\n")
    (move-to-column 85)
    (visual-line-table-mode 1)
    (let* ((columns nil)
           (record (lambda ()
                     (when (memq this-command '(next-line previous-line))
                       (push (- (point) (line-beginning-position)) columns)))))
      (add-hook 'post-command-hook record t t)
      (unwind-protect
          (progn
            (redisplay t)
            (execute-kbd-macro (kbd "C-n C-n C-p C-p"))
            (should (equal (nreverse columns) '(5 85 5 85)))
            (should line-move-visual))
        (remove-hook 'post-command-hook record t)))))

(ert-deftest vltable-home-end-default-bindings ()
  (vltable-test--buffer vltable-test--reported-table
    (should (eq (key-binding [home] nil t) #'move-beginning-of-line))
    (should (eq (key-binding [end] nil t) #'move-end-of-line))
    (visual-line-table-mode 1)
    (should (eq (key-binding [home]) #'visual-line-table-move-beginning-of-line))
    (should (eq (key-binding [end]) #'visual-line-table-move-end-of-line))))

(defun vltable-test--navigation-trace (text row column keys hide enabled
                                       &optional prose redisplay-each default-bindings)
  "Trace KEYS using the user's bindings, optionally redisplaying each key."
  (vltable-test--buffer text
    (use-local-map (copy-keymap (current-local-map)))
    (local-set-key (kbd "<left>") #'left-char)
    (local-set-key (kbd "<right>") #'right-char)
    (unless default-bindings
      (local-set-key (kbd "<home>") #'org-beginning-of-line)
      (local-set-key (kbd "<end>") #'org-end-of-line))
    (setq-local org-hide-emphasis-markers hide
                display-line-numbers t
                truncate-lines t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (forward-line row)
    (goto-char (+ (line-beginning-position) column))
    (when prose (visual-line-mode 1))
    (when enabled (visual-line-table-mode 1))
    (let* ((positions nil)
           (record (lambda ()
                     (when (memq this-command
                                 '(left-char right-char
                                   org-beginning-of-line org-end-of-line
                                   visual-line-table-beginning-of-line
                                   visual-line-table-end-of-line
                                   visual-line-table-move-beginning-of-line
                                   visual-line-table-move-end-of-line))
                       (push (list (point) (invisible-p (point))) positions)))))
      (unless redisplay-each (add-hook 'post-command-hook record t t))
      (unwind-protect
          (progn
            (redisplay t)
            (if redisplay-each
                (dolist (event (append keys nil))
                  (execute-kbd-macro (vector event))
                  (redisplay t)
                  (when enabled
                    ;; No overlay is needed when the whole table fits.
                    (should (vltable-test--one-screen-row-p)))
                  (push (list (point) (invisible-p (point))) positions))
              (execute-kbd-macro keys))
            (nreverse positions))
        (remove-hook 'post-command-hook record t)))))

(ert-deftest vltable-keyboard-home-end-in-tables ()
  (skip-unless (not noninteractive))
  (let ((text (concat "*** Table\n" vltable-test--reported-table)))
    (dolist (hide '(nil t))
      (dolist (row '(1 3 5))
        (dolist (case '((100 "<home> <home>")
                        (20 "<end> <end>")
                        (105 "<end> <home> <end> <home>")))
          (dolist (default-bindings '(nil t))
            (let* ((keys (kbd (cadr case)))
                   (baseline (vltable-test--navigation-trace
                              text row (car case) keys hide nil nil nil default-bindings))
                   (actual (vltable-test--navigation-trace
                            text row (car case) keys hide t nil nil default-bindings)))
              (should baseline)
              (should (equal actual baseline)))))))))

(ert-deftest vltable-keyboard-left-right-in-tables ()
  (skip-unless (not noninteractive))
  (let ((text (concat "*** Table\n" vltable-test--reported-table))
        (keys (vconcat (make-list 10 'right) (make-list 10 'left))))
    (dolist (hide '(nil t))
      (dolist (row '(1 3 5))
        (dolist (column '(10 65 105))
          (dolist (redisplay-each '(nil t))
            (let ((baseline (vltable-test--navigation-trace
                             text row column keys hide nil nil redisplay-each))
                  (actual (vltable-test--navigation-trace
                           text row column keys hide t nil redisplay-each)))
              (should (= (length baseline) 20))
              (should (equal actual baseline)))))))))

(ert-deftest vltable-keyboard-home-end-in-prose ()
  (skip-unless (not noninteractive))
  (let ((keys (kbd "<home> <end> <home> <end>")))
    (dolist (default-bindings '(nil t))
      (should (equal (vltable-test--navigation-trace
                      vltable-test--text 0 140 keys t t t nil default-bindings)
                     (vltable-test--navigation-trace
                      vltable-test--text 0 140 keys t nil t nil default-bindings))))))

(ert-deftest vltable-keyboard-end-displays-closing-bar ()
  (skip-unless (not noninteractive))
  (vltable-test--buffer (concat "*** Table\n" vltable-test--reported-table)
    (setq-local org-hide-emphasis-markers t
                display-line-numbers t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (use-local-map (copy-keymap (current-local-map)))
    (local-set-key [end] #'move-end-of-line)
    (forward-line 3)
    (visual-line-table-mode 1)
    (redisplay t)
    (execute-kbd-macro [end])
    (redisplay t)
    (should (eolp))
    (should (eq (char-before) ?|))
    (should-not (invisible-p (1- (point))))
    (let ((bar (posn-at-point (1- (point))))
          (cursor (posn-at-point (point))))
      (should bar)
      (should cursor)
      (should (= (cdr (posn-x-y bar)) (cdr (posn-x-y cursor))))
      (should (< (car (posn-x-y bar)) (car (posn-x-y cursor)))))))

(ert-deftest vltable-end-keeps-closing-bar-visible ()
  (vltable-test--buffer (concat "*** Table\n" vltable-test--reported-table)
    (setq-local org-hide-emphasis-markers t
                display-line-numbers t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (forward-line 3)
    (end-of-line)
    ;; Match the indentation prefix installed during interactive redisplay.
    (put-text-property (line-beginning-position) (line-end-position)
                       'line-prefix (make-string 6 ?\s))
    (let ((end (point)))
      (visual-line-table-mode 1)
      (should (= (point) end))
      (should (eq (char-before) ?|))
      (should-not (invisible-p (1- end)))
      (should (vltable-test--one-screen-row-p)))))

(defconst vltable-test--large-table
  (concat "*** Large table\n| ID | Description | SHA |\n|----+-------------+-----|\n"
          (mapconcat (lambda (n)
                       (format "| %03d | %s | =%040x= |"
                               n (make-string 150 ?x) n))
                     (number-sequence 1 400) "\n")
          "\n"))

(defun vltable-test--page-trace (enabled bindings &optional column prose)
  "Trace page keys with ENABLED clipping and BINDINGS, starting at COLUMN."
  (vltable-test--buffer (if prose
                         (apply #'concat (make-list 400
                                                   (concat (make-string 200 ?x) "\n")))
                       vltable-test--large-table)
    (use-local-map (copy-keymap (current-local-map)))
    (when (eq bindings 'wrapper)
      ;; Deliberately reproduce the user's commands, not `forward-line'.
      (with-suppressed-warnings ((interactive-only next-line previous-line))
        (local-set-key [next] (lambda () (interactive) (next-line 35)))
        (local-set-key [prior] (lambda () (interactive) (previous-line 35)))))
    (setq-local truncate-lines t
                display-line-numbers t
                org-hide-emphasis-markers t
                scroll-preserve-screen-position t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (forward-line 69)
    (forward-char (or column 0))
    (when prose (visual-line-mode 1))
    (when enabled (visual-line-table-mode 1))
    (set-window-start (selected-window)
                      (save-excursion
                        (goto-char (point-min)) (forward-line 49) (point)))
    (redisplay t)
    (let ((trace nil))
      (dolist (event '(nil next next prior prior))
        (when event (execute-kbd-macro (vector event)))
        (redisplay t)
        (push (list (line-number-at-pos)
                    (- (point) (line-beginning-position))
                    (line-number-at-pos (window-start)))
              trace))
      (nreverse trace))))

(ert-deftest vltable-restore-navigation-after-buffer-switch ()
  (vltable-test--buffer vltable-test--reported-table
    (visual-line-table-mode 1)
    (let ((original line-move-visual)
          (local (local-variable-p 'line-move-visual))
          (this-command 'switch-to-buffer))
      (visual-line-table--pre-command)
      (should-not line-move-visual)
      (with-temp-buffer (run-hooks 'post-command-hook))
      (should (eq line-move-visual original))
      (should (eq (local-variable-p 'line-move-visual) local))
      (should-not visual-line-table--line-move-buffer)
      (should-not (memq #'visual-line-table--restore-line-move
                        (default-value 'post-command-hook))))))

(ert-deftest vltable-keyboard-page-wrappers-in-tables ()
  (skip-unless (not noninteractive))
  (dolist (column '(0 120))
    (let ((baseline (vltable-test--page-trace nil 'wrapper column))
          (actual (vltable-test--page-trace t 'wrapper column)))
      (should (equal (mapcar #'car actual) '(70 105 140 105 70)))
      (should (equal actual baseline)))))

(ert-deftest vltable-keyboard-native-pages-in-tables ()
  (skip-unless (not noninteractive))
  (let ((baseline (vltable-test--page-trace nil 'native 0)))
    (dolist (column '(0 120))
      (let ((actual (vltable-test--page-trace t 'native column)))
        (should (equal (mapcar #'car actual) (mapcar #'car baseline)))
        (should (equal (mapcar #'caddr actual) (mapcar #'caddr baseline)))
        (should (cl-every (lambda (entry) (= (cadr entry) column)) actual))))))

(ert-deftest vltable-keyboard-pages-in-prose ()
  (skip-unless (not noninteractive))
  (dolist (bindings '(wrapper native))
    (should (equal (vltable-test--page-trace t bindings 0 t)
                   (vltable-test--page-trace nil bindings 0 t)))))

(defconst vltable-test--boundary-text
  (concat "*** Section\n"
          "before-one " (make-string 220 ?a) "\n"
          "before-two " (make-string 220 ?b) "\n"
          "| first | " (make-string 220 ?x) " |\n"
          "| last  | " (make-string 220 ?y) " |\n"
          "after-one " (make-string 220 ?c) "\n"
          "after-two " (make-string 220 ?d) "\n"))

(defun vltable-test--boundary-trace (text row column events &optional wrapper)
  "Trace vertical EVENTS across table boundaries, optionally using WRAPPER pages."
  (vltable-test--buffer text
    (use-local-map (copy-keymap (current-local-map)))
    (local-set-key [down] #'next-line)
    (local-set-key [up] #'previous-line)
    (when wrapper
      (with-suppressed-warnings ((interactive-only next-line previous-line))
        (local-set-key [next] (lambda () (interactive) (next-line 35)))
        (local-set-key [prior] (lambda () (interactive) (previous-line 35)))))
    (setq-local display-line-numbers t org-hide-emphasis-markers t
                scroll-preserve-screen-position t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (forward-line row)
    (goto-char (min (+ (line-beginning-position) column) (line-end-position)))
    (visual-line-table-mode 1)
    (set-window-start (selected-window)
                      (save-excursion (beginning-of-line) (vertical-motion -10) (point)))
    (redisplay t)
    (let ((last-command nil)
          (goal-column nil)
          (temporary-goal-column 0)
          (trace nil))
      (dolist (event events)
        (execute-kbd-macro (vector event))
        (redisplay t)
        (push (list :row (line-number-at-pos) :column (current-column)
                    :table (and (visual-line-table--table) t)
                    :bol (bolp) :goal goal-column :temporary temporary-goal-column
                    :visual-bol (= (point) (save-excursion (beginning-of-visual-line) (point))))
              trace))
      (nreverse trace))))

(ert-deftest vltable-boundary-resets-column-and-goal ()
  (dolist (rows '((4 5) (2 3)))
    (vltable-test--buffer vltable-test--boundary-text
      (forward-line (car rows)) (forward-char 80)
      (visual-line-table-mode 1)
      (let ((this-command 'next-line) (last-command-event 'down)
            (goal-column 80) (temporary-goal-column 80))
        (visual-line-table--pre-command)
        (goto-char (point-min)) (forward-line (cadr rows)) (forward-char 20)
        (visual-line-table--post-command)
        (should (bolp))
        (should-not goal-column)
        (should (= temporary-goal-column 0))))))

(ert-deftest vltable-boundary-does-not-reset-mouse-or-search ()
  (dolist (command '(mouse-set-point isearch-forward next-line))
    (vltable-test--buffer vltable-test--boundary-text
      (forward-line 4) (forward-char 80)
      (visual-line-table-mode 1)
      (let ((this-command command)
            (last-command-event (pcase command
                                  ('mouse-set-point 'mouse-1)
                                  ('next-line 'up)
                                  (_ ?\C-s)))
            (isearch-mode (eq command 'next-line))
            (goal-column 80) (temporary-goal-column 80))
        (visual-line-table--pre-command)
        (goto-char (point-min)) (forward-line 5) (forward-char 20)
        (let ((target (point)))
          (visual-line-table--post-command)
          (should (= (point) target))
          (should (= goal-column 80))
          (should (= temporary-goal-column 80)))))))

(ert-deftest vltable-keyboard-arrows-reset-at-boundaries ()
  (skip-unless (not noninteractive))
  (dolist (case '((4 120 (down down) nil)
                  (3 120 (up up) nil)
                  (2 999 (down down) t)
                  (5 5 (up up) t)))
    (let* ((trace (vltable-test--boundary-trace vltable-test--boundary-text
                                            (nth 0 case) (nth 1 case) (nth 2 case)))
           (first (car trace)) (second (cadr trace)))
      (should (eq (plist-get first :table) (nth 3 case)))
      (should (plist-get first :bol))
      (should-not (plist-get first :goal))
      (should (eql (plist-get first :temporary) 0))
      (should (plist-get second :visual-bol))))
  (let ((text (concat (make-string 220 ?a) "\n\n"
                      "| " (make-string 220 ?x) " |\n"
                      "| " (make-string 220 ?y) " |\n\n"
                      (make-string 220 ?b) "\n")))
    (dolist (case '((3 (down down)) (2 (up up))))
      (let ((trace (vltable-test--boundary-trace text (car case) 120 (cadr case))))
        (should-not (plist-get (car trace) :table))
        (should (plist-get (car trace) :bol))
        (should (eql (plist-get (car trace) :temporary) 0))
        (should (plist-get (cadr trace) :visual-bol))))))

(ert-deftest vltable-keyboard-pages-reset-at-boundaries ()
  (skip-unless (not noninteractive))
  (let* ((prose (concat "paragraph " (make-string 200 ?p) "\n"))
         (text (concat (apply #'concat (make-list 40 prose))
                       vltable-test--large-table
                       (apply #'concat (make-list 80 prose)))))
    (dolist (wrapper '(nil t))
      (dolist (case '((442 120 (next down) nil)
                      (43 120 (prior up) nil)
                      (34 20 (next down) t)
                      (449 20 (prior up) t)))
        (let* ((trace (vltable-test--boundary-trace text (nth 0 case) (nth 1 case)
                                                 (nth 2 case) wrapper))
               (first (car trace)) (second (cadr trace)))
          (should (eq (plist-get first :table) (nth 3 case)))
          (should (plist-get first :bol))
          (should-not (plist-get first :goal))
          (should (eql (plist-get first :temporary) 0))
          (should (plist-get second :visual-bol)))))))

(defconst vltable-test--pretty-table
  (concat "Text\n| Title | " (make-string 1000 ?x) " |\n"
          "|-------+" (make-string 1002 ?-) "|\n"
          "| Body | " (make-string 1000 ?y) " |\nAfter.\n"))

(defun vltable-test--pretty-properties ()
  "Install the length-preserving replacements used by org-pretty-table."
  (font-lock-ensure)
  (setq-local org-pretty-table-mode t)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "[-+|]+" nil t)
      (put-text-property
       (match-beginning 0) (match-end 0) 'display
       (apply #'string (mapcar (lambda (char)
                                (pcase char (?- ?─) (?+ ?┼) (?| ?│)))
                              (string-to-list (match-string 0))))))))

(defun vltable-test--pretty-rows-fit ()
  "Assert that every table row occupies one screen row in the selected window."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (dotimes (_ 3)
      (should (vltable-test--one-screen-row-p))
      (forward-line 1))))

(ert-deftest vltable-pretty-replacements-clip-without-changing-properties ()
  (vltable-test--buffer vltable-test--pretty-table
    (visual-line-mode 1)
    (vltable-test--pretty-properties)
    (set-buffer-modified-p nil)
    (let ((original (buffer-string))
          (tick (buffer-chars-modified-tick))
          (undo buffer-undo-list))
      (visual-line-table-mode 1)
      (vltable-test--pretty-rows-fit)
      (save-excursion
        (forward-line 2)
        (let ((glyph (get-char-property (+ 2 (point)) 'display (selected-window))))
          (should (stringp glyph))
          (should (equal glyph "─"))))
      (should-not (buffer-modified-p))
      (should (= tick (buffer-chars-modified-tick)))
      (should (equal undo buffer-undo-list))
      (visual-line-table-mode -1)
      (should (equal-including-properties original (buffer-string)))
      (should org-pretty-table-mode)
      (forward-line 2)
      (should-not (vltable-test--one-screen-row-p)))))

(ert-deftest vltable-pretty-replacements-scroll ()
  (vltable-test--buffer vltable-test--pretty-table
    (vltable-test--pretty-properties)
    (forward-line 3)
    (visual-line-table-mode 1)
    (visual-line-table-scroll-left 100)
    (vltable-test--pretty-rows-fit)
    (save-excursion
      (goto-char (point-min)) (forward-line 2) (forward-char 110)
      (should (equal (get-char-property (point) 'display (selected-window)) "─")))
    (visual-line-table-scroll-right 100)
    (vltable-test--pretty-rows-fit)))

(ert-deftest vltable-pretty-replacements-in-two-windows ()
  (vltable-test--buffer vltable-test--pretty-table
    (delete-other-windows)
    (vltable-test--pretty-properties)
    (forward-line 3)
    (let ((second (split-window-right 30)))
      (set-window-point second (1- (line-end-position)))
      (visual-line-table-mode 1)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (vltable-test--pretty-rows-fit)))
      (should-not (= (plist-get (visual-line-table--state (selected-window)) :offset)
                     (plist-get (visual-line-table--state second) :offset)))
      (window-resize (selected-window) 5 t)
      (visual-line-table--refresh)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (vltable-test--pretty-rows-fit))))))

(declare-function org-pretty-table-mode "org-pretty-table" (&optional arg))

(ert-deftest vltable-pretty-table-mode-integration ()
  (skip-unless (not noninteractive))
  (skip-unless (require 'org-pretty-table nil t))
  (dolist (pretty-first '(nil t))
    (dolist (charset '("┌┐└┘┬┤┴├┼─│" "╒╕╘╛╤╡╧╞╪═│"))
      (vltable-test--buffer vltable-test--pretty-table
        (setq-local org-pretty-table-charset charset)
        (org-indent-mode 1)
        (unwind-protect
            (progn
              (when pretty-first (org-pretty-table-mode 1))
              (visual-line-table-mode 1)
              (unless pretty-first (org-pretty-table-mode 1))
              (redisplay t)
              (vltable-test--pretty-rows-fit)
              (let ((start (save-excursion (forward-line 2) (point)))
                    (next (save-excursion (forward-line 3) (point))))
                (should (= (- (cdr (posn-x-y (posn-at-point next)))
                              (cdr (posn-x-y (posn-at-point start))))
                           (frame-char-height))))
              (forward-line 3)
              (visual-line-table-scroll-left 100)
              (redisplay t)
              (vltable-test--pretty-rows-fit)
              (visual-line-table-mode -1)
              (should org-pretty-table-mode)
              (should (stringp (get-text-property (line-beginning-position) 'display))))
          (org-pretty-table-mode -1))))))

(ert-deftest vltable-mode-line-restoration ()
  (dolist (local '(nil t))
    (dolist (format '(nil ("column %c %%")))
      (vltable-test--buffer vltable-test--text
        (if local (setq-local mode-line-format format)
          (kill-local-variable 'mode-line-format))
        (let ((original mode-line-format)
              (was-local (local-variable-p 'mode-line-format)))
          (visual-line-table-mode 1)
          (when (and local (null format)) (should-not mode-line-format))
          (visual-line-table-mode -1)
          (should (eq original mode-line-format))
          (should (eq was-local (local-variable-p 'mode-line-format))))))))

(ert-deftest vltable-mode-line-keeps-user-changes ()
  (vltable-test--buffer vltable-test--text
    (setq-local mode-line-format '("original %c"))
    (let ((original mode-line-format))
      (visual-line-table-mode 1)
      (setq-local mode-line-format (cons "prefix " mode-line-format))
      (visual-line-table-mode -1)
      (should (equal mode-line-format (list "prefix " original))))
    (visual-line-table-mode 1)
    (setq-local mode-line-format '("replacement %c"))
    (visual-line-table-mode -1)
    (should (equal mode-line-format '("replacement %c")))))

(defun vltable-test--check-column-format (original window)
  "Compare WINDOW's wrapped format with unclipped ORIGINAL."
  (visual-line-table--clear)
  (let ((expected
         (let ((buffer-invisibility-spec
                (if (with-selected-window window
                      (visual-line-table--table))
                    nil buffer-invisibility-spec)))
           (with-selected-window window
             (visual-line-table--reset-column-cache))
           (format-mode-line original nil window))))
    (visual-line-table--refresh)
    (let ((point-before (point))
          (spec buffer-invisibility-spec)
          (actual (format-mode-line mode-line-format nil window)))
      (should (equal-including-properties expected actual))
      (should (= point-before (point)))
      (should (eq spec buffer-invisibility-spec)))))

(ert-deftest vltable-mode-line-absolute-columns ()
  (skip-unless (not noninteractive))
  (dolist (original '("L%l:%4c/%C %% %b"
                      (:eval (list "%l:" "%c/%C"))
                      ((:propertize "A" face font-lock-keyword-face)
                       (:propertize "%c" face font-lock-warning-face)
                       " %% %b")
                      ((:eval (if (mode-line-window-selected-p)
                                  "ACTIVE " "INACTIVE ")) "%c")
                      ((:propertize "%%" face font-lock-keyword-face) ":%c")))
    (vltable-test--buffer vltable-test--text
      (rename-buffer " *vltable%column*" t)
      (delete-other-windows)
      (setq-local mode-line-format original)
      (forward-line 2)
      (forward-char 120)
      (add-to-invisibility-spec 'vltable-test-hidden)
      (put-text-property (+ (line-beginning-position) 5)
                         (+ (line-beginning-position) 15)
                         'invisible 'vltable-test-hidden)
      (let ((second (split-window-right)))
        (set-window-point second (+ (line-beginning-position) 180))
        (visual-line-table-mode 1)
        (redisplay t)
        (dotimes (_ 2)
          (dolist (window (list (selected-window) second))
            (vltable-test--check-column-format original window)))
        ;; Rendering must not change the visible-column semantics used by
        ;; ordinary editor commands outside mode-line formatting.
        (visual-line-table--reset-column-cache)
        (should (< (current-column) 120))
        ;; Ordinary text keeps the usual treatment of invisible characters.
        (goto-char (+ (point-min) 30))
        (put-text-property (+ (point-min) 5) (+ (point-min) 15)
                           'invisible 'vltable-test-hidden)
        (visual-line-table--refresh)
        (vltable-test--check-column-format original (selected-window))))))

(declare-function doom-modeline "doom-modeline-core" (key &optional default))

(ert-deftest vltable-doom-modeline-absolute-columns ()
  (skip-unless (not noninteractive))
  (skip-unless (require 'doom-modeline nil t))
  (let ((doom-modeline-icon nil)
        (column-number-mode t)
        (line-number-mode t))
    (dolist (zero-based '(nil t))
      (let ((doom-modeline-column-zero-based zero-based))
        (vltable-test--buffer vltable-test--text
          (let ((original (list "%e" (doom-modeline 'main))))
            (setq-local mode-line-format original)
            (forward-line 2)
            (forward-char 120)
            (visual-line-table-mode 1)
            (redisplay t)
            (vltable-test--check-column-format original (selected-window))))))))

(ert-deftest vltable-real-redisplay ()
  "Check actual screen coordinates, not just buffer properties."
  (skip-unless (not noninteractive))
  (vltable-test--buffer vltable-test--text
    (delete-other-windows)
    (visual-line-table-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (set-window-start (selected-window) (point-min))
    (redisplay t)
    (let* ((first (posn-at-point (point-min)))
           (table (save-excursion (forward-line 2) (point)))
           (next (save-excursion (forward-line 3) (point)))
           (a (posn-at-point table))
           (b (posn-at-point next)))
      (should first)
      (should a)
      (should b)
      (should (> (cdr (posn-x-y a)) (+ 2 (cdr (posn-x-y first)))))
      (should (= (- (cdr (posn-x-y b)) (cdr (posn-x-y a)))
                 (frame-char-height))))))

(declare-function markdown-mode "markdown-mode" ())
(declare-function gfm-mode "markdown-mode" ())
(declare-function markdown-beginning-of-line "markdown-mode" (&optional n))
(declare-function markdown-end-of-line "markdown-mode" (&optional n))

(defmacro vltable-test--markdown-buffer (mode text &rest body)
  "Run BODY with TEXT displayed in a Markdown buffer using MODE."
  (declare (indent 2) (debug t))
  `(progn
     (skip-unless (require 'markdown-mode nil t))
     (save-window-excursion
       (with-temp-buffer
         (funcall ,mode)
         (insert ,text)
         (goto-char (point-min))
         (set-window-buffer (selected-window) (current-buffer))
         (set-window-hscroll (selected-window) 0)
         (set-window-start (selected-window) (point-min))
         (unwind-protect
             (progn ,@body)
           (when visual-line-table-mode (visual-line-table-mode -1)))))))

(defconst vltable-test--markdown-text
  (concat (apply #'concat (make-list 70 "prose ")) "\n\n"
          "Name | Description\n:--- | ---:\n"
          "one | " (make-string 220 ?x) "\n"
          "two | " (make-string 220 ?y) "\n\nAfter.\n"))

(ert-deftest vltable-markdown-table-bounds ()
  (dolist (mode '(markdown-mode gfm-mode))
    (dolist (text '("| A | B |\n| --- | :---: |\n| x | y |\n"
                    "A | B\n--- | ---:\nx | y\n"
                    "  | A |\n  | --- |\n  | x |"
                    "| A | B |\n--- | ---\nx | y | extra\n| short |\n"
                    "a\\|b | `c|d`\n--- | ---\nx | y\n"
                    "``a`|b`` | c\n--- | ---\nx | y\n"
                    "`unmatched | b\n--- | ---\nx | y\n"
                    "A | B\n--- | ---\nonly-one-cell\nx | y\n"))
      (vltable-test--markdown-buffer mode text
        (let ((bounds (cons (point-min) (point-max))))
          (while (not (eobp))
            (should (equal (visual-line-table--table) bounds))
            (forward-line 1)))))))

(ert-deftest vltable-markdown-not-tables ()
  (dolist (mode '(markdown-mode gfm-mode))
    (dolist (text '("plain prose | with a pipe\n"
                    "| A | B |\n| x | y |\n"
                    "A | B\n--- | --\nx | y\n"
                    "A | B\n--- | --- | ---\nx | y\n"
                    "a\\|b\n--- | ---\nx | y\n"
                    "`a|b`\n--- | ---\nx | y\n"
                    "A | B\nnot a delimiter\nx | y\n"))
      (vltable-test--markdown-buffer mode text
        (visual-line-table-mode 1)
        (should-not (visual-line-table--markdown-tables))
        (should-not visual-line-table--overlays)))))

(ert-deftest vltable-markdown-ignores-code-blocks ()
  (dolist (mode '(markdown-mode gfm-mode))
    (dolist (text '("```markdown\nA | B\n--- | ---\nx | y\n```\n"
                    "~~~\n| A | B |\n| --- | --- |\n| x | y |\n~~~\n"
                    "    A | B\n    --- | ---\n    x | y\n"
                    "```\nA | B\n--- | ---\nx | y\n"
                    "~~~~\nA | B\n--- | ---\nx | y\n~~~\nstill | code\n"
                    "````\nA | B\n--- | ---\nx | y\n```\n"))
      (vltable-test--markdown-buffer mode text
        (visual-line-table-mode 1)
        (while (not (eobp))
          (should-not (visual-line-table--table))
          (forward-line 1))
        (should-not visual-line-table--overlays)))))

(ert-deftest vltable-markdown-cells ()
  (vltable-test--markdown-buffer #'markdown-mode
      "| a\\|b | `c|d` | ``e`|f`` | g\\\\ | h |\n"
    (should (equal (visual-line-table--markdown-cells)
                   '("a\\|b" "`c|d`" "``e`|f``" "g\\\\" "h")))))

(ert-deftest vltable-markdown-wrap-scroll-and-follow ()
  (dolist (mode '(markdown-mode gfm-mode))
    (vltable-test--markdown-buffer mode vltable-test--markdown-text
      (visual-line-table-mode 1)
      (should-not (vltable-test--one-screen-row-p))
      (forward-line 4)
      (should (vltable-test--one-screen-row-p))
      (visual-line-table-scroll-left 100)
      (should (= (plist-get (visual-line-table--state (selected-window)) :offset) 100))
      (should (= (let ((buffer-invisibility-spec nil)) (current-column)) 100))
      (should (vltable-test--one-screen-row-p))
      (visual-line-table-scroll-right 50)
      (should (= (plist-get (visual-line-table--state (selected-window)) :offset) 50))
      (visual-line-table--clear)
      (end-of-line)
      (visual-line-table--refresh)
      (should-not (invisible-p (1- (point))))
      (should (vltable-test--one-screen-row-p))
      (goto-char (point-min))
      (visual-line-table--refresh)
      (should (= (plist-get (visual-line-table--state (selected-window)) :offset) 0))
      (should-not (vltable-test--one-screen-row-p))
      (should (= (window-hscroll) 0)))))

(ert-deftest vltable-markdown-updates-after-edit ()
  (vltable-test--markdown-buffer #'markdown-mode
      (concat "A | B\nnot a delimiter\nx | " (make-string 220 ?x) "\n")
    (visual-line-table-mode 1)
    (should-not visual-line-table--overlays)
    (forward-line 1)
    (delete-region (point) (line-end-position))
    (insert "--- | ---")
    (should visual-line-table--overlays)
    (should (visual-line-table--table))
    (beginning-of-line)
    (delete-char 1)
    (should-not (visual-line-table--table))
    (should-not visual-line-table--overlays)))

(ert-deftest vltable-markdown-updates-code-context ()
  (vltable-test--markdown-buffer #'gfm-mode
      (concat "A | B\n--- | ---\nx | " (make-string 220 ?x) "\n")
    (visual-line-table-mode 1)
    (should visual-line-table--overlays)
    (insert "```\n")
    (should-not visual-line-table--overlays)
    (should-not (visual-line-table--markdown-tables))
    (delete-region (point-min) (+ (point-min) 4))
    (should visual-line-table--overlays)))

(ert-deftest vltable-markdown-independent-tables-and-windows ()
  (vltable-test--markdown-buffer #'markdown-mode
      (concat vltable-test--markdown-text "\n" vltable-test--markdown-text)
    (delete-other-windows)
    (forward-line 4)
    (let ((second (split-window-right 30)))
      (set-window-point second (+ (line-beginning-position) 180))
      (visual-line-table-mode 1)
      (should (= (plist-get (visual-line-table--state (selected-window)) :offset) 0))
      (should (> (plist-get (visual-line-table--state second) :offset) 0))
      (visual-line-table-scroll-left 100)
      (should (= (plist-get (visual-line-table--state (selected-window)) :offset) 100))
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (should (vltable-test--one-screen-row-p))))
      (save-excursion
        (goto-char (point-max)) (forward-line -4)
        (should (visual-line-table--table))
        (should-not (invisible-p (line-beginning-position))))
      (window-resize (selected-window) 5 t)
      (visual-line-table--refresh)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (should (vltable-test--one-screen-row-p)))))))

(ert-deftest vltable-markdown-restores-settings-and-read-only-buffer ()
  (dolist (mode '(markdown-mode gfm-mode))
    (vltable-test--markdown-buffer mode vltable-test--markdown-text
      (setq-local truncate-lines t word-wrap nil)
      (setq buffer-read-only t)
      (set-buffer-modified-p nil)
      (let ((original (buffer-string)) (undo buffer-undo-list)
            (tick (buffer-chars-modified-tick))
            (format mode-line-format) (spec (copy-tree buffer-invisibility-spec)))
        (visual-line-table-mode 1)
        (should visual-line-table--overlays)
        (visual-line-table-mode -1)
        (should truncate-lines)
        (should-not word-wrap)
        (should-not visual-line-mode)
        (should-not visual-line-table--overlays)
        (should-not visual-line-table--markdown-cache)
        (should (equal mode-line-format format))
        (should (equal buffer-invisibility-spec spec))
        (should (equal original (buffer-string)))
        (should (equal undo buffer-undo-list))
        (should (= tick (buffer-chars-modified-tick)))
        (should-not (buffer-modified-p))))))

(ert-deftest vltable-markdown-home-end-and-prose ()
  (dolist (mode '(markdown-mode gfm-mode))
    (vltable-test--markdown-buffer mode vltable-test--markdown-text
      (visual-line-table-mode 1)
      (should (eq (command-remapping #'markdown-beginning-of-line)
                  #'visual-line-table-beginning-of-line))
      (should (eq (command-remapping #'markdown-end-of-line)
                  #'visual-line-table-end-of-line))
      (forward-line 4)
      (visual-line-table--clear)
      (move-to-column 100)
      (visual-line-table-move-end-of-line)
      (should (eolp))
      (visual-line-table-move-beginning-of-line)
      (should (bolp))
      ;; Outside tables, compare with the major mode and Visual Line directly.
      (goto-char (point-min)) (forward-char 120)
      (let ((expected (save-excursion (markdown-beginning-of-line) (point))))
        (visual-line-table-move-beginning-of-line)
        (should (= (point) expected)))
      (let ((expected (save-excursion (markdown-end-of-line) (point))))
        (visual-line-table-move-end-of-line)
        (should (= (point) expected))))))

(ert-deftest vltable-markdown-navigation-and-boundary ()
  (vltable-test--markdown-buffer #'gfm-mode vltable-test--markdown-text
    (forward-line 4) (forward-char 100)
    (visual-line-table-mode 1)
    (let ((this-command 'next-line) (last-command-event 'down)
          (goal-column 100) (temporary-goal-column 100))
      (visual-line-table--pre-command)
      (should-not line-move-visual)
      (with-suppressed-warnings ((interactive-only next-line)) (next-line 1))
      (visual-line-table--post-command)
      (should (= (current-column) 100))
      (should line-move-visual)
      (visual-line-table--pre-command)
      (with-suppressed-warnings ((interactive-only next-line)) (next-line 1))
      (visual-line-table--post-command)
      (should (bolp))
      (should-not goal-column)
      (should (= temporary-goal-column 0)))))

(ert-deftest vltable-markdown-table-at-end-of-file ()
  (dolist (mode '(markdown-mode gfm-mode))
    (vltable-test--markdown-buffer mode
        (concat "A | B\n--- | ---\nx | " (make-string 220 ?x))
      (goto-char (point-max))
      (visual-line-table-mode 1)
      (should (visual-line-table--table))
      (should (> (plist-get (visual-line-table--state (selected-window)) :offset) 0))
      (should-not (invisible-p (1- (point))))
      (should (vltable-test--one-screen-row-p))
      (visual-line-table-scroll-right 20)
      (should (visual-line-table--table)))))

(ert-deftest vltable-markdown-single-cell-body-clips ()
  (vltable-test--markdown-buffer #'gfm-mode
      (concat "A | B\n--- | ---\n" (make-string 220 ?x) "\nx | y\n\nAfter\n")
    (visual-line-table-mode 1)
    (forward-line 2)
    (should (visual-line-table--table))
    (should (vltable-test--one-screen-row-p))
    (visual-line-table-scroll-left 100)
    (should (vltable-test--one-screen-row-p))
    (forward-line 1)
    (should (visual-line-table--table))
    (forward-line 1)
    (should-not (visual-line-table--table))))

(ert-deftest vltable-markdown-body-stops-at-block-boundaries ()
  (dolist (following '("\n" "# Heading\n" "- list item\n" "> quote\n"
                       "***\n" "<div>\n" "```\ncode\n```\n"))
    (vltable-test--markdown-buffer #'gfm-mode
        (concat "A | B\n--- | ---\nx | y\n" following)
      (let ((end (save-excursion (forward-line 3) (point))))
        (should (equal (visual-line-table--table) (cons (point-min) end)))
        (goto-char end)
        (should-not (visual-line-table--table))))))

(ert-deftest vltable-markdown-keyboard-pages ()
  (skip-unless (not noninteractive))
  (dolist (mode '(markdown-mode gfm-mode))
    (dolist (wrapper '(nil t))
      (let (traces)
        (dolist (enabled '(nil t))
          (vltable-test--markdown-buffer mode
              (concat "A | B\n--- | ---\n"
                      (apply #'concat (make-list 180
                                                 (concat "x | " (make-string 220 ?x) "\n"))))
            (setq-local truncate-lines t scroll-preserve-screen-position t)
            (when wrapper
              (use-local-map (copy-keymap (current-local-map)))
              (with-suppressed-warnings ((interactive-only next-line previous-line))
                (local-set-key [next] (lambda () (interactive) (next-line 35)))
                (local-set-key [prior] (lambda () (interactive) (previous-line 35)))))
            (forward-line 40) (forward-char 100)
            (when enabled (visual-line-table-mode 1))
            (set-window-start (selected-window)
                              (save-excursion (forward-line -10) (point)))
            (redisplay t)
            (let (trace)
              (dolist (event '(next next prior prior))
                (execute-kbd-macro (vector event))
                (redisplay t)
                (push (list (line-number-at-pos)
                            (let ((buffer-invisibility-spec nil)) (current-column))
                            (line-number-at-pos (window-start))) trace))
              (push (nreverse trace) traces))))
        (should (equal (car traces) (cadr traces)))))))

(ert-deftest vltable-markdown-keyboard-navigation ()
  (skip-unless (not noninteractive))
  (dolist (mode '(markdown-mode gfm-mode))
    (vltable-test--markdown-buffer mode vltable-test--markdown-text
      (forward-line 4) (forward-char 100)
      (visual-line-table-mode 1)
      (redisplay t)
      (execute-kbd-macro (kbd "C-n"))
      (redisplay t)
      (should (= (line-number-at-pos) 6))
      (should (= (let ((buffer-invisibility-spec nil)) (current-column)) 100))
      (execute-kbd-macro (kbd "<end>"))
      (redisplay t)
      (should (eolp))
      (should-not (invisible-p (1- (point))))
      (execute-kbd-macro (kbd "<home>"))
      (redisplay t)
      (should (bolp))
      (should (vltable-test--one-screen-row-p))
      (execute-kbd-macro (kbd "C-n"))
      (should (bolp))
      (should-not (visual-line-table--table)))))

;;; visual-line-table-mode-test.el ends here
