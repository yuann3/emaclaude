use std::process::Command;
use tokio::task;

#[derive(Debug, Clone)]
pub struct EmacsBridge {
    emacsclient_path: String,
}

impl EmacsBridge {
    pub fn new(emacsclient_path: String) -> Self {
        Self { emacsclient_path }
    }

    /// Returns a `Command` that will invoke `emacsclient --eval <elisp>`.
    pub fn build_eval(&self, elisp: &str) -> Command {
        let mut cmd = Command::new(&self.emacsclient_path);
        cmd.args(["--eval", elisp]);
        cmd
    }

    // ── pure elisp-generation helpers ────────────────────────────────────────

    fn escape(s: &str) -> String {
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
    }

    pub fn send_to_buffer_elisp(&self, buffer_name: &str, text: &str) -> String {
        format!(
            "(emaclaude--send-to-buffer \"{}\" \"{}\")",
            Self::escape(buffer_name),
            Self::escape(text)
        )
    }

    pub fn spawn_buffer_elisp(&self, buffer_name: &str, command: &str) -> String {
        format!(
            "(emaclaude--spawn-buffer \"{}\" \"{}\")",
            Self::escape(buffer_name),
            Self::escape(command)
        )
    }

    pub fn split_layout_elisp(&self) -> String {
        "(emaclaude--split-layout)".to_string()
    }

    pub fn open_diff_view_elisp(&self) -> String {
        "(emaclaude--open-diff-view)".to_string()
    }

    pub fn refresh_diff_elisp(&self) -> String {
        "(emaclaude--refresh-diff)".to_string()
    }

    pub fn notify_elisp(&self, message: &str) -> String {
        format!("(emaclaude--notify \"{}\")", Self::escape(message))
    }

    pub fn show_pr_link_elisp(&self, url: &str) -> String {
        format!("(emaclaude--show-pr-link \"{}\")", Self::escape(url))
    }

    pub fn shutdown_elisp(&self) -> String {
        "(emaclaude--clear-session)".to_string()
    }

    // ── async helpers ─────────────────────────────────────────────────────────

    /// Run `emacsclient --eval <elisp>` and return its stdout as a `String`.
    pub async fn eval(&self, elisp: &str) -> anyhow::Result<String> {
        let path = self.emacsclient_path.clone();
        let elisp = elisp.to_string();
        let output = task::spawn_blocking(move || {
            Command::new(&path).args(["--eval", &elisp]).output()
        })
        .await??;

        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        Ok(stdout)
    }

    pub async fn send_to_buffer(&self, buffer_name: &str, text: &str) -> anyhow::Result<String> {
        self.eval(&self.send_to_buffer_elisp(buffer_name, text)).await
    }

    pub async fn spawn_buffer(&self, buffer_name: &str, command: &str) -> anyhow::Result<String> {
        self.eval(&self.spawn_buffer_elisp(buffer_name, command)).await
    }

    pub async fn split_layout(&self) -> anyhow::Result<String> {
        self.eval(&self.split_layout_elisp()).await
    }

    pub async fn open_diff_view(&self) -> anyhow::Result<String> {
        self.eval(&self.open_diff_view_elisp()).await
    }

    pub async fn refresh_diff(&self) -> anyhow::Result<String> {
        self.eval(&self.refresh_diff_elisp()).await
    }

    pub async fn notify(&self, message: &str) -> anyhow::Result<String> {
        self.eval(&self.notify_elisp(message)).await
    }

    pub async fn shutdown(&self) -> anyhow::Result<String> {
        self.eval(&self.shutdown_elisp()).await
    }
}
