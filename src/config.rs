use anyhow::Result;
use figment::{
    providers::{Env, Format, Serialized, Toml},
    Figment,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BufferNames {
    pub planning: String,
    pub coding: String,
    pub review: String,
    pub diff: String,
}

impl Default for BufferNames {
    fn default() -> Self {
        Self {
            planning: "*emaclaude-planning*".to_string(),
            coding: "*emaclaude-coding*".to_string(),
            review: "*emaclaude-review*".to_string(),
            diff: "*emaclaude-diff*".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub port: u16,
    pub emacsclient_path: String,
    pub confirmation_loops: u32,
    pub buffers: BufferNames,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: 3737,
            emacsclient_path: "emacsclient".to_string(),
            confirmation_loops: 3,
            buffers: BufferNames::default(),
        }
    }
}

impl Config {
    /// Load configuration from defaults, then the TOML config file, then environment variables.
    ///
    /// The config file is read from `~/.config/emaclaude/config.toml` if it exists.
    /// Environment variables are prefixed with `EMACLAUDE_`.
    pub fn load() -> Result<Self> {
        let config_path = dirs::config_dir()
            .map(|p| p.join("emaclaude").join("config.toml"));

        let mut figment = Figment::from(Serialized::defaults(Config::default()));

        if let Some(path) = config_path {
            if path.exists() {
                figment = figment.merge(Toml::file(path));
            }
        }

        figment = figment.merge(Env::prefixed("EMACLAUDE_"));

        let config: Config = figment.extract()?;
        Ok(config)
    }
}
