import GhosttyKit

extension Ghostty.Action {
    /// tmux's status line, for a session with `tmux-status-bar` on: what
    /// tmux would show at the bottom of its own client. Copied, since the
    /// C payload is only valid during the callback.
    struct TmuxStatus: Equatable {
        /// `status-left`, formatted by tmux, without its styles.
        let left: String

        /// The session's windows as tmux would list them.
        let windows: String

        /// `status-right`, formatted by tmux, without its styles.
        let right: String

        init(c: ghostty_action_tmux_status_s) {
            // UTF-8 in practice, but nothing promises it; String(cString:)
            // repairs anything else rather than failing.
            self.left = String(cString: c.left)
            self.windows = String(cString: c.windows)
            self.right = String(cString: c.right)
        }
    }
}
