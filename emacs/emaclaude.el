;;; tools/emaclaude/emaclaude.el -*- lexical-binding: t; -*-
;;
;; Doom Emacs module for emaclaude — an Emacs-native interface to Claude Code
;; for multi-agent planning, coding, and review workflows.

(require 'json)
(require 'url)

;;; --- Customization group ---

(defgroup emaclaude nil
  "Emacs interface for the emaclaude daemon."
  :group 'tools
  :prefix "emaclaude-")

(defcustom emaclaude-port 7878
  "Port the emaclaude daemon listens on."
  :type 'integer
  :group 'emaclaude)

(defcustom emaclaude-daemon-path "emaclaude"
  "Path to the emaclaude daemon binary."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-planning "*mra-planning*"
  "Buffer name for the planning agent."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-coding "*mra-coding*"
  "Buffer name for the coding agent."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-review "*mra-review*"
  "Buffer name for the review agent."
  :type 'string
  :group 'emaclaude)

(defcustom emaclaude-buffer-diff "*mra-diff*"
  "Buffer name for the diff view."
  :type 'string
  :group 'emaclaude)

;;; --- Internal state ---

(defvar emaclaude--daemon-process nil
  "Process object for the running emaclaude daemon.")

(defvar emaclaude--saved-window-config nil
  "Window configuration saved before launching emaclaude.")

(defvar-local emaclaude--review-comments nil
  "Buffer-local list of review comments for the current diff buffer.")

;;; --- HTTP helpers ---

(defun emaclaude--post (endpoint payload &optional callback)
  "POST PAYLOAD (alist) as JSON to the daemon ENDPOINT.
CALLBACK is called with the response buffer if provided."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data (encode-coding-string (json-encode payload) 'utf-8))
        (url (format "http://127.0.0.1:%d%s" emaclaude-port endpoint)))
    (if callback
        (url-retrieve url callback nil t t)
      (url-retrieve url (lambda (_status) (kill-buffer (current-buffer))) nil t t))))

;;; --- Internal functions ---

(defun emaclaude--spawn-buffer (name cmd)
  "Create a vterm buffer named NAME and send CMD to it."
  (require 'vterm)
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (unless (eq major-mode 'vterm-mode)
        (vterm-mode)))
    (display-buffer buf)
    (with-current-buffer buf
      (vterm-send-string cmd)
      (vterm-send-return))
    buf))

(defun emaclaude--split-layout ()
  "Create a three-way split: planning left, coding top-right, review bottom-right."
  (delete-other-windows)
  ;; Left: planning
  (switch-to-buffer (get-buffer-create emaclaude-buffer-planning))
  ;; Right side
  (let ((right-window (split-window-right)))
    (select-window right-window)
    ;; Top-right: coding
    (switch-to-buffer (get-buffer-create emaclaude-buffer-coding))
    ;; Bottom-right: review
    (let ((bottom-right (split-window-below)))
      (select-window bottom-right)
      (switch-to-buffer (get-buffer-create emaclaude-buffer-review))))
  ;; Return focus to planning
  (select-window (get-buffer-window emaclaude-buffer-planning)))

(defun emaclaude--send-to-buffer (name text)
  "Send TEXT followed by return to the vterm buffer named NAME."
  (require 'vterm)
  (let ((buf (get-buffer name)))
    (when buf
      (with-current-buffer buf
        (vterm-send-string text)
        (vterm-send-return)))))

(defun emaclaude--open-diff-view ()
  "Open a magit diff (main...HEAD) in the rightmost split."
  (require 'magit)
  (let ((win (car (last (window-list)))))
    (select-window win)
    (magit-diff-range "main...HEAD")
    (rename-buffer emaclaude-buffer-diff t)
    (emaclaude-review-mode 1)))

(defun emaclaude--refresh-diff ()
  "Refresh the magit diff buffer."
  (let ((buf (get-buffer emaclaude-buffer-diff)))
    (when buf
      (with-current-buffer buf
        (when (derived-mode-p 'magit-diff-mode)
          (magit-refresh))))))

(defun emaclaude--notify (msg)
  "Display MSG in the minibuffer."
  (message "[emaclaude] %s" msg))

(defun emaclaude--clear-session ()
  "Alias for `emaclaude-clear-session'."
  (emaclaude-clear-session))

;;; --- Public interactive commands ---

;;;###autoload
(defun emaclaude-launch ()
  "Save window configuration, start the emaclaude daemon, and spawn the planning vterm."
  (interactive)
  (setq emaclaude--saved-window-config (current-window-configuration))
  ;; Start the daemon process
  (setq emaclaude--daemon-process
        (start-process "emaclaude-daemon" "*emaclaude-daemon*"
                       emaclaude-daemon-path
                       "serve"
                       "--port" (number-to-string emaclaude-port)))
  (set-process-sentinel emaclaude--daemon-process
                        (lambda (proc event)
                          (emaclaude--notify (format "daemon %s" (string-trim event)))))
  (emaclaude--notify (format "daemon started on port %d" emaclaude-port))
  ;; Spawn the planning buffer
  (emaclaude--spawn-buffer emaclaude-buffer-planning ""))

;;;###autoload
(defun emaclaude-clear-session ()
  "Send /exit to all vterm buffers, kill them after timeout, stop daemon, restore windows."
  (interactive)
  ;; Send /exit to each agent buffer
  (dolist (name (list emaclaude-buffer-planning
                      emaclaude-buffer-coding
                      emaclaude-buffer-review))
    (let ((buf (get-buffer name)))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (when (eq major-mode 'vterm-mode)
            (vterm-send-string "/exit")
            (vterm-send-return))))))
  ;; Kill buffers after 5 second timeout
  (run-at-time 5 nil
               (lambda ()
                 (dolist (name (list emaclaude-buffer-planning
                                     emaclaude-buffer-coding
                                     emaclaude-buffer-review
                                     emaclaude-buffer-diff))
                   (let ((buf (get-buffer name)))
                     (when (and buf (buffer-live-p buf))
                       (kill-buffer buf))))))
  ;; Stop daemon
  (when (and emaclaude--daemon-process
             (process-live-p emaclaude--daemon-process))
    (kill-process emaclaude--daemon-process)
    (setq emaclaude--daemon-process nil))
  ;; Restore window configuration
  (when emaclaude--saved-window-config
    (set-window-configuration emaclaude--saved-window-config)
    (setq emaclaude--saved-window-config nil))
  (emaclaude--notify "session cleared"))

;;;###autoload
(defun emaclaude-address-github-reviews ()
  "Prompt for a PR number and POST it to the daemon to address GitHub reviews."
  (interactive)
  (let ((pr-number (read-number "PR number: ")))
    (emaclaude--post "/address-reviews"
                     `((pr_number . ,pr-number))
                     (lambda (_status)
                       (emaclaude--notify (format "addressing reviews for PR #%d" pr-number))
                       (kill-buffer (current-buffer))))))

;;; --- Review minor mode ---

(defvar emaclaude-review-mode-map (make-sparse-keymap)
  "Keymap for `emaclaude-review-mode'.")

;;;###autoload
(define-minor-mode emaclaude-review-mode
  "Minor mode for reviewing diffs in emaclaude."
  :lighter " EC-Review"
  :keymap emaclaude-review-mode-map
  (if emaclaude-review-mode
      (setq-local emaclaude--review-comments nil)
    (emaclaude--remove-comment-overlays)))

;;; --- Review functions ---

(defun emaclaude--remove-comment-overlays ()
  "Remove all emaclaude comment overlays from the current buffer."
  (remove-overlays (point-min) (point-max) 'emaclaude-comment t))

(defun emaclaude-add-comment ()
  "Prompt for a comment at the current hunk and store it."
  (interactive)
  (let* ((line (line-number-at-pos))
         (text (read-string (format "Comment at line %d: " line)))
         (ov (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put ov 'emaclaude-comment t)
    (overlay-put ov 'after-string
                 (propertize (format "  # %s" text)
                             'face 'font-lock-comment-face))
    (push `((line . ,line) (text . ,text)) emaclaude--review-comments)
    (emaclaude--notify (format "comment added at line %d" line))))

(defun emaclaude-submit-comments ()
  "POST all review comments to the daemon /human-review endpoint."
  (interactive)
  (if (null emaclaude--review-comments)
      (emaclaude--notify "no comments to submit")
    (emaclaude--post "/human-review"
                     `((comments . ,(vconcat emaclaude--review-comments)))
                     (lambda (_status)
                       (emaclaude--notify
                        (format "submitted %d comment(s)"
                                (length emaclaude--review-comments)))
                       (kill-buffer (current-buffer))))
    (setq emaclaude--review-comments nil)))

(defun emaclaude-create-pr ()
  "POST to the daemon /create-pr endpoint to create a pull request."
  (interactive)
  (emaclaude--post "/create-pr" nil
                   (lambda (_status)
                     (emaclaude--notify "PR creation requested")
                     (kill-buffer (current-buffer)))))

(defun emaclaude-close-diff ()
  "Remove comment overlays and kill the diff buffer."
  (interactive)
  (emaclaude--remove-comment-overlays)
  (let ((buf (get-buffer emaclaude-buffer-diff)))
    (when (and buf (buffer-live-p buf))
      (kill-buffer buf)))
  (emaclaude--notify "diff view closed"))

(provide 'emaclaude)
;;; emaclaude.el ends here
