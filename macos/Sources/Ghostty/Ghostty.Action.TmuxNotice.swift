import GhosttyKit

extension Ghostty.Action {
    /// Something a tmux control mode session has to tell the user, which a
    /// normal tmux client would have shown on its status line. The text is
    /// copied, since the C payload is only valid during the callback.
    struct TmuxNotice {
        enum Kind {
            /// `display-message` aimed at this client. Informational.
            case message

            /// An error loading tmux.conf. Several tend to arrive together,
            /// one per error, when the session is attached.
            case configError

            /// Something the user asked tmux to do failed; the text is
            /// tmux's error.
            case commandError

            /// The session ended and this is why. Sent just before the
            /// session's windows go.
            case exit

            /// What a command line the user typed printed. May be several
            /// lines; its errors come as `commandError`.
            case commandOutput

            init?(_ c: ghostty_tmux_notice_kind_e) {
                switch c {
                case GHOSTTY_TMUX_NOTICE_MESSAGE: self = .message
                case GHOSTTY_TMUX_NOTICE_CONFIG_ERROR: self = .configError
                case GHOSTTY_TMUX_NOTICE_COMMAND_ERROR: self = .commandError
                case GHOSTTY_TMUX_NOTICE_EXIT: self = .exit
                case GHOSTTY_TMUX_NOTICE_COMMAND_OUTPUT: self = .commandOutput
                default: return nil
                }
            }
        }

        let kind: Kind
        let text: String

        init?(c: ghostty_action_tmux_notice_s) {
            guard let kind = Kind(c.kind), let text = c.text else { return nil }
            self.kind = kind

            // tmux's text is UTF-8 in practice, but nothing promises it.
            // String(cString:) repairs anything else rather than failing.
            self.text = String(cString: text)
        }
    }
}
