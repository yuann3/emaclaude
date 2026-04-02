;;; tools/emaclaude/config.el -*- lexical-binding: t; -*-

(use-package! emaclaude
  :commands (emaclaude-launch
             emaclaude-clear-session
             emaclaude-open-diff
             emaclaude-address-github-reviews)
  :config
  (map! :map emaclaude-review-mode-map
        :localleader
        :n "c" #'emaclaude-add-comment
        :v "c" #'emaclaude-add-comment
        :n "s" #'emaclaude-submit-comments
        :n "p" #'emaclaude-create-pr
        :n "q" #'emaclaude-close-diff))
