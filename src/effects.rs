use crate::config::Config;
use crate::emacs::EmacsBridge;
use crate::state::SideEffect;

pub struct EffectExecutor {
    bridge: EmacsBridge,
    config: Config,
}

impl EffectExecutor {
    pub fn new(bridge: EmacsBridge, config: Config) -> Self {
        Self { bridge, config }
    }

    pub async fn execute(&self, effects: Vec<SideEffect>) -> anyhow::Result<()> {
        for effect in effects {
            if let Err(e) = self.execute_one(effect).await {
                tracing::error!("effect execution failed: {e:#}");
            }
        }
        Ok(())
    }

    async fn execute_one(&self, effect: SideEffect) -> anyhow::Result<()> {
        match effect {
            SideEffect::SpawnCodingAgent { prompt, spec_path } => {
                let coding_buf = &self.config.buffers.coding;
                self.bridge.spawn_buffer(coding_buf, "claude").await?;
                self.bridge.split_layout().await?;
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;

                let full_prompt = format!(
                    "{}\n\nSpec path: {}\n\n\
                     When you have finished implementing all changes, run:\n\
                     curl -s -X POST http://localhost:{}/coding-done \
                     -H 'Content-Type: application/json' \
                     -d '{{\"branch\": \"CURRENT_BRANCH\"}}'",
                    prompt, spec_path, self.config.port
                );
                self.bridge.send_to_buffer(coding_buf, &full_prompt).await?;
            }
            SideEffect::SpawnReviewAgent => {
                let review_buf = &self.config.buffers.review;
                self.bridge.spawn_buffer(review_buf, "claude").await?;
            }
            SideEffect::SendToCodingAgent { prompt } => {
                let coding_buf = &self.config.buffers.coding;
                self.bridge.send_to_buffer(coding_buf, &prompt).await?;
            }
            SideEffect::SendToReviewAgent { prompt } => {
                let review_buf = &self.config.buffers.review;
                self.bridge.send_to_buffer(review_buf, &prompt).await?;
            }
            SideEffect::OpenDiffView => {
                self.bridge.open_diff_view().await?;
            }
            SideEffect::RefreshDiffView => {
                self.bridge.refresh_diff().await?;
            }
            SideEffect::Notify { message } => {
                self.bridge.notify(&message).await?;
            }
            SideEffect::Shutdown => {
                tracing::info!("Shutdown effect: exiting daemon process");
                // Exit the daemon process so the port is freed.
                // Use a short delay to let the HTTP response flush first.
                tokio::spawn(async {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    std::process::exit(0);
                });
            }
        }
        Ok(())
    }
}
