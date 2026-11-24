use crate::{
    client::{json_response, InterludeClient},
    timeline::{CommunityTimings, IntervalMs},
};
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Segment {
    pub start_sec: f64,
    pub end_sec: f64,
}

impl Segment {
    pub fn to_interval_ms(&self) -> Option<IntervalMs> {
        if self.start_sec.is_finite() && self.end_sec.is_finite() {
            Some(IntervalMs {
                start_ms: (self.start_sec * 1000.0).round() as i64,
                end_ms: (self.end_sec * 1000.0).round() as i64,
            })
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Timings {
    pub intro: Option<Segment>,
    pub recap: Option<Segment>,
    pub outro: Option<Segment>,
    pub post_credits: Option<Segment>,
}

impl Timings {
    pub fn to_community_timings(&self) -> CommunityTimings {
        CommunityTimings {
            intro: self.intro.as_ref().and_then(Segment::to_interval_ms),
            recap: self.recap.as_ref().and_then(Segment::to_interval_ms),
            outro: self.outro.as_ref().and_then(Segment::to_interval_ms),
            post_credits: self.post_credits.as_ref().and_then(Segment::to_interval_ms),
        }
    }
}

impl InterludeClient {
    pub async fn segment_timings(
        &self,
        imdb: &str,
        season: Option<u16>,
        episode: Option<u16>,
    ) -> Result<Option<Timings>, String> {
        if !imdb.strip_prefix("tt").is_some_and(|id| {
            (7..=12).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_digit())
        }) {
            return Ok(None);
        }
        let request = self
            .http
            .get("https://api.introdb.app/segments")
            .query(&[("imdb_id", imdb)])
            .timeout(Duration::from_secs(4));
        let request = match (season, episode) {
            (None, None) => request.query(&[("is_movie", true)]),
            (Some(season), Some(episode)) if season > 0 && episode > 0 => {
                request.query(&[("season", season), ("episode", episode)])
            }
            _ => return Ok(None),
        };
        json_response(request, "IntroDB").await.map(Some)
    }
}
