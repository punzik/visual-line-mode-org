;;; visual-line-mode-org-test.el --- Prototype tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'visual-line-mode-org)

(defmacro vlorg-test--buffer (text &rest body)
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
         (when visual-line-mode-org-mode (visual-line-mode-org-mode -1))))))

(defun vlorg-test--one-screen-row-p ()
  "Whether the current logical line occupies one screen row."
  (let ((next (save-excursion (forward-line 1) (point))))
    (save-excursion
      (beginning-of-line)
      (= (progn (vertical-motion 1) (point)) next))))

(defconst vlorg-test--text
  (concat (apply #'concat (make-list 70 "prose ")) "\n\n"
          "| " (make-string 220 ?x) " |\n"
          "| " (make-string 220 ?y) " |\n\nAfter.\n"))

(ert-deftest vlorg-prose-wraps-table-does-not ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode-org-mode 1)
    (should-not (vlorg-test--one-screen-row-p))
    (forward-line 2)
    (should (vlorg-test--one-screen-row-p))
    (forward-line 1)
    (should (vlorg-test--one-screen-row-p))
    (should (= (window-hscroll) 0))))

(ert-deftest vlorg-restores-settings-and-buffer ()
  (vlorg-test--buffer vlorg-test--text
    (setq-local truncate-lines t)
    (setq-local word-wrap nil)
    (setq-local truncate-partial-width-windows 45)
    (set-buffer-modified-p nil)
    (let ((text (buffer-string))
          (undo buffer-undo-list)
          (tick (buffer-chars-modified-tick)))
      (visual-line-mode-org-mode 1)
      (should visual-line-mode)
      (should-not truncate-lines)
      (should-not (buffer-modified-p))
      (visual-line-mode-org-mode -1)
      (should truncate-lines)
      (should-not word-wrap)
      (should (= truncate-partial-width-windows 45))
      (should-not visual-line-mode)
      (should-not (memq #'visual-line-mode-org--refresh pre-redisplay-functions))
      (should-not visual-line-mode-org--overlays)
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should (= tick (buffer-chars-modified-tick)))
      (should-not (buffer-modified-p)))))

(ert-deftest vlorg-preserves-existing-visual-line-mode ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode 1)
    (let ((state (copy-tree visual-line--saved-state)))
      (visual-line-mode-org-mode 1)
      (visual-line-mode-org-mode -1)
      (should visual-line-mode)
      (should (equal state visual-line--saved-state)))))

(ert-deftest vlorg-scrolls-only-the-table ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode-org-mode 1)
    (forward-line 2)
    (visual-line-mode-org-scroll-left 100)
    (should (= (let ((buffer-invisibility-spec nil)) (current-column)) 100))
    (should (= (plist-get (visual-line-mode-org--state (selected-window)) :offset) 100))
    (should (vlorg-test--one-screen-row-p))
    (should (= (window-hscroll) 0))
    (goto-char (point-min))
    (should-not (vlorg-test--one-screen-row-p))
    (forward-line 2)
    (let ((buffer-invisibility-spec nil)) (move-to-column 100))
    (visual-line-mode-org-scroll-right 50)
    (should (= (let ((buffer-invisibility-spec nil)) (current-column)) 50))
    (should (vlorg-test--one-screen-row-p))))

(ert-deftest vlorg-follows-point ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode-org-mode 1)
    (forward-line 2)
    (end-of-line)
    (visual-line-mode-org--refresh)
    (let ((state (visual-line-mode-org--state (selected-window))))
      (should (> (plist-get state :offset) 0))
      (should (vlorg-test--one-screen-row-p))
      (beginning-of-line)
      (visual-line-mode-org--refresh)
      (should (= (plist-get state :offset) 0)))))

(ert-deftest vlorg-updates-after-edit ()
  (vlorg-test--buffer (concat "text " (make-string 220 ?x) "\n")
    (visual-line-mode-org-mode 1)
    (should-not visual-line-mode-org--overlays)
    (insert "| ")
    (should visual-line-mode-org--overlays)
    (should (vlorg-test--one-screen-row-p))
    (delete-region (point-min) (+ 2 (point-min)))
    (should-not visual-line-mode-org--overlays)
    (should-not (vlorg-test--one-screen-row-p))))

(ert-deftest vlorg-ignores-block-contents ()
  (vlorg-test--buffer
      (concat "#+begin_src text\n| " (make-string 220 ?x)
              "\n#+end_src\n\n#+begin_example\n| " (make-string 220 ?y)
              "\n#+end_example\n")
    (visual-line-mode-org-mode 1)
    (should-not visual-line-mode-org--overlays)))

(ert-deftest vlorg-two-window-widths ()
  (vlorg-test--buffer vlorg-test--text
    (delete-other-windows)
    (let ((second (split-window-right)))
      (visual-line-mode-org-mode 1)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (goto-char (point-min))
          (forward-line 2)
          (should (vlorg-test--one-screen-row-p))))
      (window-resize second -5 t)
      (visual-line-mode-org--refresh)
      (dolist (window (list (selected-window) second))
        (with-selected-window window
          (goto-char (point-min))
          (forward-line 2)
          (should (vlorg-test--one-screen-row-p)))))))

(ert-deftest vlorg-read-only-and-foreign-overlays ()
  (vlorg-test--buffer vlorg-test--text
    (let ((foreign (make-overlay 1 3)))
      (setq buffer-read-only t)
      (visual-line-mode-org-mode 1)
      (visual-line-mode-org-mode -1)
      (should (overlay-buffer foreign)))))

(ert-deftest vlorg-enable-idempotent ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode-org-mode 1)
    (let ((count (length visual-line-mode-org--overlays)))
      (visual-line-mode-org-mode 1)
      (should (= count (length visual-line-mode-org--overlays))))))

(ert-deftest vlorg-empty-and-non-org ()
  (vlorg-test--buffer ""
    (visual-line-mode-org-mode 1)
    (should-not visual-line-mode-org--overlays))
  (with-temp-buffer
    (should-error (visual-line-mode-org-mode 1) :type 'user-error)
    (should-not visual-line-mode-org-mode)))

(ert-deftest vlorg-cleanup-on-major-mode-change ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode-org-mode 1)
    (let ((overlays (copy-sequence visual-line-mode-org--overlays)))
      (fundamental-mode)
      (should-not (cl-some #'overlay-buffer overlays)))))

(ert-deftest vlorg-restores-horizontal-scroll ()
  (vlorg-test--buffer vlorg-test--text
    (set-window-hscroll (selected-window) 5)
    (visual-line-mode-org-mode 1)
    (should (= (window-hscroll) 0))
    (visual-line-mode-org-mode -1)
    (should (= (window-hscroll) 5))))

(ert-deftest vlorg-tabs-and-wide-characters ()
  (dolist (row (list (concat "|\t" (apply #'concat (make-list 50 "xx\t")) "|\n")
                     (concat "| " (make-string 150 ?界) " |\n")))
    (vlorg-test--buffer row
      (visual-line-mode-org-mode 1)
      (should (vlorg-test--one-screen-row-p))
      (visual-line-mode-org-scroll-left 13)
      (should (vlorg-test--one-screen-row-p)))))

(ert-deftest vlorg-org-indent ()
  (vlorg-test--buffer (concat "*** Heading\n| " (make-string 220 ?x) " |\n")
    (org-indent-mode 1)
    (font-lock-ensure)
    (visual-line-mode-org-mode 1)
    (forward-line 1)
    (should (vlorg-test--one-screen-row-p))))

(ert-deftest vlorg-follow-point-after-tab ()
  (vlorg-test--buffer (concat "|\t" (make-string 200 ?x) "\n")
    (visual-line-mode-org-mode 1)
    (let ((buffer-invisibility-spec nil))
      (move-to-column (+ 3 (window-body-width))))
    (visual-line-mode-org--refresh)
    (should-not (invisible-p (point)))
    (should (vlorg-test--one-screen-row-p))))

(ert-deftest vlorg-preserves-other-invisibility-owners ()
  (vlorg-test--buffer vlorg-test--text
    (visual-line-mode-org-mode 1)
    (add-to-invisibility-spec 'other-owner)
    (visual-line-mode-org-mode -1)
    (should (memq 'other-owner buffer-invisibility-spec))
    (should-not (memq 'visual-line-mode-org buffer-invisibility-spec))))

(ert-deftest vlorg-org-table-editing ()
  (let* ((text (concat "| a | " (make-string 180 ?x) " |\n| b | short |\n"))
         (expected (with-temp-buffer
                     (org-mode)
                     (insert text)
                     (goto-char (point-min))
                     (org-table-align)
                     (buffer-string))))
    (vlorg-test--buffer text
      (visual-line-mode-org-mode 1)
      (org-table-align)
      (should (equal (buffer-string) expected))
      (visual-line-mode-org-scroll-left 40)
      (org-table-next-field)
      (visual-line-mode-org--refresh)
      (should-not (invisible-p (point))))))

(defconst vlorg-test--reported-table
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "reported-table.org"
                       (file-name-directory (or load-file-name buffer-file-name))))
    (buffer-string)))

(ert-deftest vlorg-reported-table-with-line-numbers ()
  (vlorg-test--buffer (concat "*** Table\n" vlorg-test--reported-table)
    (setq-local display-line-numbers t
                org-hide-emphasis-markers t)
    (org-indent-mode 1)
    (font-lock-ensure)
    (unless noninteractive (redisplay t))
    (visual-line-mode-org-mode 1)
    (forward-line 1)
    (while (not (eobp))
      (should (vlorg-test--one-screen-row-p))
      (forward-line 1))))

(ert-deftest vlorg-keyboard-navigation-keeps-goal-column ()
  (skip-unless (not noninteractive))
  (vlorg-test--buffer
      (concat "| " (make-string 150 ?a) " |\n| x |\n| "
              (make-string 150 ?c) " |\n")
    (move-to-column 85)
    (visual-line-mode-org-mode 1)
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

(ert-deftest vlorg-home-end-default-bindings ()
  (vlorg-test--buffer vlorg-test--reported-table
    (should (eq (key-binding [home] nil t) #'move-beginning-of-line))
    (should (eq (key-binding [end] nil t) #'move-end-of-line))
    (visual-line-mode-org-mode 1)
    (should (eq (key-binding [home]) #'visual-line-mode-org-move-beginning-of-line))
    (should (eq (key-binding [end]) #'visual-line-mode-org-move-end-of-line))))

(defun vlorg-test--navigation-trace (text row column keys hide enabled
                                       &optional prose redisplay-each default-bindings)
  "Trace KEYS using the user's bindings, optionally redisplaying each key."
  (vlorg-test--buffer text
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
    (when enabled (visual-line-mode-org-mode 1))
    (let* ((positions nil)
           (record (lambda ()
                     (when (memq this-command
                                 '(left-char right-char
                                   org-beginning-of-line org-end-of-line
                                   visual-line-mode-org-beginning-of-line
                                   visual-line-mode-org-end-of-line
                                   visual-line-mode-org-move-beginning-of-line
                                   visual-line-mode-org-move-end-of-line))
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
                    (should (vlorg-test--one-screen-row-p)))
                  (push (list (point) (invisible-p (point))) positions))
              (execute-kbd-macro keys))
            (nreverse positions))
        (remove-hook 'post-command-hook record t)))))

(ert-deftest vlorg-keyboard-home-end-in-tables ()
  (skip-unless (not noninteractive))
  (let ((text (concat "*** Table\n" vlorg-test--reported-table)))
    (dolist (hide '(nil t))
      (dolist (row '(1 3 5))
        (dolist (case '((100 "<home> <home>")
                        (20 "<end> <end>")
                        (105 "<end> <home> <end> <home>")))
          (dolist (default-bindings '(nil t))
            (let* ((keys (kbd (cadr case)))
                   (baseline (vlorg-test--navigation-trace
                              text row (car case) keys hide nil nil nil default-bindings))
                   (actual (vlorg-test--navigation-trace
                            text row (car case) keys hide t nil nil default-bindings)))
              (should baseline)
              (should (equal actual baseline)))))))))

(ert-deftest vlorg-keyboard-left-right-in-tables ()
  (skip-unless (not noninteractive))
  (let ((text (concat "*** Table\n" vlorg-test--reported-table))
        (keys (vconcat (make-list 10 'right) (make-list 10 'left))))
    (dolist (hide '(nil t))
      (dolist (row '(1 3 5))
        (dolist (column '(10 65 105))
          (dolist (redisplay-each '(nil t))
            (let ((baseline (vlorg-test--navigation-trace
                             text row column keys hide nil nil redisplay-each))
                  (actual (vlorg-test--navigation-trace
                           text row column keys hide t nil redisplay-each)))
              (should (= (length baseline) 20))
              (should (equal actual baseline)))))))))

(ert-deftest vlorg-keyboard-home-end-in-prose ()
  (skip-unless (not noninteractive))
  (let ((keys (kbd "<home> <end> <home> <end>")))
    (dolist (default-bindings '(nil t))
      (should (equal (vlorg-test--navigation-trace
                      vlorg-test--text 0 140 keys t t t nil default-bindings)
                     (vlorg-test--navigation-trace
                      vlorg-test--text 0 140 keys t nil t nil default-bindings))))))

(ert-deftest vlorg-real-redisplay ()
  "Check actual screen coordinates, not just buffer properties."
  (skip-unless (not noninteractive))
  (vlorg-test--buffer vlorg-test--text
    (delete-other-windows)
    (visual-line-mode-org-mode 1)
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

;;; visual-line-mode-org-test.el ends here
