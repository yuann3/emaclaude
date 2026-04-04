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

;;; --- emaclaude--handle-event tests ---

(ert-deftest emaclaude-test-handle-event-exists ()
  "emaclaude--handle-event should be defined as a function."
  (should (fboundp #'emaclaude--handle-event)))

(ert-deftest emaclaude-test-handle-event-returns-t ()
  "emaclaude--handle-event should return t."
  (should (eq t (emaclaude--handle-event "planning-done" "{\"prompt\":\"test\"}"))))

(ert-deftest emaclaude-test-handle-event-no-payload ()
  "emaclaude--handle-event should accept missing payload without error."
  (should (eq t (emaclaude--handle-event "coding-done"))))

(ert-deftest emaclaude-test-handle-event-notifies ()
  "emaclaude--handle-event should call emaclaude--notify with event name."
  (let ((notified nil))
    (cl-letf (((symbol-function 'emaclaude--notify)
               (lambda (msg) (setq notified msg))))
      (emaclaude--handle-event "review-done" "{\"status\":\"approved\"}")
      (should (string-match-p "review-done" notified)))))

(provide 'emaclaude-test)
;;; emaclaude-test.el ends here
