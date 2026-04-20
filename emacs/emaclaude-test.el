;;; emaclaude-test.el --- ERT tests for emaclaude -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; We can't require agent-shell in test environment, so mock what we need
;; Provide the feature first so (require 'agent-shell) in emaclaude.el succeeds
(unless (featurep 'agent-shell)
  (defvar agent-shell-agent-configs nil)
  (defvar agent-shell-preferred-agent-config nil)
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

(defvar emaclaude-test--emacs-dir
  (file-name-directory (symbol-file 'emaclaude-launch 'defun))
  "Directory containing the emaclaude elisp files.
Derived from the loaded emaclaude.el, so it works regardless of CWD.")

(ert-deftest emaclaude-test-packages-declares-agent-shell ()
  "packages.el should declare agent-shell as a dependency."
  (let ((packages-content (with-temp-buffer
                            (insert-file-contents
                             (expand-file-name "packages.el"
                                               emaclaude-test--emacs-dir))
                            (buffer-string))))
    (should (string-match-p "agent-shell" packages-content))))

(ert-deftest emaclaude-test-packages-no-vterm ()
  "packages.el should not reference vterm."
  (let ((packages-content (with-temp-buffer
                            (insert-file-contents
                             (expand-file-name "packages.el"
                                               emaclaude-test--emacs-dir))
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
  "emaclaude--agent-configs should be a defined variable."
  (should (boundp 'emaclaude--agent-configs)))

(ert-deftest emaclaude-test-selected-backend-initially-nil ()
  "emaclaude--agent-configs should be nil initially."
  (should (null emaclaude--agent-configs)))

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
  "emaclaude-spawn-agent should error when no config is in emaclaude--agent-configs."
  (let ((emaclaude--agent-configs nil))
    (should-error (emaclaude-spawn-agent emaclaude-buffer-planning) :type 'user-error)))

(ert-deftest emaclaude-test-spawn-agent-creates-buffer ()
  "emaclaude-spawn-agent should create a buffer with the given name."
  (let* ((emaclaude--agent-configs '((planning . ((:model . "test")))))
         (created-buf (generate-new-buffer "*test-spawn*")))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest _) created-buf)))
      (unwind-protect
          (let ((result (emaclaude-spawn-agent emaclaude-buffer-planning)))
            (should (buffer-live-p result)))
        (when (buffer-live-p created-buf)
          (kill-buffer created-buf))))))

(ert-deftest emaclaude-test-spawn-agent-uses-stored-config ()
  "emaclaude-spawn-agent should pass the stored config to agent-shell-start."
  (let* ((emaclaude--agent-configs '((coding . ((:model . "claude-test")))))
         (captured-config nil)
         (tmp-buf (generate-new-buffer "*test-config*")))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest args)
                 (setq captured-config (plist-get args :config))
                 tmp-buf)))
      (unwind-protect
          (progn
            (emaclaude-spawn-agent emaclaude-buffer-coding)
            (should (equal (alist-get :model captured-config) "claude-test")))
        (when (buffer-live-p tmp-buf)
          (kill-buffer tmp-buf))))))

;;; --- emaclaude-send-to-agent tests ---

(ert-deftest emaclaude-test-send-to-agent-returns-nil-for-missing-buffer ()
  "emaclaude-send-to-agent should return nil when buffer doesn't exist."
  (let ((emaclaude--agent-buffers nil))
    (should (null (emaclaude-send-to-agent "*nonexistent-buffer*" "hello")))))

(ert-deftest emaclaude-test-send-to-agent-submits-when-not-busy ()
  "emaclaude-send-to-agent should use agent-shell-queue-request."
  (let ((queued-message nil)
        (buf (generate-new-buffer "*test-idle-agent*"))
        (emaclaude--agent-buffers nil))
    (cl-letf (((symbol-function 'agent-shell-queue-request)
               (lambda (msg) (setq queued-message msg))))
      (unwind-protect
          (progn
            ;; Register buffer in agent-buffers
            (setf (alist-get "*test-idle-agent*" emaclaude--agent-buffers nil nil #'equal) buf)
            (emaclaude-send-to-agent "*test-idle-agent*" "do something")
            (should (equal queued-message "do something")))
        (kill-buffer buf)))))

(ert-deftest emaclaude-test-send-to-agent-enqueues-when-busy ()
  "emaclaude-send-to-agent should use agent-shell-queue-request even when busy."
  (let ((queued-message nil)
        (buf (generate-new-buffer "*test-busy-agent*"))
        (emaclaude--agent-buffers nil))
    (cl-letf (((symbol-function 'agent-shell-queue-request)
               (lambda (msg) (setq queued-message msg))))
      (unwind-protect
          (progn
            ;; Register buffer in agent-buffers
            (setf (alist-get "*test-busy-agent*" emaclaude--agent-buffers nil nil #'equal) buf)
            (emaclaude-send-to-agent "*test-busy-agent*" "queued message")
            (should (equal queued-message "queued message")))
        (kill-buffer buf)))))

(ert-deftest emaclaude-test-send-to-agent-returns-t-on-success ()
  "emaclaude-send-to-agent should return t when buffer exists."
  (let ((buf (generate-new-buffer "*test-success-agent*"))
        (emaclaude--agent-buffers nil))
    (cl-letf (((symbol-function 'agent-shell-queue-request) (lambda (_) nil)))
      (unwind-protect
          (progn
            ;; Register buffer in agent-buffers
            (setf (alist-get "*test-success-agent*" emaclaude--agent-buffers nil nil #'equal) buf)
            (should (eq t (emaclaude-send-to-agent "*test-success-agent*" "msg"))))
        (kill-buffer buf)))))

;;; --- emaclaude-launch integration tests ---

(ert-deftest emaclaude-test-launch-saves-window-config ()
  "emaclaude-launch should save window configuration after config resolution."
  (let ((emaclaude--saved-window-config nil)
        (emaclaude--agent-configs nil)
        (emaclaude-planning-agent 'test-agent)
        (emaclaude-coding-agent 'test-agent)
        (emaclaude-review-agent 'test-agent)
        (agent-shell-agent-configs '((test-agent . ((:model . "test")))))
        (tmp-buf (generate-new-buffer "*test-launch-wc*")))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest _) tmp-buf))
              ((symbol-function 'emaclaude--split-layout) #'ignore))
      (unwind-protect
          (progn
            (emaclaude-launch)
            (should (not (null emaclaude--saved-window-config))))
        (setq emaclaude--saved-window-config nil)
        (setq emaclaude--agent-configs nil)
        (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
        (dolist (name (list emaclaude-buffer-planning
                            emaclaude-buffer-coding
                            emaclaude-buffer-review))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

(ert-deftest emaclaude-test-launch-spawns-three-buffers ()
  "emaclaude-launch should spawn planning, coding, and review buffers."
  (let ((emaclaude--agent-configs nil)
        (emaclaude-planning-agent 'test-agent)
        (emaclaude-coding-agent 'test-agent)
        (emaclaude-review-agent 'test-agent)
        (agent-shell-agent-configs '((test-agent . ((:model . "test")))))
        (spawned-names nil))
    (cl-letf (((symbol-function 'emaclaude--spawn-buffer)
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
        (setq emaclaude--agent-configs nil)
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

(ert-deftest emaclaude-test-event-mapping-cycle-complete ()
  "emaclaude--map-event should map cycle-complete to CycleComplete string."
  (should (equal (emaclaude--map-event "cycle-complete") "CycleComplete")))

;;; --- emaclaude--handle-event tests ---

(ert-deftest emaclaude-test-handle-event-exists ()
  "emaclaude--handle-event should be defined as a function."
  (should (fboundp #'emaclaude--handle-event)))

(ert-deftest emaclaude-test-handle-event-calls-rust-cli ()
  "emaclaude--handle-event should pipe correct JSON to the Rust CLI."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2)
        (captured-program nil)
        (captured-args nil))
    (cl-letf (((symbol-function 'call-process-region)
               (lambda (_start _end program _delete buffer _display &rest args)
                 (setq captured-program program)
                 (setq captured-args args)
                 (when (eq buffer t)
                   (erase-buffer)
                   (insert "{\"state\":\"Coding\",\"effects\":[]}"))
                 0)))
      (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\",\"spec_path\":\"s.md\"}")
      (should (string-match-p "emaclaude" captured-program))
      (should (member "transition" captured-args)))))

(ert-deftest emaclaude-test-handle-event-updates-state ()
  "emaclaude--handle-event should update emaclaude--workflow-state."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2))
    (cl-letf (((symbol-function 'call-process-region)
               (lambda (_start _end _program _delete buffer _display &rest _args)
                 (when (eq buffer t)
                   (erase-buffer)
                   (insert "{\"state\":\"Coding\",\"effects\":[]}"))
                 0))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\",\"spec_path\":\"s.md\"}")
      (should (equal emaclaude--workflow-state "\"Coding\"")))))

(ert-deftest emaclaude-test-handle-event-dispatches-effects ()
  "emaclaude--handle-event should dispatch each effect from CLI output."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2)
        (dispatched-effects nil))
    (cl-letf (((symbol-function 'call-process-region)
               (lambda (_start _end _program _delete buffer _display &rest _args)
                 (when (eq buffer t)
                   (erase-buffer)
                   (insert "{\"state\":\"Coding\",\"effects\":[{\"SpawnCodingAgent\":{\"prompt\":\"test\",\"spec_path\":\"s.md\"}},\"SpawnReviewAgent\"]}"))
                 0))
              ((symbol-function 'emaclaude--dispatch-effect)
               (lambda (effect) (push effect dispatched-effects)))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\",\"spec_path\":\"s.md\"}")
      (should (= 2 (length dispatched-effects))))))

(ert-deftest emaclaude-test-handle-event-returns-nil-on-error ()
  "emaclaude--handle-event should return nil when CLI returns error."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2))
    (cl-letf (((symbol-function 'call-process-region)
               (lambda (_start _end _program _delete buffer _display &rest _args)
                 (when (eq buffer t)
                   (erase-buffer)
                   (insert "not valid json {{{"))
                 0))
              ((symbol-function 'emaclaude--notify) #'ignore))
      (should (null (emaclaude--handle-event "planning-done" "{\"prompt\":\"t\",\"spec_path\":\"s\"}"))))))

(ert-deftest emaclaude-test-handle-event-returns-nil-on-cli-error-json ()
  "emaclaude--handle-event should return nil when CLI returns JSON error."
  (let ((emaclaude--workflow-state "\"Idle\"")
        (emaclaude-confirmation-loops 2)
        (notified-msgs nil))
    (cl-letf (((symbol-function 'call-process-region)
               (lambda (_start _end _program delete buffer _display &rest _args)
                 ;; When delete is t and buffer is t, we're in the temp buffer context
                 ;; The function replaces buffer contents with output
                 (when (eq buffer t)
                   (erase-buffer)
                   (insert "{\"error\":\"invalid transition\"}"))
                 0))
              ((symbol-function 'emaclaude--notify)
               (lambda (msg) (push msg notified-msgs))))
      (should (null (emaclaude--handle-event "coding-done" "{\"branch\":\"x\"}")))
      (should (cl-some (lambda (msg) (string-match-p "invalid transition" msg)) notified-msgs)))))

;;; --- emaclaude--dispatch-effect tests ---

(ert-deftest emaclaude-test-dispatch-spawn-coding-agent ()
  "SpawnCodingAgent should spawn buffer and send prompt with spec path."
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
      (should (equal sent-msg "do stuff\n\nSpec file: s.md")))))

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

(ert-deftest emaclaude-test-reset-coding-and-review-kills-buffers ()
  "emaclaude--reset-coding-and-review should kill coding and review buffers."
  (let* ((coding-buf (generate-new-buffer "*test-coding*"))
         (review-buf (generate-new-buffer "*test-review*"))
         (plan-buf (generate-new-buffer "*test-planning*"))
         (emaclaude-buffer-coding "*test-coding*")
         (emaclaude-buffer-review "*test-review*")
         (emaclaude-buffer-planning "*test-planning*")
         (emaclaude-buffer-diff "*test-diff*")
         (emaclaude--agent-buffers
          `(("*test-coding*" . ,coding-buf)
            ("*test-review*" . ,review-buf)
            ("*test-planning*" . ,plan-buf)))
         (emaclaude--agent-configs
          '((coding . ((:model . "test")))
            (review . ((:model . "test")))
            (planning . ((:model . "test"))))))
    (cl-letf (((symbol-function 'emaclaude--spawn-buffer)
               (lambda (name _config) (generate-new-buffer name)))
              ((symbol-function 'emaclaude--split-layout) #'ignore)
              ((symbol-function 'get-buffer-window) (lambda (_) nil)))
      (unwind-protect
          (progn
            (emaclaude--reset-coding-and-review)
            (should-not (buffer-live-p coding-buf))
            (should-not (buffer-live-p review-buf))
            (should (buffer-live-p plan-buf)))
        (dolist (name '("*test-coding*" "*test-review*" "*test-planning*"))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

(ert-deftest emaclaude-test-reset-coding-and-review-respawns ()
  "emaclaude--reset-coding-and-review should respawn coding and review buffers."
  (let* ((coding-buf (generate-new-buffer "*test-coding*"))
         (review-buf (generate-new-buffer "*test-review*"))
         (plan-buf (generate-new-buffer "*test-planning*"))
         (emaclaude-buffer-coding "*test-coding*")
         (emaclaude-buffer-review "*test-review*")
         (emaclaude-buffer-planning "*test-planning*")
         (emaclaude-buffer-diff "*test-diff*")
         (emaclaude--agent-buffers
          `(("*test-coding*" . ,coding-buf)
            ("*test-review*" . ,review-buf)
            ("*test-planning*" . ,plan-buf)))
         (emaclaude--agent-configs
          '((coding . ((:model . "test")))
            (review . ((:model . "test")))
            (planning . ((:model . "test")))))
         (spawned-names nil))
    (cl-letf (((symbol-function 'emaclaude--spawn-buffer)
               (lambda (name _config)
                 (push name spawned-names)
                 (generate-new-buffer name)))
              ((symbol-function 'emaclaude--split-layout) #'ignore)
              ((symbol-function 'get-buffer-window) (lambda (_) nil)))
      (unwind-protect
          (progn
            (emaclaude--reset-coding-and-review)
            (should (member "*test-coding*" spawned-names))
            (should (member "*test-review*" spawned-names))
            (should-not (member "*test-planning*" spawned-names)))
        (dolist (name '("*test-coding*" "*test-review*" "*test-planning*"))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

(ert-deftest emaclaude-test-dispatch-reset-coding-and-review ()
  "ResetCodingAndReview effect should call emaclaude--reset-coding-and-review."
  (let ((called nil))
    (cl-letf (((symbol-function 'emaclaude--reset-coding-and-review)
               (lambda () (setq called t))))
      (emaclaude--dispatch-effect "ResetCodingAndReview")
      (should called))))

(ert-deftest emaclaude-test-dispatch-insert-into-planning-buffer ()
  "InsertIntoPlanningBuffer should call agent-shell-insert with :submit nil."
  (let* ((plan-buf (generate-new-buffer "*test-plan-insert*"))
         (emaclaude-buffer-planning "*test-plan-insert*")
         (emaclaude--agent-buffers
          `(("*test-plan-insert*" . ,plan-buf)))
         (captured-text nil)
         (captured-submit nil)
         (captured-buf nil))
    (cl-letf (((symbol-function 'agent-shell-insert)
               (lambda (&rest args)
                 (setq captured-text (plist-get args :text))
                 (setq captured-submit (plist-get args :submit))
                 (setq captured-buf (plist-get args :shell-buffer)))))
      (unwind-protect
          (progn
            (emaclaude--dispatch-effect
             '((InsertIntoPlanningBuffer . ((message . "Implementation is done.")))))
            (should (equal captured-text "Implementation is done."))
            (should (null captured-submit))
            (should (equal captured-buf plan-buf)))
        (when (buffer-live-p plan-buf) (kill-buffer plan-buf))))))

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

;;; --- Logging tests ---

(ert-deftest emaclaude-test-log-event-writes-jsonl ()
  "emaclaude--log-event should write valid JSON to the correct file path."
  (let* ((tmp-dir (make-temp-file "emaclaude-log-test" t))
         (log-dir (expand-file-name "logs" tmp-dir))
         (expected-file (expand-file-name
                         (format "%s.jsonl" (format-time-string "%Y-%m-%d"))
                         log-dir)))
    (cl-letf (((symbol-function 'expand-file-name)
               (let ((orig (symbol-function 'expand-file-name)))
                 (lambda (name &optional dir)
                   (if (and (stringp dir) (string= dir "~/.emaclaude"))
                       (funcall orig name tmp-dir)
                     (funcall orig name dir))))))
      (unwind-protect
          (progn
            (emaclaude--log-event "test-event" "StateA" "StateB" "test payload")
            (should (file-exists-p expected-file))
            (let* ((content (with-temp-buffer
                              (insert-file-contents expected-file)
                              (buffer-string)))
                   (parsed (json-read-from-string (string-trim content))))
              (should (equal (alist-get 'event parsed) "test-event"))
              (should (equal (alist-get 'from parsed) "StateA"))
              (should (equal (alist-get 'to parsed) "StateB"))
              (should (equal (alist-get 'payload parsed) "test payload"))
              (should (alist-get 'timestamp parsed))))
        (delete-directory tmp-dir t)))))

(ert-deftest emaclaude-test-log-event-omits-nil-fields ()
  "emaclaude--log-event should omit from/to/payload when nil."
  (let* ((tmp-dir (make-temp-file "emaclaude-log-test" t))
         (log-dir (expand-file-name "logs" tmp-dir))
         (expected-file (expand-file-name
                         (format "%s.jsonl" (format-time-string "%Y-%m-%d"))
                         log-dir)))
    (cl-letf (((symbol-function 'expand-file-name)
               (let ((orig (symbol-function 'expand-file-name)))
                 (lambda (name &optional dir)
                   (if (and (stringp dir) (string= dir "~/.emaclaude"))
                       (funcall orig name tmp-dir)
                     (funcall orig name dir))))))
      (unwind-protect
          (progn
            (emaclaude--log-event "minimal-event")
            (let* ((content (with-temp-buffer
                              (insert-file-contents expected-file)
                              (buffer-string)))
                   (parsed (json-read-from-string (string-trim content))))
              (should (equal (alist-get 'event parsed) "minimal-event"))
              (should-not (assoc 'from parsed))
              (should-not (assoc 'to parsed))
              (should-not (assoc 'payload parsed))))
        (delete-directory tmp-dir t)))))

;;; --- Watchdog tests ---

(ert-deftest emaclaude-test-reset-watchdog-creates-timer ()
  "emaclaude--reset-watchdog should create a timer."
  (let ((emaclaude--watchdog-timer nil)
        (emaclaude-watchdog-timeout 9999))
    (unwind-protect
        (progn
          (emaclaude--reset-watchdog)
          (should (timerp emaclaude--watchdog-timer)))
      (emaclaude--cancel-watchdog))))

(ert-deftest emaclaude-test-cancel-watchdog-clears-timer ()
  "emaclaude--cancel-watchdog should cancel and nil the timer."
  (let ((emaclaude--watchdog-timer nil)
        (emaclaude-watchdog-timeout 9999))
    (emaclaude--reset-watchdog)
    (should (timerp emaclaude--watchdog-timer))
    (emaclaude--cancel-watchdog)
    (should (null emaclaude--watchdog-timer))))

(ert-deftest emaclaude-test-cancel-watchdog-noop-when-nil ()
  "emaclaude--cancel-watchdog should not error when timer is nil."
  (let ((emaclaude--watchdog-timer nil))
    (should-not (emaclaude--cancel-watchdog))))

;;; --- Clear session tests ---

(ert-deftest emaclaude-test-clear-session-cancels-watchdog ()
  "emaclaude-clear-session should cancel the watchdog timer."
  (let ((emaclaude--watchdog-timer nil)
        (emaclaude-watchdog-timeout 9999)
        (emaclaude--workflow-state "\"Idle\"")
        (emaclaude--agent-configs nil)
        (emaclaude--saved-window-config nil))
    (emaclaude--reset-watchdog)
    (should (timerp emaclaude--watchdog-timer))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'emaclaude--handle-event) #'ignore)
              ((symbol-function 'emaclaude--notify) #'ignore)
              ((symbol-function 'server-running-p) (lambda (&rest _) nil)))
      (emaclaude-clear-session))
    (should (null emaclaude--watchdog-timer))))

(ert-deftest emaclaude-test-clear-session-resets-state ()
  "emaclaude-clear-session should reset workflow state to Idle."
  (let ((emaclaude--workflow-state "\"Coding\"")
        (emaclaude--watchdog-timer nil)
        (emaclaude--agent-configs '((planning . ((:model . "test")))))
        (emaclaude--saved-window-config nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'emaclaude--handle-event) #'ignore)
              ((symbol-function 'emaclaude--notify) #'ignore)
              ((symbol-function 'server-running-p) (lambda (&rest _) nil)))
      (emaclaude-clear-session))
    (should (equal emaclaude--workflow-state "\"Idle\""))
    (should (null emaclaude--agent-configs))))

(ert-deftest emaclaude-test-clear-session-is-interactive ()
  "emaclaude-clear-session should be an interactive command."
  (should (commandp #'emaclaude-clear-session)))

(ert-deftest emaclaude-test-clear-session-no-daemon-references ()
  "emaclaude-clear-session source should not reference daemon or HTTP."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "emaclaude.el"
                                     emaclaude-test--emacs-dir))
                  ;; Extract the clear-session defun
                  (goto-char (point-min))
                  (when (re-search-forward "(defun emaclaude-clear-session" nil t)
                    (beginning-of-line)
                    (let ((start (point)))
                      (forward-sexp)
                      (buffer-substring-no-properties start (point)))))))
    (should source)
    (should-not (string-match-p "emaclaude--post" source))
    (should-not (string-match-p "emaclaude--daemon-process" source))
    (should-not (string-match-p "emaclaude--kill-stale" source))))

;;; --- Watchdog timeout variable ---

(ert-deftest emaclaude-test-watchdog-timeout-default ()
  "emaclaude-watchdog-timeout should default to 600."
  (should (= emaclaude-watchdog-timeout 600)))

;;; --- Per-agent backend configuration tests ---

(ert-deftest emaclaude-test-planning-agent-defcustom-exists ()
  "emaclaude-planning-agent should be a defined customizable variable."
  (should (boundp 'emaclaude-planning-agent))
  (should (custom-variable-p 'emaclaude-planning-agent)))

(ert-deftest emaclaude-test-planning-agent-default-nil ()
  "emaclaude-planning-agent should default to nil (inherit)."
  (should (null (default-value 'emaclaude-planning-agent))))

(ert-deftest emaclaude-test-coding-agent-defcustom-exists ()
  "emaclaude-coding-agent should be a defined customizable variable."
  (should (boundp 'emaclaude-coding-agent))
  (should (custom-variable-p 'emaclaude-coding-agent)))

(ert-deftest emaclaude-test-coding-agent-default-nil ()
  "emaclaude-coding-agent should default to nil (inherit)."
  (should (null (default-value 'emaclaude-coding-agent))))

(ert-deftest emaclaude-test-review-agent-defcustom-exists ()
  "emaclaude-review-agent should be a defined customizable variable."
  (should (boundp 'emaclaude-review-agent))
  (should (custom-variable-p 'emaclaude-review-agent)))

(ert-deftest emaclaude-test-review-agent-default-nil ()
  "emaclaude-review-agent should default to nil (inherit)."
  (should (null (default-value 'emaclaude-review-agent))))

(ert-deftest emaclaude-test-agent-configs-variable-exists ()
  "emaclaude--agent-configs should be a defined variable."
  (should (boundp 'emaclaude--agent-configs)))

(ert-deftest emaclaude-test-agent-configs-initially-nil ()
  "emaclaude--agent-configs should be nil initially."
  (should (null emaclaude--agent-configs)))

;;; --- emaclaude--resolve-agent-symbol tests ---

(ert-deftest emaclaude-test-resolve-agent-symbol-exists ()
  "emaclaude--resolve-agent-symbol should be defined."
  (should (fboundp #'emaclaude--resolve-agent-symbol)))

(ert-deftest emaclaude-test-resolve-agent-symbol-finds-config ()
  "emaclaude--resolve-agent-symbol should return matching config from agent-shell-agent-configs."
  (let ((agent-shell-agent-configs
         '((claude-code . ((:model . "claude") (:buffer-name . "Claude")))
           (codex . ((:model . "codex") (:buffer-name . "Codex"))))))
    (let ((result (emaclaude--resolve-agent-symbol 'claude-code)))
      (should (equal (alist-get :model result) "claude"))
      (should (equal (alist-get :buffer-name result) "Claude")))))

(ert-deftest emaclaude-test-resolve-agent-symbol-errors-on-not-found ()
  "emaclaude--resolve-agent-symbol should signal error when symbol not found."
  (let ((agent-shell-agent-configs
         '((claude-code . ((:model . "claude"))))))
    (should-error (emaclaude--resolve-agent-symbol 'nonexistent) :type 'user-error)))

;;; --- emaclaude--resolve-agent-config tests ---

(ert-deftest emaclaude-test-resolve-agent-config-exists ()
  "emaclaude--resolve-agent-config should be defined."
  (should (fboundp #'emaclaude--resolve-agent-config)))

(ert-deftest emaclaude-test-resolve-agent-config-uses-defcustom ()
  "emaclaude--resolve-agent-config should use the role-specific defcustom."
  (let ((emaclaude-planning-agent 'claude-code)
        (agent-shell-agent-configs
         '((claude-code . ((:model . "claude") (:buffer-name . "Claude"))))))
    (let ((result (emaclaude--resolve-agent-config 'planning)))
      (should (equal (alist-get :model result) "claude")))))

(ert-deftest emaclaude-test-resolve-agent-config-inherits-when-nil ()
  "emaclaude--resolve-agent-config should inherit from agent-shell-preferred-agent-config when defcustom is nil."
  (let ((emaclaude-coding-agent nil)
        (agent-shell-preferred-agent-config 'codex)
        (agent-shell-agent-configs
         '((codex . ((:model . "codex") (:buffer-name . "Codex"))))))
    (let ((result (emaclaude--resolve-agent-config 'coding)))
      (should (equal (alist-get :model result) "codex")))))

(ert-deftest emaclaude-test-resolve-agent-config-errors-when-both-nil ()
  "emaclaude--resolve-agent-config should error when defcustom and preferred are both nil."
  (let ((emaclaude-review-agent nil)
        (agent-shell-preferred-agent-config nil))
    (should-error (emaclaude--resolve-agent-config 'review) :type 'user-error)))

(ert-deftest emaclaude-test-resolve-agent-config-all-roles ()
  "emaclaude--resolve-agent-config should work for planning, coding, and review roles."
  (let ((emaclaude-planning-agent 'agent-a)
        (emaclaude-coding-agent 'agent-b)
        (emaclaude-review-agent 'agent-c)
        (agent-shell-agent-configs
         '((agent-a . ((:id . "a")))
           (agent-b . ((:id . "b")))
           (agent-c . ((:id . "c"))))))
    (should (equal (alist-get :id (emaclaude--resolve-agent-config 'planning)) "a"))
    (should (equal (alist-get :id (emaclaude--resolve-agent-config 'coding)) "b"))
    (should (equal (alist-get :id (emaclaude--resolve-agent-config 'review)) "c"))))

;;; --- emaclaude-launch with per-agent config tests ---

(ert-deftest emaclaude-test-launch-populates-agent-configs ()
  "emaclaude-launch without prefix should populate emaclaude--agent-configs from defcustoms."
  (let ((emaclaude--agent-configs nil)
        (emaclaude-planning-agent 'claude-code)
        (emaclaude-coding-agent 'claude-code)
        (emaclaude-review-agent 'codex)
        (agent-shell-agent-configs
         '((claude-code . ((:model . "claude")))
           (codex . ((:model . "codex")))))
        (tmp-buf (generate-new-buffer "*test-launch-configs*")))
    (cl-letf (((symbol-function 'agent-shell-start)
               (lambda (&rest _) tmp-buf))
              ((symbol-function 'emaclaude--split-layout) #'ignore))
      (unwind-protect
          (progn
            (emaclaude-launch)
            (should (alist-get 'planning emaclaude--agent-configs))
            (should (alist-get 'coding emaclaude--agent-configs))
            (should (alist-get 'review emaclaude--agent-configs))
            (should (equal (alist-get :model (alist-get 'planning emaclaude--agent-configs)) "claude"))
            (should (equal (alist-get :model (alist-get 'review emaclaude--agent-configs)) "codex")))
        (setq emaclaude--agent-configs nil)
        (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
        (dolist (name (list emaclaude-buffer-planning
                            emaclaude-buffer-coding
                            emaclaude-buffer-review))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

(ert-deftest emaclaude-test-launch-with-prefix-prompts-three-times ()
  "emaclaude-launch with prefix arg should call agent-shell-select-config three times."
  (let ((emaclaude--agent-configs nil)
        (select-count 0)
        (tmp-buf (generate-new-buffer "*test-launch-prefix*")))
    (cl-letf (((symbol-function 'agent-shell-select-config)
               (lambda (&rest _)
                 (cl-incf select-count)
                 '((:model . "test"))))
              ((symbol-function 'agent-shell-start)
               (lambda (&rest _) tmp-buf))
              ((symbol-function 'emaclaude--split-layout) #'ignore))
      (unwind-protect
          (progn
            (let ((current-prefix-arg '(4)))
              (emaclaude-launch))
            (should (= select-count 3)))
        (setq emaclaude--agent-configs nil)
        (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
        (dolist (name (list emaclaude-buffer-planning
                            emaclaude-buffer-coding
                            emaclaude-buffer-review))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

(ert-deftest emaclaude-test-launch-without-prefix-does-not-prompt ()
  "emaclaude-launch without prefix arg should not call agent-shell-select-config."
  (let ((emaclaude--agent-configs nil)
        (select-called nil)
        (emaclaude-planning-agent 'test-agent)
        (emaclaude-coding-agent 'test-agent)
        (emaclaude-review-agent 'test-agent)
        (agent-shell-agent-configs
         '((test-agent . ((:model . "test")))))
        (tmp-buf (generate-new-buffer "*test-launch-no-prompt*")))
    (cl-letf (((symbol-function 'agent-shell-select-config)
               (lambda (&rest _)
                 (setq select-called t)
                 '((:model . "test"))))
              ((symbol-function 'agent-shell-start)
               (lambda (&rest _) tmp-buf))
              ((symbol-function 'emaclaude--split-layout) #'ignore))
      (unwind-protect
          (progn
            (emaclaude-launch)
            (should-not select-called))
        (setq emaclaude--agent-configs nil)
        (when (buffer-live-p tmp-buf) (kill-buffer tmp-buf))
        (dolist (name (list emaclaude-buffer-planning
                            emaclaude-buffer-coding
                            emaclaude-buffer-review))
          (when-let ((b (get-buffer name))) (kill-buffer b)))))))

;;; --- Clear session confirmation tests ---

(ert-deftest emaclaude-test-clear-session-confirms-before-clearing ()
  "emaclaude-clear-session should ask for confirmation and proceed when yes."
  (let ((emaclaude--workflow-state "\"Coding\"")
        (emaclaude--watchdog-timer nil)
        (emaclaude--agent-configs '((planning . ((:model . "test")))))
        (emaclaude--saved-window-config nil)
        (handle-event-called nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'emaclaude--handle-event)
               (lambda (&rest _) (setq handle-event-called t)))
              ((symbol-function 'emaclaude--notify) #'ignore)
              ((symbol-function 'server-running-p) (lambda (&rest _) nil)))
      (emaclaude-clear-session)
      (should handle-event-called))))

(ert-deftest emaclaude-test-clear-session-aborts-on-no ()
  "emaclaude-clear-session should abort when user says no."
  (let ((emaclaude--workflow-state "\"Coding\"")
        (emaclaude--watchdog-timer nil)
        (emaclaude--agent-configs '((planning . ((:model . "test")))))
        (emaclaude--saved-window-config nil)
        (handle-event-called nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil))
              ((symbol-function 'emaclaude--handle-event)
               (lambda (&rest _) (setq handle-event-called t)))
              ((symbol-function 'emaclaude--notify) #'ignore)
              ((symbol-function 'server-running-p) (lambda (&rest _) nil)))
      (emaclaude-clear-session)
      (should-not handle-event-called)
      ;; State should be unchanged
      (should (equal emaclaude--workflow-state "\"Coding\"")))))

;;; --- emaclaude-next-cycle tests ---

(ert-deftest emaclaude-test-next-cycle-is-interactive ()
  "emaclaude-next-cycle should be an interactive command."
  (should (commandp #'emaclaude-next-cycle)))

(ert-deftest emaclaude-test-next-cycle-calls-handle-event ()
  "emaclaude-next-cycle should call emaclaude--handle-event with cycle-complete."
  (let ((captured-event nil))
    (cl-letf (((symbol-function 'emaclaude--handle-event)
               (lambda (event &optional payload)
                 (setq captured-event event))))
      (emaclaude-next-cycle)
      (should (equal captured-event "cycle-complete")))))

(provide 'emaclaude-test)
;;; emaclaude-test.el ends here
