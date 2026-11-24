pub mod addons;
pub mod artwork;
pub mod captions;
pub mod catalogue;
pub mod client;
pub mod http_cache;
pub mod profile;
pub mod room;
pub mod source_selection;
pub mod timeline;
pub mod timings;
pub mod torbox;
pub mod tvmaze;

use thiserror::Error;

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoreError {
    #[error("{0}")]
    InvalidInput(String),
    #[error("{0}")]
    Expired(String),
    #[error("{0}")]
    TooLarge(String),
    #[error("{0}")]
    Network(String),
}

pub fn core_version() -> String {
    CORE_VERSION.to_owned()
}
