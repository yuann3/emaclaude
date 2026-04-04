;;; emaclaude-test.el --- ERT tests for emaclaude -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; We can't require agent-shell in test environment, so mock what we need
;; Provide the feature first so (require 'agent-shell) in emaclaude.el succeeds
(unless (featurep 'agent-shell)
  (defvar agent-shell-agent-configs nil)
  (defun agent-shell-select-config (&rest _) nil)
  (cl-defun agent-shell-start (&key config) nil)
  (cl-defun agent-shell-insert (&key text submit shell-buffer) nil)
  (provide 'agent-shell))

;; Mock shell-maker and agent-shell queue functions for tests
(unless (fboundp 'shell-maker-busy)
  (defun shell-maker-busy () nil))
(unless (fboundp 'shell-maker-submit)
  (cl-defun shell-maker-submit (&key input) nil))
(unless (fboundp 'agent-shell--enqueue-request)
  (cl-defun agent-shell--enqueue-request (&key prompt) nil))

(require 'emaclaude)

;;; --- packages.el declaration tests ---

(ert-deftest emaclaude-test-packages-declares-agent-shell ()
  "packages.el should declare agent-shell as a dependency."
  (let ((packages-content (with-temp-buffer
                            (insert-file-contents
                             (expand-file-name "packages.el"
                                               (file-name-directory
                                                (or load-file-name
                                                    buffer-file-name
                                                    default-directory))))
                            (buffer-string))))
    (should (string-match-p "agent-shell" packages-content))))

(ert-deftest emaclaude-test-packages-no-vterm ()
  "packages.el should not reference vterm."
  (let ((packages-content (with-temp-buffer
                            (insert-file-contents
                             (expand-file-name "packages.el"
                                               (file-name-directory
                                                (or load-file-name
                                                    buffer-file-name
                                                    default-directory))))
                            (buffer-string))))
    (should-not (string-match-p "vterm" packages-content))))

;;; --- emaclaude-launch tests ---

(ert-deftest emaclaude-test-launch-is-interactive ()
  "emaclaude-launch should be an interactive command."
  (should (commandp #'emaclaude-launch)))

(ert-deftest emaclaude-test-launch-function-exists ()
  "emaclaude-launch should be defined as a function."
  (should (fboundp #'emaclaude-launch)))

;;; --- Backend selection state ---

(ert-deftest emaclaude-test-selected-backend-variable-exists ()
  "emaclaude--selected-agent-config should be a defined variable."
  (should (boundp 'emaclaude--selected-agent-config)))

(ert-deftest emaclaude-test-selected-backend-initially-nil ()
  "emaclaude--selected-agent-config should be nil initially."
  (should (null emaclaude--selected-agent-config)))

;;; --- Buffer name customization ---

(ert-deftest emaclaude-test-planning-buffer-name ()
  "emaclaude-buffer-planning should default to *mra-planning*."
  (should (string= emaclaude-buffer-planning "*mra-planning*")))

;;; --- Launch error handling ---

(ert-deftest emaclaude-test-launch-errors-on-no-selection ()
  "emaclaude-launch should signal user-error when no config selected."
  (cl-letf (((symbol-function 'agent-shell-select-config) (lambda (&rest _) nil)))
    (should-error (emaclaude-launch) :type 'user-error)))

;;; --- emaclaude-spawn-agent tests ---

(ert-deftest emaclaude-test-spawn-agent-errors-without-config ()
  "emaclaude-spawn-agent should error when no config is selected."
  (let ((emaclaude--selected-agent-config nil))
    (should-error (emaclaude-spawn-agent "*test-agent*") :type 'user-error)))

(ert-deftest emaclaude-test-spawn-agent-creates-buffer ()
  "emaclaude-spawn-agent should create a buffer with the given name."
  (let* ((emaclaude--selected-agent-config '((:model . "test")))
         (created-buf (generate-new-buffer "*test-spawn*")))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest _) created-buf)))
      (unwind-protect
          (let ((result (emaclaude-spawn-agent "*test-spawn*")))
            (should (buffer-live-p result)))
        (when (buffer-live-p created-buf)
          (kill-buffer created-buf))))))

(ert-deftest emaclaude-test-spawn-agent-uses-stored-config ()
  "emaclaude-spawn-agent should pass the stored config to agent-shell-start."
  (let* ((emaclaude--selected-agent-config '((:model . "claude-test")))
         (captured-config nil)
         (tmp-buf (generate-new-buffer "*test-config*")))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest args)
                 (setq captured-config (plist-get args :config))
                 tmp-buf)))
      (unwind-protect
          (progn
            (emaclaude-spawn-agent "*test-config*")
            (should (equal captured-config '((:model . "claude-test")))))
        (when (buffer-live-p tmp-buf)
          (kill-buffer tmp-buf))))))

;;; --- emaclaude-send-to-agent tests ---

(ert-deftest emaclaude-test-send-to-agent-returns-nil-for-missing-buffer ()
  "emaclaude-send-to-agent should return nil when buffer doesn't exist."
  (should (null (emaclaude-send-to-agent "*nonexistent-buffer*" "hello"))))

(ert-deftest emaclaude-test-send-to-agent-submits-when-not-busy ()
  "emaclaude-send-to-agent should call shell-maker-submit when agent is idle."
  (let ((submitted-input nil)
        (buf (generate-new-buffer "*test-idle-agent*")))
    (cl-letf (((symbol-function 'shell-maker-busy) (lambda () nil))
              ((symbol-function 'shell-maker-submit)
               (lambda (&rest args)
                 (setq submitted-input (plist-get args :input)))))
      (unwind-protect
          (progn
            (emaclaude-send-to-agent (buffer-name buf) "do something")
            (should (equal submitted-input "do something")))
        (kill-buffer buf)))))

(ert-deftest emaclaude-test-send-to-agent-enqueues-when-busy ()
  "emaclaude-send-to-agent should enqueue when agent is busy."
  (let ((enqueued-prompt nil)
        (submit-called nil)
        (buf (generate-new-buffer "*test-busy-agent*")))
    (cl-letf (((symbol-function 'shell-maker-busy) (lambda () t))
              ((symbol-function 'shell-maker-submit)
               (lambda (&rest _) (setq submit-called t)))
              ((symbol-function 'agent-shell--enqueue-request)
               (lambda (&rest args)
                 (setq enqueued-prompt (plist-get args :prompt)))))
      (unwind-protect
          (progn
            (emaclaude-send-to-agent (buffer-name buf) "queued message")
            (should (equal enqueued-prompt "queued message"))
            (should (null submit-called)))
        (kill-buffer buf)))))

(ert-deftest emaclaude-test-send-to-agent-returns-t-on-success ()
  "emaclaude-send-to-agent should return t when buffer exists."
  (let ((buf (generate-new-buffer "*test-success-agent*")))
    (cl-letf (((symbol-function 'shell-maker-busy) (lambda () nil))
              ((symbol-function 'shell-maker-submit) (lambda (&rest _) nil)))
      (unwind-protect
          (should (eq t (emaclaude-send-to-agent (buffer-name buf) "msg")))
        (kill-buffer buf)))))

;;; --- emaclaude-launch integration tests ---

(ert-deftest emaclaude-test-launch-saves-window-config ()
  "emaclaude-launch should save window configuration after config selection."
  (let ((emaclaude--saved-window-config nil)
        (emaclaude--selected-agent-config nil)
        (tmp-buf (generate-new-buffer "*test-launch-wc*")))
    (cl-letf (((symbol-function 'agent-shell-select-config)
               (lambda (&rest _) '((:model . "test"))))
              ((symbol-function 'agent-shell-start)
               (lambda (&rest _) tmp-buf))
              ((symbol-function 'emaclaude--split-layout) #'ignore))
      (unwind-protect
          (progn
            (emaclaude-launch)
            (should (not (null emaclaude--saved-window-config))))
        (setq emaclaude--saved-window-config nil)
        (setq emaclaude--selected-agent-config nil)
        (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
        (dolist (name (list emaclaude-buffer-planning
                            emaclaude-buffer-coding
                            emaclaude-buffer-review))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

(ert-deftest emaclaude-test-launch-spawns-three-buffers ()
  "emaclaude-launch should spawn planning, coding, and review buffers."
  (let ((emaclaude--selected-agent-config nil)
        (spawned-names nil))
    (cl-letf (((symbol-function 'agent-shell-select-config)
               (lambda (&rest _) '((:model . "test"))))
              ((symbol-function 'emaclaude--spawn-buffer)
               (lambda (name _config)
                 (push name spawned-names)
                 (generate-new-buffer name)))
              ((symbol-function 'emaclaude--split-layout) #'ignore))
      (unwind-protect
          (progn
            (emaclaude-launch)
            (should (member emaclaude-buffer-planning spawned-names))
            (should (member emaclaude-buffer-coding spawned-names))
            (should (member emaclaude-buffer-review spawned-names)))
        (setq emaclaude--selected-agent-config nil)
        (dolist (name (list emaclaude-buffer-planning
                            emaclaude-buffer-coding
                            emaclaude-buffer-review))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

;;; --- emaclaude--split-layout tests ---

(ert-deftest emaclaude-test-split-layout-creates-three-windows ()
  "emaclaude--split-layout should create exactly 3 windows."
  (let ((emaclaude-buffer-planning "*test-plan*")
        (emaclaude-buffer-coding "*test-code*")
        (emaclaude-buffer-review "*test-review*"))
    (unwind-protect
        (progn
          (emaclaude--split-layout)
          (should (= 3 (length (window-list)))))
      (dolist (name '("*test-plan*" "*test-code*" "*test-review*"))
        (when-let ((b (get-buffer name)))
          (kill-buffer b))))))

;;; --- emaclaude--map-event tests ---

(ert-deftest emaclaude-test-event-mapping-planning-done ()
  "emaclaude--map-event should map planning-done to PlanningDone JSON."
  (let ((result (emaclaude--map-event "planning-done" "{\"prompt\":\"build X\",\"spec_path\":\"spec.md\"}")))
    (should (assoc "PlanningDone" result))
    (let ((data (cdr (assoc "PlanningDone" result))))
      (should (equal (alist-get 'prompt data) "build X"))
      (should (equal (alist-get 'spec_path data) "spec.md")))))

(ert-deftest emaclaude-test-event-mapping-coding-done ()
  "emaclaude--map-event should map coding-done to CodingDone JSON."
  (let ((result (emaclaude--map-event "coding-done" "{\"branch\":\"feat\"}")))
    (should (assoc "CodingDone" result))
    (should (equal (alist-get 'branch (cdr (assoc "CodingDone" result))) "feat"))))

(ert-deftest emaclaude-test-event-mapping-review-done-approved ()
  "emaclaude--map-event should convert approved to Approved (PascalCase)."
  (let ((result (emaclaude--map-event "review-done" "{\"status\":\"approved\"}")))
    (should (assoc "ReviewDone" result))
    (let ((data (cdr (assoc "ReviewDone" result))))
      (should (equal (alist-get 'status data) "Approved"))
      (should (equal (alist-get 'feedback data) "")))))

(ert-deftest emaclaude-test-event-mapping-review-done-changes-needed ()
  "emaclaude--map-event should convert changes_needed to ChangesNeeded."
  (let ((result (emaclaude--map-event "review-done" "{\"status\":\"changes_needed\",\"feedback\":\"fix X\"}")))
    (let ((data (cdr (assoc "ReviewDone" result))))
      (should (equal (alist-get 'status data) "ChangesNeeded"))
      (should (equal (alist-get 'feedback data) "fix X")))))

(ert-deftest emaclaude-test-event-mapping-create-pr ()
  "emaclaude--map-event should map create-pr to CreatePr string."
  (should (equal (emaclaude--map-event "create-pr") "CreatePr")))

(ert-deftest emaclaude-test-event-mapping-clear-session ()
  "emaclaude--map-event should map clear-session to ClearSession string."
  (should (equal (emaclaude--map-event "clear-session") "ClearSession")))

;;; --- emaclaude--handle-event tests ---

(ert-deftest emaclaude-test-handle-event-exists ()
  "emaclaude--handle-event should be defined as a function."
  (should (fboundp #'emaclaude--handle-event)))

(ert-deftest emaclaude-test-handle-event-calls-rust-cli ()
  "emaclaude--handle-event should pipe correct JSON to the Rust CLI."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2)
        (captured-cmd nil))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (cmd)
                 (setq captured-cmd cmd)
                 "{\"state\":\"Coding\",\"effects\":[]}")))
      (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\",\"spec_path\":\"s.md\"}")
      (should (string-match-p "emaclaude" captured-cmd))
      (should (string-match-p "transition" captured-cmd)))))

(ert-deftest emaclaude-test-handle-event-updates-state ()
  "emaclaude--handle-event should update emaclaude--workflow-state."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "{\"state\":\"Coding\",\"effects\":[]}"))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\",\"spec_path\":\"s.md\"}")
      (should (equal emaclaude--workflow-state "\"Coding\"")))))

(ert-deftest emaclaude-test-handle-event-dispatches-effects ()
  "emaclaude--handle-event should dispatch each effect from CLI output."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2)
        (dispatched-effects nil))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_)
                 "{\"state\":\"Coding\",\"effects\":[{\"SpawnCodingAgent\":{\"prompt\":\"test\",\"spec_path\":\"s.md\"}},\"SpawnReviewAgent\"]}"))
              ((symbol-function 'emaclaude--dispatch-effect)
               (lambda (effect) (push effect dispatched-effects)))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\",\"spec_path\":\"s.md\"}")
      (should (= 2 (length dispatched-effects))))))

(ert-deftest emaclaude-test-handle-event-returns-nil-on-error ()
  "emaclaude--handle-event should return nil when CLI returns error."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "not valid json {{{"))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (should (null (emaclaude--handle-event "planning-done" "{\"prompt\":\"t\",\"spec_path\":\"s\"}"))))))

(ert-deftest emaclaude-test-handle-event-returns-nil-on-cli-error-json ()
  "emaclaude--handle-event should return nil when CLI returns JSON error."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2)
        (notified nil))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) "{\"error\":\"invalid transition\"}"))
              ((symbol-function 'emaclaude--notify)
               (lambda (msg) (setq notified msg))))
      (should (null (emaclaude--handle-event "coding-done" "{\"branch\":\"x\"}")))
      (should (string-match-p "invalid transition" notified)))))

;;; --- emaclaude--dispatch-effect tests ---

(ert-deftest emaclaude-test-dispatch-spawn-coding-agent ()
  "SpawnCodingAgent should spawn buffer and send prompt."
  (let ((spawned-name nil)
        (sent-name nil)
        (sent-msg nil))
    (cl-letf (((symbol-function 'emaclaude-spawn-agent)
               (lambda (name) (setq spawned-name name)))
              ((symbol-function 'emaclaude-send-to-agent)
               (lambda (name msg) (setq sent-name name sent-msg msg))))
      (emaclaude--dispatch-effect '((SpawnCodingAgent . ((prompt . "do stuff") (spec_path . "s.md")))))
      (should (equal spawned-name emaclaude-buffer-coding))
      (should (equal sent-name emaclaude-buffer-coding))
      (should (equal sent-msg "do stuff")))))

(ert-deftest emaclaude-test-dispatch-spawn-review-agent ()
  "SpawnReviewAgent should spawn review buffer."
  (let ((spawned-name nil))
    (cl-letf (((symbol-function 'emaclaude-spawn-agent)
               (lambda (name) (setq spawned-name name))))
      (emaclaude--dispatch-effect "SpawnReviewAgent")
      (should (equal spawned-name emaclaude-buffer-review)))))

(ert-deftest emaclaude-test-dispatch-send-to-coding-agent ()
  "SendToCodingAgent should call emaclaude-send-to-agent."
  (let ((sent-name nil)
        (sent-msg nil))
    (cl-letf (((symbol-function 'emaclaude-send-to-agent)
               (lambda (name msg) (setq sent-name name sent-msg msg))))
      (emaclaude--dispatch-effect '((SendToCodingAgent . ((prompt . "fix it")))))
      (should (equal sent-name emaclaude-buffer-coding))
      (should (equal sent-msg "fix it")))))

(ert-deftest emaclaude-test-dispatch-send-to-review-agent ()
  "SendToReviewAgent should call emaclaude-send-to-agent."
  (let ((sent-name nil)
        (sent-msg nil))
    (cl-letf (((symbol-function 'emaclaude-send-to-agent)
               (lambda (name msg) (setq sent-name name sent-msg msg))))
      (emaclaude--dispatch-effect '((SendToReviewAgent . ((prompt . "review it")))))
      (should (equal sent-name emaclaude-buffer-review))
      (should (equal sent-msg "review it")))))

(ert-deftest emaclaude-test-dispatch-notify ()
  "Notify effect should call emaclaude--notify."
  (let ((notified nil))
    (cl-letf (((symbol-function 'emaclaude--notify)
               (lambda (msg) (setq notified msg))))
      (emaclaude--dispatch-effect '((Notify . ((message . "hello")))))
      (should (equal notified "hello")))))

(ert-deftest emaclaude-test-dispatch-shutdown ()
  "Shutdown effect should reset state and call cleanup."
  (let ((emaclaude--workflow-state "\"Coding\"")
        (cleanup-called nil))
    (cl-letf (((symbol-function 'emaclaude--cleanup-buffers-and-windows)
               (lambda () (setq cleanup-called t))))
      (emaclaude--dispatch-effect "Shutdown")
      (should cleanup-called)
      (should (equal emaclaude--workflow-state "\"Idle\"")))))

;;; --- Workflow state variable tests ---

(ert-deftest emaclaude-test-workflow-state-exists ()
  "emaclaude--workflow-state should be defined."
  (should (boundp 'emaclaude--workflow-state)))

(ert-deftest emaclaude-test-confirmation-loops-exists ()
  "emaclaude-confirmation-loops should be defined."
  (should (boundp 'emaclaude-confirmation-loops)))

;;; --- Diff base tests ---

(ert-deftest emaclaude-test-diff-base-returns-main ()
  "emaclaude--diff-base should always return \"main\"."
  (should (equal (emaclaude--diff-base) "main")))

;;; --- Submit comments tests ---

(ert-deftest emaclaude-test-submit-comments-calls-handle-event ()
  "emaclaude-submit-comments should call emaclaude--handle-event with human-comments."
  (let ((captured-event nil)
        (captured-payload nil))
    (cl-letf (((symbol-function 'emaclaude--handle-event)
               (lambda (event payload)
                 (setq captured-event event
                       captured-payload payload)))
              ((symbol-function 'emaclaude--remove-comment-overlays) #'ignore)
              ((symbol-function 'emaclaude--notify) #'ignore))
      (with-temp-buffer
        (setq-local emaclaude--review-comments
                    '(((file . "src/main.rs") (line . 10) (end_line . 10) (text . "fix this"))))
        (emaclaude-submit-comments)
        (should (equal captured-event "human-comments"))
        (let* ((parsed (json-read-from-string captured-payload))
               (comments (alist-get 'comments parsed)))
          (should (= 1 (length comments)))
          (should (equal (alist-get 'file (aref comments 0)) "src/main.rs"))
          (should (equal (alist-get 'text (aref comments 0)) "fix this")))
        (should (null emaclaude--review-comments))))))

(ert-deftest emaclaude-test-submit-comments-no-comments ()
  "emaclaude-submit-comments should notify when no comments exist."
  (let ((notified nil))
    (cl-letf (((symbol-function 'emaclaude--notify)
               (lambda (msg) (setq notified msg))))
      (with-temp-buffer
        (setq-local emaclaude--review-comments nil)
        (emaclaude-submit-comments)
        (should (string-match-p "no comments" notified))))))

;;; --- Create PR tests ---

(ert-deftest emaclaude-test-create-pr-calls-handle-event ()
  "emaclaude-create-pr should call emaclaude--handle-event with create-pr."
  (let ((captured-event nil)
        (captured-payload nil))
    (cl-letf (((symbol-function 'emaclaude--handle-event)
               (lambda (event payload)
                 (setq captured-event event
                       captured-payload payload)))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (emaclaude-create-pr)
      (should (equal captured-event "create-pr"))
      (should (equal captured-payload "{}")))))

;;; --- Address GitHub reviews tests ---

(ert-deftest emaclaude-test-address-github-reviews-calls-handle-event ()
  "emaclaude-address-github-reviews should call emaclaude--handle-event with pr_number."
  (let ((captured-event nil)
        (captured-payload nil))
    (cl-letf (((symbol-function 'emaclaude--handle-event)
               (lambda (event payload)
                 (setq captured-event event
                       captured-payload payload)))
              ((symbol-function 'read-number)
               (lambda (_prompt) 42))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (emaclaude-address-github-reviews)
      (should (equal captured-event "address-github-reviews"))
      (let ((parsed (json-read-from-string captured-payload)))
        (should (equal (alist-get 'pr_number parsed) 42))))))

(ert-deftest emaclaude-test-event-mapping-address-github-reviews ()
  "emaclaude--map-event should map address-github-reviews to AddressGithubReviews."
  (let ((result (emaclaude--map-event "address-github-reviews" "{\"pr_number\":99}")))
    (should (assoc "AddressGithubReviews" result))
    (should (equal (alist-get 'pr_number (cdr (assoc "AddressGithubReviews" result))) 99))))

(provide 'emaclaude-test)
;;; emaclaude-test.el ends here
