use crate::http_cache::HttpCache;
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::{path::PathBuf, sync::Arc, time::Duration};

pub struct InterludeClient {
    pub http: reqwest::Client,
    pub cache: Arc<HttpCache>,
}

impl InterludeClient {
    pub fn new(cache_dir: PathBuf) -> Result<Self, String> {
        let http = reqwest::Client::builder()
            .pool_idle_timeout(Duration::from_secs(90))
            .timeout(Duration::from_secs(14))
            .connect_timeout(Duration::from_secs(6))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("Interlude/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| "Couldn't initialize HTTP client.".to_owned())?;
        let cache = HttpCache::new(cache_dir);
        Ok(Self { http, cache })
    }

    pub fn prune_cache(&self) {
        self.cache.prune();
    }

    pub async fn cached_json(
        &self,
        request: reqwest::RequestBuilder,
        label: &str,
        route: &str,
        query: &[(&str, &str)],
        ttl: Option<Duration>,
    ) -> Result<Value, String> {
        let label = label.to_owned();
        let key = HttpCache::key(&label, route, query);
        self.cache
            .fetch(key, ttl, move || async move { json_response(request, &label).await })
            .await
    }
}

pub async fn json_response<T: DeserializeOwned>(
    request: reqwest::RequestBuilder,
    label: &str,
) -> Result<T, String> {
    let response = request
        .send()
        .await
        .map_err(|_| format!("Couldn't reach {label}. Check your connection and try again."))?;
    decode_response(response, label).await
}

pub async fn decode_response<T: DeserializeOwned>(
    response: reqwest::Response,
    label: &str,
) -> Result<T, String> {
    match response.status().as_u16() {
        200..=299 => response
            .json()
            .await
            .map_err(|_| format!("{label} returned an unreadable response.")),
        401 | 403 => Err(format!(
            "{label} denied access. Check your credential and account access."
        )),
        429 => Err(format!(
            "{label} is rate-limiting requests. Try again shortly."
        )),
        code => Err(format!("{label} returned HTTP {code}.")),
    }
}
