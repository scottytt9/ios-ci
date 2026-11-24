use crate::{client::InterludeClient, torbox};
use reqwest::{header::LOCATION, Url};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

fn manifest_url(raw: &str) -> Result<Url, String> {
    let normalized = if let Some(host) = raw.strip_prefix("stremio://") {
        format!("https://{host}")
    } else {
        raw.to_owned()
    };
    let url = Url::parse(&normalized).map_err(|_| "Enter the add-on’s manifest URL.")?;
    let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if !(url.scheme() == "https" || (url.scheme() == "http" && loopback))
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || !url.path().ends_with("/manifest.json")
    {
        return Err("Use an HTTPS manifest.json URL, or a local HTTP manifest.".into());
    }
    Ok(url)
}

async fn fetch<T: serde::de::DeserializeOwned>(
    client: &reqwest::Client,
    url: Url,
) -> Result<T, String> {
    const LIMIT: usize = 2 * 1024 * 1024;
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(|_| "Couldn’t reach the stream add-on. Check its address and connection.")?;
    if !response.status().is_success() {
        return Err(format!(
            "The add-on returned HTTP {}.",
            response.status().as_u16()
        ));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Couldn’t read the add-on’s response.")?
    {
        if bytes.len() + chunk.len() > LIMIT {
            return Err("The add-on’s response was too large.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "The add-on returned invalid JSON.".into())
}

fn streams_url(
    mut url: Url,
    kind: &str,
    imdb: &str,
    season: Option<u16>,
    episode: Option<u16>,
) -> Result<Url, String> {
    if !imdb.strip_prefix("tt").is_some_and(|id| {
        (7..=12).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_digit())
    }) {
        return Err("This title has no usable IMDb ID.".into());
    }
    let (resource, id) = match (kind, season, episode) {
        ("movie", None, None) => ("movie", imdb.to_owned()),
        ("tv", Some(season), Some(episode)) if episode > 0 => {
            ("series", format!("{imdb}:{season}:{episode}"))
        }
        _ => return Err("Select an episode to look up TV sources.".into()),
    };
    url.path_segments_mut()
        .map_err(|_| "Invalid add-on address.")?
        .pop()
        .extend(["stream", resource, &format!("{id}.json")]);
    Ok(url)
}

#[derive(Deserialize)]
struct StreamList {
    #[serde(default)]
    streams: Vec<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TorrentSource {
    pub hash: String,
    pub file_index: Option<u64>,
    pub filename: Option<String>,
    pub name: String,
    pub description: String,
    pub bytes: Option<u64>,
    pub cached: Option<bool>,
}

fn torrents(list: StreamList) -> Vec<TorrentSource> {
    let mut seen = HashSet::new();
    list.streams
        .into_iter()
        .filter_map(|stream| {
            let hash = torbox::canonical_hash(stream["infoHash"].as_str()?)?;
            let file_index = stream["fileIdx"].as_u64();
            let hints = &stream["behaviorHints"];
            let filename = hints["filename"]
                .as_str()
                .filter(|name| !name.is_empty() && name.len() <= 512)
                .map(str::to_owned);
            if !seen.insert((
                hash.clone(),
                file_index,
                if file_index.is_none() {
                    filename.clone()
                } else {
                    None
                },
            )) {
                return None;
            }
            let name = stream["name"]
                .as_str()
                .filter(|name| !name.trim().is_empty())
                .unwrap_or("Torrent source");
            let description = stream["description"]
                .as_str()
                .or_else(|| stream["title"].as_str())
                .or(filename.as_deref())
                .unwrap_or("");
            Some(TorrentSource {
                hash,
                file_index,
                filename: filename.clone(),
                name: name.chars().take(120).collect(),
                description: description.chars().take(320).collect(),
                bytes: hints["videoSize"].as_u64(),
                cached: None,
            })
        })
        .take(60)
        .collect()
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceResults {
    pub torrents: Vec<TorrentSource>,
    pub cache_warning: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OnlineSubtitle {
    pub id: String,
    pub lang: String,
    pub label: String,
    pub url: String,
}

#[derive(Deserialize)]
struct SubtitleFeed {
    #[serde(default)]
    subtitles: Vec<Value>,
}

pub fn subtitle_language_label(code: &str) -> String {
    match code.to_ascii_lowercase().as_str() {
        "eng" | "en" => "English".into(),
        "spa" | "es" => "Spanish".into(),
        "fre" | "fra" | "fr" => "French".into(),
        "ger" | "deu" | "de" => "German".into(),
        "ita" | "it" => "Italian".into(),
        "por" | "pt" => "Portuguese".into(),
        "pob" | "pt-br" => "Portuguese (BR)".into(),
        "dut" | "nld" | "nl" => "Dutch".into(),
        "jpn" | "ja" => "Japanese".into(),
        "kor" | "ko" => "Korean".into(),
        "chi" | "zho" | "zh" => "Chinese".into(),
        "ara" | "ar" => "Arabic".into(),
        "rus" | "ru" => "Russian".into(),
        "pol" | "pl" => "Polish".into(),
        "tur" | "tr" => "Turkish".into(),
        "swe" | "sv" => "Swedish".into(),
        "nor" | "no" => "Norwegian".into(),
        "dan" | "da" => "Danish".into(),
        "fin" | "fi" => "Finnish".into(),
        "hin" | "hi" => "Hindi".into(),
        "ind" | "id" => "Indonesian".into(),
        "vie" | "vi" => "Vietnamese".into(),
        "ukr" | "uk" => "Ukrainian".into(),
        other => other.to_ascii_uppercase(),
    }
}

pub fn allowed_subtitle_url(raw: &str) -> Option<Url> {
    let url = Url::parse(raw.trim()).ok()?;
    if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() {
        return None;
    }
    let host = url.host_str()?.to_ascii_lowercase();
    let ok = host == "strem.io"
        || host.ends_with(".strem.io")
        || host == "opensubtitles.org"
        || host.ends_with(".opensubtitles.org");
    ok.then_some(url)
}

impl InterludeClient {
    pub async fn addon_verify(&self, raw: &str) -> Result<(), String> {
        let manifest: Value = fetch(&self.http, manifest_url(raw)?).await?;
        let supported = manifest["resources"].as_array().is_some_and(|resources| {
            resources.iter().any(|resource| {
                if resource == "stream" {
                    return true;
                }
                if resource["name"] != "stream" {
                    return false;
                }
                let types = resource["types"].as_array();
                let prefixes = resource["idPrefixes"].as_array();
                types.is_none_or(|types| {
                    types.is_empty() || types.iter().any(|kind| kind == "movie" || kind == "series")
                }) && prefixes.is_none_or(|values| {
                    values.is_empty() || values.iter().any(|value| value == "tt")
                })
            })
        });
        if !supported {
            return Err("Choose an add-on that provides movie or TV streams by IMDb ID.".into());
        }
        Ok(())
    }

    pub async fn addon_torrent_sources(
        &self,
        addon_url: &str,
        torbox_token: Option<&str>,
        kind: &str,
        imdb: &str,
        season: Option<u16>,
        episode: Option<u16>,
    ) -> Result<SourceResults, String> {
        let url = streams_url(manifest_url(addon_url)?, kind, imdb, season, episode)?;
        let mut results = torrents(fetch(&self.http, url).await?);
        if results.is_empty() {
            return Ok(SourceResults {
                torrents: results,
                cache_warning: None,
            });
        }
        let Some(token) = torbox_token.filter(|t| !t.trim().is_empty()) else {
            return Ok(SourceResults {
                torrents: results,
                cache_warning: None,
            });
        };
        let hashes = results
            .iter()
            .map(|source| source.hash.as_str())
            .collect::<HashSet<_>>();
        let cache_warning = match self.torbox_cache_status(token, hashes).await {
            Ok(cached) => {
                for source in &mut results {
                    source.cached = Some(cached.contains(&source.hash));
                }
                results.sort_by_key(|source| source.cached != Some(true));
                None
            }
            Err(error) => Some(error),
        };
        Ok(SourceResults {
            torrents: results,
            cache_warning,
        })
    }

    pub async fn online_subtitles(
        &self,
        kind: &str,
        imdb: &str,
        season: Option<u16>,
        episode: Option<u16>,
    ) -> Result<Vec<OnlineSubtitle>, String> {
        let imdb = imdb.trim();
        if !(imdb.starts_with("tt")
            && (7..=12).contains(&(imdb.len() - 2))
            && imdb[2..].bytes().all(|b| b.is_ascii_digit()))
        {
            return Err("No IMDb ID is available for online subtitles.".into());
        }
        let route = match kind {
            "movie" => format!("movie/{imdb}"),
            "tv" => match (season, episode) {
                (Some(s), Some(e)) if s <= 999 && (1..=9999).contains(&e) => {
                    format!("series/{imdb}:{s}:{e}")
                }
                _ => return Err("Choose an episode first.".into()),
            },
            _ => return Err("Online subtitles are only available for movies and TV shows.".into()),
        };
        let endpoint = format!("https://opensubtitles-v3.strem.io/subtitles/{route}.json");
        let response = self
            .http
            .get(&endpoint)
            .send()
            .await
            .map_err(|_| {
                "Couldn't reach OpenSubtitles. Check your connection and try again.".to_string()
            })?;
        if !response.status().is_success() {
            return Err("OpenSubtitles didn't return subtitles for this title.".into());
        }
        let feed: SubtitleFeed = response
            .json()
            .await
            .map_err(|_| "OpenSubtitles returned an unreadable response.".to_string())?;
        let mut tracks = Vec::new();
        let mut lang_counts: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
        for entry in feed.subtitles {
            let Some(url) = entry["url"].as_str().and_then(allowed_subtitle_url) else {
                continue;
            };
            let lang = entry["lang"]
                .as_str()
                .unwrap_or("und")
                .trim()
                .to_ascii_lowercase();
            let count = lang_counts.entry(lang.clone()).or_insert(0);
            if *count >= 4 {
                continue;
            }
            *count += 1;
            let id = entry["id"]
                .as_str()
                .map(str::to_string)
                .or_else(|| entry["id"].as_u64().map(|n| n.to_string()))
                .unwrap_or_else(|| format!("{lang}-{}", *count));
            let base = subtitle_language_label(&lang);
            let label = if *count > 1 {
                format!("{base} #{}", *count)
            } else {
                base
            };
            tracks.push(OnlineSubtitle {
                id,
                lang,
                label,
                url: url.to_string(),
            });
            if tracks.len() >= 28 {
                break;
            }
        }
        tracks.sort_by_key(|track| {
            if track.lang == "eng" || track.lang == "en" {
                0
            } else {
                1
            }
        });
        Ok(tracks)
    }

    pub async fn download_subtitle(&self, raw_url: &str) -> Result<String, String> {
        const LIMIT: usize = 4 * 1024 * 1024;
        let mut current = allowed_subtitle_url(raw_url)
            .ok_or_else(|| "Unsupported subtitle URL.".to_owned())?;
        for _ in 0..3 {
            let mut response = self
                .http
                .get(current.clone())
                .send()
                .await
                .map_err(|_| "Couldn’t download those subtitles.".to_owned())?;
            let status = response.status().as_u16();
            if (300..400).contains(&status) {
                let next = response
                    .headers()
                    .get(LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or_else(|| "Invalid subtitle redirect.".to_owned())?;
                let joined = current
                    .join(next)
                    .map_err(|_| "Invalid subtitle redirect.".to_owned())?;
                current = allowed_subtitle_url(joined.as_str())
                    .ok_or_else(|| "Unsupported subtitle URL.".to_owned())?;
                continue;
            }
            if !(200..300).contains(&status) {
                return Err("Couldn’t download those subtitles.".into());
            }
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| "Couldn’t download those subtitles.".to_owned())?
            {
                if bytes.len() + chunk.len() > LIMIT {
                    return Err("Subtitle file is too large.".into());
                }
                bytes.extend_from_slice(&chunk);
            }
            return Ok(String::from_utf8_lossy(&bytes).into_owned());
        }
        Err("Too many subtitle redirects.".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn preserves_private_addon_path_for_movie_and_episode_lookup() {
        let url =
            manifest_url("stremio://example.test/custom/token/manifest.json?mode=raw").unwrap();
        assert_eq!(
            streams_url(url.clone(), "movie", "tt1254207", None, None)
                .unwrap()
                .as_str(),
            "https://example.test/custom/token/stream/movie/tt1254207.json?mode=raw"
        );
        assert!(
            streams_url(url.clone(), "tv", "tt1254207", Some(2), Some(4))
                .unwrap()
                .path()
                .ends_with("/series/tt1254207:2:4.json")
        );
        assert!(streams_url(url, "tv", "tt1254207", Some(2), None).is_err());
        assert!(manifest_url("http://outside.test/manifest.json").is_err());
        assert!(manifest_url("http://127.0.0.1:7000/manifest.json").is_ok());
    }

    #[test]
    fn reads_raw_torrents_and_keeps_distinct_file_indices() {
        let hash = "ad31e9ad266d59e304c4c423e10def346345404d";
        let entries = torrents(StreamList {
            streams: vec![
                json!({"infoHash": hash, "fileIdx": 0, "behaviorHints": {"filename": "film.mkv"}}),
                json!({"infoHash": hash.to_uppercase(), "fileIdx": 0}),
                json!({"infoHash": hash, "fileIdx": 1}),
                json!({"url": "https://example.test/watch.mp4"}),
                json!({"infoHash": "invalid"}),
            ],
        });
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].file_index, Some(0));
        assert_eq!(entries[0].filename.as_deref(), Some("film.mkv"));
    }

    #[tokio::test]
    async fn requests_an_episode_from_a_local_addon_without_an_authorization_header() {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut connection, _) = listener.accept().unwrap();
            let mut request = BufReader::new(&connection);
            let mut first = String::new();
            request.read_line(&mut first).unwrap();
            assert!(first.starts_with("GET /profile/stream/series/tt1254207:1:2.json "));
            loop {
                let mut line = String::new();
                if request.read_line(&mut line).unwrap() == 0 || line.trim().is_empty() {
                    break;
                }
                assert!(!line.to_ascii_lowercase().starts_with("authorization:"));
            }
            let body = r#"{"streams":[{"infoHash":"ad31e9ad266d59e304c4c423e10def346345404d","fileIdx":0}]}"#;
            write!(
                connection,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let manifest = manifest_url(&format!("http://{address}/profile/manifest.json")).unwrap();
        let url = streams_url(manifest, "tv", "tt1254207", Some(1), Some(2)).unwrap();
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(3))
            .build()
            .unwrap();
        let streams = torrents(fetch(&client, url).await.unwrap());
        server.join().unwrap();
        assert_eq!(streams[0].file_index, Some(0));
    }
}
