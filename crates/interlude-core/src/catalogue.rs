use crate::client::{json_response, InterludeClient};
use serde::Deserialize;
use serde_json::Value;
use std::time::Duration;

const LABEL: &str = "TMDB";

#[derive(Debug, Clone, Deserialize)]
pub struct DiscoveryFilters {
    pub kind: String,
    pub order: String,
    pub genre: Option<String>,
    pub decade: Option<u16>,
    pub language: Option<String>,
    pub today: String,
}

fn request(client: &reqwest::Client, secret: &str, route: &str) -> reqwest::RequestBuilder {
    let request = client.get(format!("https://api.themoviedb.org/3/{route}"));
    if secret.len() == 32 && secret.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        request.query(&[("api_key", secret)])
    } else {
        request.bearer_auth(secret)
    }
}

fn media_route(kind: &str, id: u32) -> Result<String, String> {
    match kind {
        "movie" | "tv" if id > 0 => Ok(format!("{kind}/{id}")),
        _ => Err("Unknown title.".into()),
    }
}

fn validate_tmdb_route(route: &str) -> Result<&str, String> {
    let trimmed = route.trim();
    if trimmed.is_empty()
        || trimmed.len() > 160
        || trimmed.starts_with('/')
        || trimmed.contains("..")
        || !trimmed
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'-'))
    {
        return Err("Invalid TMDB route.".into());
    }
    Ok(trimmed)
}

impl InterludeClient {
    pub async fn tmdb_verify(&self, secret: &str) -> Result<(), String> {
        json_response::<Value>(request(&self.http, secret, "authentication"), LABEL)
            .await
            .map(|_| ())
    }

    async fn tmdb_get(
        &self,
        secret: &str,
        route: &str,
        query: &[(&str, &str)],
        ttl: Option<Duration>,
    ) -> Result<Value, String> {
        self.cached_json(
            request(&self.http, secret, route).query(query),
            LABEL,
            route,
            query,
            ttl,
        )
        .await
    }

    pub async fn tmdb_feed(&self, secret: &str, name: &str, page: u16) -> Result<Value, String> {
        let route = match name {
            "trending" => "trending/all/week",
            "movies" => "movie/popular",
            "series" => "tv/popular",
            "top" => "movie/top_rated",
            "airing" => "tv/on_the_air",
            _ => return Err("Unknown shelf.".into()),
        };
        let page = page.clamp(1, 500).to_string();
        self.tmdb_get(
            secret,
            route,
            &[("language", "en-GB"), ("page", &page)],
            Some(Duration::from_secs(1800)),
        )
        .await
    }

    pub async fn tmdb_search(
        &self,
        secret: &str,
        query: &str,
        page: u16,
        kind: Option<&str>,
    ) -> Result<Value, String> {
        let route = match kind {
            Some("movie") => "search/movie",
            Some("tv") => "search/tv",
            None => "search/multi",
            _ => return Err("Unknown media type.".into()),
        };
        let query: String = query.trim().chars().take(140).collect();
        let page = page.clamp(1, 500).to_string();
        self.tmdb_get(
            secret,
            route,
            &[
                ("query", &query),
                ("include_adult", "false"),
                ("language", "en-GB"),
                ("page", &page),
            ],
            None,
        )
        .await
    }

    pub async fn tmdb_discover(
        &self,
        secret: &str,
        filters: &DiscoveryFilters,
        page: u16,
    ) -> Result<Value, String> {
        let (route, since, until, release_order) = match filters.kind.as_str() {
            "movie" => (
                "discover/movie",
                "primary_release_date.gte",
                "primary_release_date.lte",
                "primary_release_date.desc",
            ),
            "tv" => (
                "discover/tv",
                "first_air_date.gte",
                "first_air_date.lte",
                "first_air_date.desc",
            ),
            _ => return Err("Unknown media type.".into()),
        };
        let sort = match filters.order.as_str() {
            "popular" => "popularity.desc",
            "recent" => release_order,
            "rated" => "vote_average.desc",
            _ => return Err("Unknown catalogue sort order.".into()),
        };
        let today = filters.today.as_str();
        if today.len() != 10
            || !today.bytes().enumerate().all(|(i, b)| {
                if i == 4 || i == 7 {
                    b == b'-'
                } else {
                    b.is_ascii_digit()
                }
            })
        {
            return Err("Invalid catalogue date.".into());
        }
        let page = page.clamp(1, 500).to_string();
        let mut params = vec![
            ("include_adult", "false"),
            ("language", "en-GB"),
            ("page", page.as_str()),
            ("sort_by", sort),
        ];
        if let Some(genre) = filters.genre.as_deref() {
            if genre.len() > 24
                || !genre.split('|').all(|id| {
                    id.parse::<u32>()
                        .is_ok_and(|value| value > 0 && value < 100_000)
                })
            {
                return Err("Invalid catalogue genre.".into());
            }
            params.push(("with_genres", genre));
        }
        if let Some(language) = filters.language.as_deref() {
            if language.len() != 2 || !language.bytes().all(|b| b.is_ascii_lowercase()) {
                return Err("Invalid original language.".into());
            }
            params.push(("with_original_language", language));
        }
        let (first, last);
        if let Some(decade) = filters.decade {
            if !(1900..=2100).contains(&decade) || decade % 10 != 0 {
                return Err("Invalid decade.".into());
            }
            first = format!("{decade:04}-01-01");
            last = format!("{:04}-12-31", decade + 9);
            params.push((since, &first));
            params.push((until, last.as_str().min(today)));
        } else {
            params.push((until, today));
        }
        if filters.order != "popular" {
            let minimum = if filters.order == "rated" {
                if filters.kind == "movie" {
                    "150"
                } else {
                    "50"
                }
            } else {
                "5"
            };
            params.push(("vote_count.gte", minimum));
        }
        self.tmdb_get(secret, route, &params, Some(Duration::from_secs(900)))
            .await
    }

    pub async fn tmdb_title_details(
        &self,
        secret: &str,
        kind: &str,
        id: u32,
    ) -> Result<Value, String> {
        let append = if kind == "movie" {
            "credits,recommendations,similar,release_dates,reviews,external_ids,videos,images"
        } else {
            "credits,recommendations,similar,content_ratings,reviews,external_ids,videos,images"
        };
        self.tmdb_get(
            secret,
            &media_route(kind, id)?,
            &[
                ("language", "en-GB"),
                ("append_to_response", append),
                ("include_image_language", "en,null"),
            ],
            Some(Duration::from_secs(86400)),
        )
        .await
    }

    pub async fn tmdb_collection(&self, secret: &str, id: u32) -> Result<Value, String> {
        if id == 0 {
            return Err("Unknown collection.".into());
        }
        self.tmdb_get(
            secret,
            &format!("collection/{id}"),
            &[("language", "en-GB")],
            Some(Duration::from_secs(86400)),
        )
        .await
    }

    pub async fn tmdb_episode_credits(
        &self,
        secret: &str,
        id: u32,
        season: u16,
        episode: u16,
    ) -> Result<Value, String> {
        if id == 0 || episode == 0 {
            return Err("Unknown episode.".into());
        }
        let route = format!(
            "{}/season/{season}/episode/{episode}/credits",
            media_route("tv", id)?
        );
        self.tmdb_get(
            secret,
            &route,
            &[("language", "en-GB")],
            Some(Duration::from_secs(86400)),
        )
        .await
    }

    pub async fn tmdb_season(&self, secret: &str, id: u32, number: u16) -> Result<Value, String> {
        let route = format!("{}/season/{number}", media_route("tv", id)?);
        self.tmdb_get(
            secret,
            &route,
            &[("language", "en-GB")],
            Some(Duration::from_secs(86400)),
        )
        .await
    }

    pub async fn tmdb_person_details(&self, secret: &str, id: u32) -> Result<Value, String> {
        if id == 0 {
            return Err("Unknown cast member.".into());
        }
        self.tmdb_get(
            secret,
            &format!("person/{id}"),
            &[
                ("language", "en-GB"),
                ("append_to_response", "combined_credits"),
            ],
            Some(Duration::from_secs(86400)),
        )
        .await
    }

    /// Cached TMDB GET for validated routes (used by mobile shelves, genres, logos, external IDs).
    pub async fn tmdb_raw(
        &self,
        secret: &str,
        route: &str,
        query: &[(String, String)],
        ttl_secs: u64,
    ) -> Result<Value, String> {
        let route = validate_tmdb_route(route)?;
        let borrowed: Vec<(&str, &str)> = query
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let ttl = (ttl_secs > 0).then(|| Duration::from_secs(ttl_secs));
        self.tmdb_get(secret, route, &borrowed, ttl).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_tmdb_routes() {
        assert_eq!(validate_tmdb_route("trending/all/week"), Ok("trending/all/week"));
        assert_eq!(validate_tmdb_route("tv/1396/external_ids"), Ok("tv/1396/external_ids"));
        assert!(validate_tmdb_route("").is_err());
        assert!(validate_tmdb_route("/movie/1").is_err());
        assert!(validate_tmdb_route("movie/../account").is_err());
        assert!(validate_tmdb_route("movie/1?api_key=leak").is_err());
    }
}
