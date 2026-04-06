;; -*- no-byte-compile: t; -*-
;;; tools/emaclaude/packages.el
(package! agent-shell)
(package! magit)
(package! emaclaude
  :recipe (:local-repo "~/Developer/emaclaude"
           :files ("emacs/*.el")))
