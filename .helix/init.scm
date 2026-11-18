;; Loads the plugin from this checkout, not an installed copy, so :db-run is
;; whatever dadbod.scm says right now. Restart Helix after editing it.
(require "../dadbod.scm")

;; The key the README suggests.
(require "helix/keymaps.scm")

(keymap (global) (normal (space (x ":db-run"))))

;; The companion plugin, from this checkout too.
(require "../dadbod-ui.scm")
