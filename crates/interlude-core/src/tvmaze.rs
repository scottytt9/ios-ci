use crate::client::InterludeClient;
use serde_json::Value;
use std::time::Duration;

impl InterludeClient {
    async fn tvmaze_get(
        &self,
        route: &str,
        query: &[(&str, &str)],
        ttl: Option<Duration>,
    ) -> Result<Value, String> {
        let request = self
            .http
            .get(format!("https://api.tvmaze.com/{route}"))
            .query(query);
        self.cached_json(request, "TVmaze", route, query, ttl).await
    }

    pub async fn tvmaze_picks(&self) -> Result<Vec<Value>, String> {
        let index = self
            .tvmaze_get("shows", &[("page", "0")], Some(Duration::from_secs(86400)))
            .await?;
        let shows = index
            .as_array()
            .ok_or("TVmaze returned an unreadable show list.")?;
        Ok([169, 82, 5, 32, 49, 157, 29, 143, 2, 7, 43, 172]
            .into_iter()
            .filter_map(|id| {
                shows
                    .iter()
                    .find(|show| show["id"].as_u64() == Some(id))
                    .cloned()
            })
            .collect())
    }

    pub async fn tvmaze_search(&self, query: &str) -> Result<Value, String> {
        let query: String = query.trim().chars().take(140).collect();
        self.tvmaze_get("search/shows", &[("q", &query)], None)
            .await
    }

    pub async fn tvmaze_details(&self, id: u32) -> Result<Value, String> {
        self.tvmaze_get(
            &format!("shows/{id}"),
            &[("embed[]", "seasons"), ("embed[]", "cast")],
            Some(Duration::from_secs(21600)),
        )
        .await
    }

    pub async fn tvmaze_episodes(&self, id: u32) -> Result<Value, String> {
        self.tvmaze_get(
            &format!("seasons/{id}/episodes"),
            &[],
            Some(Duration::from_secs(21600)),
        )
        .await
    }

    pub async fn tvmaze_person_credits(&self, id: u32) -> Result<Value, String> {
        if id == 0 {
            return Err("Unknown cast member.".into());
        }
        self.tvmaze_get(
            &format!("people/{id}/castcredits"),
            &[("embed", "show")],
            Some(Duration::from_secs(86400)),
        )
        .await
    }
}
