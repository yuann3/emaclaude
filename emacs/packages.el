;; -*- no-byte-compile: t; -*-
;;; tools/emaclaude/packages.el
(package! agent-shell)
(package! magit)
(package! emaclaude :recipe (:host github :repo "yuann3/emaclaude" :files ("emacs/*.el")))
