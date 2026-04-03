;;; emaclaude-test.el --- ERT tests for emaclaude Phase 1 -*- lexical-binding: t; -*-

(require 'ert)

;; We can't require agent-shell in test environment, so mock what we need
(unless (featurep 'agent-shell)
  (defvar agent-shell-agent-configs nil)
  (defun agent-shell-select-config (&rest _) nil)
  (cl-defun agent-shell-start (&key config) nil))

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

(provide 'emaclaude-test)
;;; emaclaude-test.el ends here
