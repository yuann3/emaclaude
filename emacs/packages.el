;; -*- no-byte-compile: t; -*-
;;; tools/emaclaude/packages.el
(package! vterm)
(package! magit)
(package! emaclaude :recipe (:host github :repo "yuann3/emaclaude" :files ("emacs/*.el")))
