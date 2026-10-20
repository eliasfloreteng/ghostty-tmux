import GhosttyKit

extension Ghostty.Action {
    /// How current a tmux pane's surface is with tmux, beyond what its
    /// content shows. Sent to the pane's surface on every change.
    enum TmuxPaneStatus {
        /// Up to date.
        case live

        /// The screen is shown and its history is still being read, so
        /// scrollback is short for now. It fills in on its own.
        case loadingHistory

        /// tmux paused the pane because we fell behind it
        /// (`tmux-pause-after`) and it is being read again. The screen
        /// may be stale until it is.
        case catchingUp

        init(_ c: ghostty_action_tmux_pane_status_e) {
            switch c {
            case GHOSTTY_TMUX_PANE_LOADING_HISTORY: self = .loadingHistory
            case GHOSTTY_TMUX_PANE_CATCHING_UP: self = .catchingUp
            default: self = .live
            }
        }
    }
}
