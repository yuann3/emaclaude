;;; tools/emaclaude/emaclaude.el -*- lexical-binding: t; -*-
;;
;; Doom Emacs module for emaclaude — an Emacs-native interface to Claude Code
;; for multi-agent planning, coding, and review workflows.

(require 'json)
(require 'map)
(require 'seq)
(require 'agent-shell)

;;; --- Customization group ---

(defgroup emaclaude nil
  "Emacs interface for the emaclaude CLI orchestrator."
  :group 'tools
  :prefix "emaclaude-")

(defcustom emaclaude-daemon-path "emaclaude"
  "Path to the emaclaude CLI binary."
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

;;; --- Workflow configuration ---

(defcustom emaclaude-confirmation-loops 2
  "Number of confirmation review passes before human review."
  :type 'integer
  :group 'emaclaude)

(defcustom emaclaude-watchdog-timeout 600
  "Seconds of inactivity before the watchdog notifies the user.
Default is 600 (10 minutes)."
  :type 'integer
  :group 'emaclaude)

;;; --- Internal state ---

(defvar emaclaude--workflow-state "\"Idle\""
  "Current workflow state as a JSON string.
This is the serialized WorkflowState from the Rust state machine.")

(defvar emaclaude--selected-agent-config nil
  "The agent-shell config selected at launch time.")

(defvar emaclaude--saved-window-config nil
  "Window configuration saved before launching emaclaude.")

(defvar emaclaude--agent-buffers nil
  "Alist mapping logical names to actual agent-shell buffer objects.
Keys are `emaclaude-buffer-planning', `emaclaude-buffer-coding', etc.")

(defvar-local emaclaude--review-comments nil
  "Buffer-local list of review comments for the current diff buffer.")

(defvar emaclaude--watchdog-timer nil
  "Timer for the inactivity watchdog.
Fires after `emaclaude-watchdog-timeout' seconds with no signal.")

;;; --- Logging ---

(defun emaclaude--log-event (event-type &optional from to payload)
  "Append a JSONL log entry to ~/.emaclaude/logs/YYYY-MM-DD.jsonl.
EVENT-TYPE is a string describing the event.
FROM and TO are optional state names.
PAYLOAD is an optional string or object to include."
  (let* ((log-dir (expand-file-name "logs" "~/.emaclaude"))
         (log-file (expand-file-name
                    (format "%s.jsonl" (format-time-string "%Y-%m-%d"))
                    log-dir))
         (entry `((timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                  (event . ,event-type)
                  ,@(when from `((from . ,from)))
                  ,@(when to `((to . ,to)))
                  ,@(when payload `((payload . ,payload)))))
         (line (concat (json-encode entry) "\n")))
    (make-directory log-dir t)
    (write-region line nil log-file 'append 'silent)))

;;; --- Watchdog ---

(defun emaclaude--reset-watchdog ()
  "Reset the inactivity watchdog timer.
Cancels any existing timer and starts a new one that fires after
`emaclaude-watchdog-timeout' seconds."
  (emaclaude--cancel-watchdog)
  (setq emaclaude--watchdog-timer
        (run-at-time emaclaude-watchdog-timeout nil
                     (lambda ()
                       (emaclaude--notify
                        (format "watchdog: no signal for %d seconds"
                                emaclaude-watchdog-timeout))))))

(defun emaclaude--cancel-watchdog ()
  "Cancel the inactivity watchdog timer if active."
  (when (timerp emaclaude--watchdog-timer)
    (cancel-timer emaclaude--watchdog-timer)
    (setq emaclaude--watchdog-timer nil)))

;;; --- Internal functions ---

(defun emaclaude--role-label (name)
  "Extract a short role label from logical buffer NAME.
E.g. \"*mra-planning*\" → \"Planning\"."
  (cond
   ((string= name emaclaude-buffer-planning) "Planning")
   ((string= name emaclaude-buffer-coding) "Coding")
   ((string= name emaclaude-buffer-review) "Review")
   (t "Agent")))

(defun emaclaude--spawn-buffer (name config)
  "Create an agent-shell buffer for NAME using agent CONFIG.
Overrides :buffer-name in the config to include the role label
so buffers are visually distinguishable. Registers the buffer
in `emaclaude--agent-buffers' under NAME.
CONFIG is an agent-shell agent configuration alist."
  (let* ((default-directory (or (and (fboundp 'doom-project-root) (doom-project-root))
                                (and (fboundp 'projectile-project-root) (projectile-project-root))
                                default-directory))
         (role (emaclaude--role-label name))
         (labeled-config (cons (cons :buffer-name
                                     (format "%s [%s]"
                                             (or (map-elt config :buffer-name) "Agent")
                                             role))
                               config))
         (buf (agent-shell-start :config labeled-config)))
    (when (and buf (buffer-live-p buf))
      (setf (alist-get name emaclaude--agent-buffers nil nil #'equal) buf))
    buf))

(defun emaclaude--get-buffer (name)
  "Get the agent-shell buffer registered under logical NAME.
Returns the buffer object or nil if not found or not alive."
  (let ((buf (alist-get name emaclaude--agent-buffers nil nil #'equal)))
    (when (and buf (buffer-live-p buf))
      buf)))

(defun emaclaude--split-layout ()
  "Create a three-way split: planning left, coding top-right, review bottom-right."
  (delete-other-windows)
  (let ((plan-buf (emaclaude--get-buffer emaclaude-buffer-planning))
        (code-buf (emaclaude--get-buffer emaclaude-buffer-coding))
        (review-buf (emaclaude--get-buffer emaclaude-buffer-review)))
    ;; Left: planning
    (when plan-buf (switch-to-buffer plan-buf))
    ;; Right side
    (let ((right-window (split-window-right)))
      (select-window right-window)
      ;; Top-right: coding
      (when code-buf (switch-to-buffer code-buf))
      ;; Bottom-right: review
      (let ((bottom-right (split-window-below)))
        (select-window bottom-right)
        (when review-buf (switch-to-buffer review-buf))))
    ;; Return focus to planning
    (when plan-buf
      (select-window (get-buffer-window plan-buf)))))

(defun emaclaude--send-to-buffer (name text)
  "Send TEXT to the agent-shell buffer named NAME.
Uses agent-shell-insert to submit the text as a prompt."
  (let ((buf (get-buffer name)))
    (when buf
      (agent-shell-insert :text text :submit t :shell-buffer buf))))

(defun emaclaude-spawn-agent (name)
  "Spawn an agent-shell buffer with NAME using the stored config.
If a buffer registered under NAME already exists, returns it.
Uses `emaclaude--selected-agent-config' set during `emaclaude-launch'.
Signals an error if no config has been selected."
  (unless emaclaude--selected-agent-config
    (user-error "No agent config selected; run `emaclaude-launch' first"))
  (or (emaclaude--get-buffer name)
      (emaclaude--spawn-buffer name emaclaude--selected-agent-config)))

(defun emaclaude-send-to-agent (name message)
  "Send MESSAGE to the agent-shell buffer registered under NAME.
If the agent is busy, enqueue MESSAGE for automatic delivery.
Returns nil if the buffer does not exist."
  (let ((buf (emaclaude--get-buffer name)))
    (when buf
      (emaclaude--log-event "send-to-agent" nil name message)
      (with-current-buffer buf
        (if (shell-maker-busy)
            ;; NOTE: agent-shell--enqueue-request is a private API.
            ;; No public queueing API exists as of agent-shell 0.33.
            (agent-shell--enqueue-request :prompt message)
          (shell-maker-submit :input message)))
      t)))

(defun emaclaude--diff-base ()
  "Return the base ref for the diff view.
Always diffs against main so the review shows all feature-branch changes."
  "main")

(defun emaclaude--open-diff-view ()
  "Open a magit diff comparing current branch against main.
Sets `default-directory' from the git toplevel for worktree support.
Expands all file sections so changes are visible per-file."
  (require 'magit)
  (let* ((win (car (last (window-list))))
         (base (emaclaude--diff-base))
         (default-directory (or (magit-toplevel) default-directory)))
    (select-window win)
    (magit-diff-range (format "%s..HEAD" base))
    (rename-buffer emaclaude-buffer-diff t)
    ;; Expand all file sections so diffs are visible
    (magit-section-show-level-4-all)
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

(defun emaclaude--cleanup-buffers-and-windows ()
  "Clean up agent buffers and restore window configuration.
Called by the Shutdown effect during session teardown."
  ;; Kill registered agent-shell buffers
  (dolist (entry emaclaude--agent-buffers)
    (let ((buf (cdr entry)))
      (when (and buf (buffer-live-p buf))
        (let ((proc (get-buffer-process buf)))
          (when proc
            (set-process-query-on-exit-flag proc nil)))
        (kill-buffer buf))))
  ;; Kill diff buffer by name (not in agent-buffers alist)
  (let ((diff-buf (get-buffer emaclaude-buffer-diff)))
    (when (and diff-buf (buffer-live-p diff-buf))
      (kill-buffer diff-buf)))
  ;; Clear state
  (setq emaclaude--agent-buffers nil)
  (setq emaclaude--selected-agent-config nil)
  (setq emaclaude--workflow-state "\"Idle\"")
  ;; Restore window configuration
  (when emaclaude--saved-window-config
    (set-window-configuration emaclaude--saved-window-config)
    (setq emaclaude--saved-window-config nil))
  (emaclaude--notify "session cleared"))


;;; --- Signal handling ---

(defun emaclaude--map-event (event &optional payload)
  "Map EVENT name and PAYLOAD string to a Rust Event JSON alist.
EVENT is a kebab-case string from emaclaude-signal.
PAYLOAD is a JSON string with event-specific data.
Returns an alist suitable for `json-encode'."
  (let ((data (and payload (not (string-empty-p payload))
                   (json-read-from-string payload))))
    (pcase event
      ("planning-done"
       `(("PlanningDone" . ((prompt . ,(alist-get 'prompt data))
                            (spec_path . ,(alist-get 'spec_path data))))))
      ("coding-done"
       `(("CodingDone" . ((branch . ,(or (alist-get 'branch data) "current"))))))
      ("review-done"
       (let* ((raw-status (alist-get 'status data))
              (status (pcase raw-status
                        ("approved" "Approved")
                        ("changes_needed" "ChangesNeeded")
                        (_ raw-status)))
              (feedback (or (alist-get 'feedback data) "")))
         `(("ReviewDone" . ((status . ,status)
                            (feedback . ,feedback))))))
      ("human-comments"
       `(("HumanComments" . ((comments . ,(alist-get 'comments data))))))
      ("create-pr" "CreatePr")
      ("address-github-reviews"
       `(("AddressGithubReviews" . ((pr_number . ,(alist-get 'pr_number data))))))
      ("clear-session" "ClearSession")
      (_ (error "Unknown event: %s" event)))))

(defun emaclaude--dispatch-effect (effect)
  "Dispatch a single parameterized EFFECT from the Rust state machine.
EFFECT is either a string (for simple effects) or an alist (for
effects with data)."
  (cond
   ;; String effects (no data)
   ((equal effect "SpawnReviewAgent")
    (emaclaude-spawn-agent emaclaude-buffer-review))
   ((equal effect "OpenDiffView")
    (emaclaude--open-diff-view))
   ((equal effect "RefreshDiffView")
    (emaclaude--refresh-diff))
   ((equal effect "Shutdown")
    (setq emaclaude--workflow-state "\"Idle\"")
    (emaclaude--cleanup-buffers-and-windows))
   ;; Object effects (with data) — json-read-from-string produces symbol keys
   ((assoc 'SpawnCodingAgent effect)
    (let* ((data (cdr (assoc 'SpawnCodingAgent effect)))
           (prompt (alist-get 'prompt data))
           (spec-path (alist-get 'spec_path data))
           (full-prompt (if spec-path
                            (format "%s\n\nSpec file: %s" prompt spec-path)
                          prompt)))
      (emaclaude-spawn-agent emaclaude-buffer-coding)
      (emaclaude-send-to-agent emaclaude-buffer-coding full-prompt)))
   ((assoc 'SendToCodingAgent effect)
    (let ((prompt (alist-get 'prompt (cdr (assoc 'SendToCodingAgent effect)))))
      (emaclaude-send-to-agent emaclaude-buffer-coding prompt)))
   ((assoc 'SendToReviewAgent effect)
    (let ((prompt (alist-get 'prompt (cdr (assoc 'SendToReviewAgent effect)))))
      (emaclaude-send-to-agent emaclaude-buffer-review prompt)))
   ((assoc 'Notify effect)
    (let ((message (alist-get 'message (cdr (assoc 'Notify effect)))))
      (emaclaude--notify message)))
   (t (emaclaude--notify (format "unknown effect: %S" effect)))))

;;;###autoload
(defun emaclaude--handle-event (event &optional payload)
  "Handle an agent signal EVENT with optional JSON PAYLOAD string.
Called by the emaclaude-signal CLI script via emacsclient --eval.

Maps the event to the Rust state machine JSON format, pipes it through
the CLI binary, updates workflow state, and dispatches resulting effects."
  (emaclaude--notify (format "event received: %s (payload: %s)" event (or payload "{}")))
  (let ((old-state emaclaude--workflow-state))
    (condition-case err
        (let* ((rust-event (emaclaude--map-event event payload))
               (input `((state . ,(json-read-from-string emaclaude--workflow-state))
                        (event . ,rust-event)
                        (config . ((confirmation_loops . ,emaclaude-confirmation-loops)))))
               (input-json (json-encode input))
               (output (with-temp-buffer
                         (insert input-json)
                         (let ((exit-code (call-process-region
                                          (point-min) (point-max)
                                          emaclaude-daemon-path
                                          t t nil "transition")))
                           (unless (= exit-code 0)
                             (emaclaude--notify
                              (format "CLI exited with code %d: %s"
                                      exit-code (buffer-string))))
                           (buffer-string))))
               (result (json-read-from-string output))
               (new-state (alist-get 'state result))
               (effects (alist-get 'effects result)))
          ;; Check for error response from CLI
          (if (alist-get 'error result)
              (progn
                (emaclaude--notify (format "CLI error: %s" (alist-get 'error result)))
                nil)
            ;; Update workflow state
            (setq emaclaude--workflow-state (json-encode new-state))
            ;; Log the state transition
            (emaclaude--log-event event old-state emaclaude--workflow-state
                                  (or payload "{}"))
            ;; Reset watchdog on successful event handling
            (emaclaude--reset-watchdog)
            ;; Dispatch each effect
            (seq-doseq (effect effects)
              (emaclaude--dispatch-effect effect))
            t))
      (error
       (emaclaude--notify (format "handle-event error: %s" (error-message-string err)))
       nil))))

;;; --- Public interactive commands ---

;;;###autoload
(defun emaclaude-open-diff ()
  "Open the emaclaude diff review view showing local staged+unstaged changes."
  (interactive)
  (emaclaude--open-diff-view))

;;;###autoload
(defun emaclaude-launch ()
  "Prompt for an LLM backend and spawn an agent-shell planning buffer.
The user selects from available agent-shell backends via completing-read.
The resulting buffer is named `emaclaude-buffer-planning'."
  (interactive)
  ;; Prompt user to select an LLM backend from agent-shell configs
  (let ((config (agent-shell-select-config :prompt "Select LLM backend: ")))
    (unless config
      (user-error "No agent config selected"))
    (setq emaclaude--saved-window-config (current-window-configuration))
    (setq emaclaude--selected-agent-config config)
    (emaclaude--notify (format "launching with %s"
                               (or (map-elt config :mode-line-name)
                                   (map-elt config :buffer-name)
                                   "unknown agent")))
    ;; Spawn all three agent buffers via agent-shell
    (emaclaude--spawn-buffer emaclaude-buffer-planning config)
    (emaclaude--spawn-buffer emaclaude-buffer-coding config)
    (emaclaude--spawn-buffer emaclaude-buffer-review config)
    (emaclaude--split-layout)))

;;;###autoload
(defun emaclaude-clear-session ()
  "Kill all agent buffers, cancel watchdog, restore windows.
Drives the state machine through ClearSession -> Shutdown, then
performs direct cleanup as a safety net."
  (interactive)
  ;; Drive the state machine (dispatches Shutdown -> cleanup)
  (ignore-errors
    (emaclaude--handle-event "clear-session"))
  ;; Cancel watchdog timer
  (emaclaude--cancel-watchdog)
  ;; Safety net: ensure cleanup even if state machine fails
  (emaclaude--cleanup-buffers-and-windows))

;;;###autoload
(defun emaclaude-address-github-reviews ()
  "Prompt for a PR number and trigger the state machine to address GitHub reviews."
  (interactive)
  (let ((pr-number (read-number "PR number: ")))
    (emaclaude--handle-event "address-github-reviews"
                             (json-encode `((pr_number . ,pr-number))))
    (emaclaude--notify (format "Addressing reviews for PR #%d" pr-number))))

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

(defun emaclaude-add-comment (beg end)
  "Prompt for a review comment on the current line or visual selection.
Works with evil visual line mode (Shift-V): select lines, then SPC m c."
  (interactive
   (if (and (bound-and-true-p evil-mode)
            (evil-visual-state-p))
       (list (region-beginning) (region-end))
     (list (line-beginning-position) (line-end-position))))
  (let* ((file (or (magit-file-at-point) "unknown"))
         (start-line (line-number-at-pos beg))
         (end-line (line-number-at-pos (max beg (1- end))))
         (line-desc (if (= start-line end-line)
                        (format "%d" start-line)
                      (format "%d-%d" start-line end-line)))
         (text (read-string (format "Comment on %s:%s: " file line-desc)))
         (ov (make-overlay beg end)))
    (overlay-put ov 'emaclaude-comment t)
    (overlay-put ov 'after-string
                 (propertize (format "\n  💬 %s" text)
                             'face '(:foreground "#98be65" :slant italic)))
    (push `((file . ,file)
            (line . ,start-line)
            (end_line . ,end-line)
            (text . ,text))
          emaclaude--review-comments)
    ;; Exit visual state if in evil
    (when (and (bound-and-true-p evil-mode)
               (evil-visual-state-p))
      (evil-normal-state))
    (emaclaude--notify (format "comment added on %s:%s (%d total)"
                               file line-desc
                               (length emaclaude--review-comments)))))

(defun emaclaude-submit-comments ()
  "Submit all review comments via the state machine."
  (interactive)
  (if (null emaclaude--review-comments)
      (emaclaude--notify "no comments to submit")
    (let* ((comments (vconcat emaclaude--review-comments))
           (payload (json-encode `((comments . ,comments))))
           (count (length emaclaude--review-comments)))
      (emaclaude--handle-event "human-comments" payload)
      (setq emaclaude--review-comments nil)
      (emaclaude--remove-comment-overlays)
      (emaclaude--notify (format "submitted %d comment(s)" count)))))

(defun emaclaude-create-pr ()
  "Request PR creation via the state machine."
  (interactive)
  (emaclaude--handle-event "create-pr" "{}")
  (emaclaude--notify "PR creation requested"))

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
