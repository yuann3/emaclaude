;;; tools/emaclaude/config.el -*- lexical-binding: t; -*-
(map! :map emaclaude-review-mode-map
      :localleader
      "c" #'emaclaude-add-comment
      "s" #'emaclaude-submit-comments
      "p" #'emaclaude-create-pr
      "q" #'emaclaude-close-diff)
