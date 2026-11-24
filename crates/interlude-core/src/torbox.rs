use crate::client::{decode_response, json_response, InterludeClient};
use percent_encoding::percent_decode_str;
use reqwest::{header::LOCATION, Url};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashSet, time::Duration};

const BASE: &str = "https://api.torbox.app/v1/api";
const LABEL: &str = "TorBox";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Torrents,
    Usenet,
    Webdl,
}

impl Source {
    pub fn route(self) -> &'static str {
        match self {
            Self::Torrents => "torrents",
            Self::Usenet => "usenet",
            Self::Webdl => "webdl",
        }
    }

    pub fn id_parameter(self) -> &'static str {
        match self {
            Self::Torrents => "torrent_id",
            Self::Usenet => "usenet_id",
            Self::Webdl => "web_id",
        }
    }
}

#[derive(Deserialize)]
struct Envelope {
    success: bool,
    #[serde(default)]
    data: Value,
}

impl Envelope {
    fn into_data(self) -> Result<Value, String> {
        if self.success {
            Ok(self.data)
        } else {
            Err(
                "TorBox couldn't complete the request. Check that the download is ready and try again."
                    .into(),
            )
        }
    }
}

async fn call(request: reqwest::RequestBuilder) -> Result<Value, String> {
    let result: Envelope = json_response(request, LABEL).await?;
    result.into_data()
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileItem {
    pub source: Source,
    pub download_id: u64,
    pub file_id: u64,
    pub collection: String,
    pub name: String,
    pub bytes: u64,
    pub ready: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hash: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Download {
    pub source: Source,
    pub id: u64,
    pub name: String,
    pub status: String,
    pub progress: Option<f64>,
    pub ready: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Library {
    pub files: Vec<FileItem>,
    pub downloads: Vec<Download>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Receipt {
    pub source: Source,
    pub id: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attached {
    pub receipt: Receipt,
    pub files: Vec<FileItem>,
}

fn ready(item: &Value) -> bool {
    item["download_finished"].as_bool().unwrap_or(false)
        || item["download_present"].as_bool().unwrap_or(false)
        || matches!(
            item["download_state"].as_str(),
            Some("cached" | "completed" | "seeding")
        )
}

fn items(source: Source, value: &Value) -> Vec<FileItem> {
    let mut output = Vec::new();
    for item in value.as_array().into_iter().flatten() {
        let Some(download_id) = item["id"].as_u64() else {
            continue;
        };
        let collection = item["name"].as_str().unwrap_or("TorBox download");
        let ready = ready(item);
        let hash = item["hash"].as_str().and_then(canonical_hash);
        for file in item["files"].as_array().into_iter().flatten() {
            let Some(file_id) = file["id"].as_u64() else {
                continue;
            };
            let name = file["short_name"]
                .as_str()
                .filter(|name| !name.is_empty())
                .or_else(|| file["name"].as_str())
                .unwrap_or("");
            let name = name.rsplit(['/', '\\']).next().unwrap_or(name);
            let extension = name
                .rsplit_once('.')
                .map(|(_, ext)| ext.to_ascii_lowercase());
            if !matches!(
                extension.as_deref(),
                Some(
                    "mp4"
                        | "mkv"
                        | "webm"
                        | "m4v"
                        | "mov"
                        | "avi"
                        | "ts"
                        | "m2ts"
                        | "mpg"
                        | "mpeg"
                        | "wmv"
                )
            ) {
                continue;
            }
            output.push(FileItem {
                source,
                download_id,
                file_id,
                collection: collection.into(),
                name: name.into(),
                bytes: file["size"].as_u64().unwrap_or(0),
                ready,
                hash: hash.clone(),
            });
        }
    }
    output
}

pub fn torrent_hash(value: &str) -> bool {
    (value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        || (value.len() == 32
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphabetic() || (b'2'..=b'7').contains(&byte)))
}

pub fn canonical_hash(value: &str) -> Option<String> {
    if !torrent_hash(value) {
        return None;
    }
    if value.len() == 40 {
        return Some(value.to_ascii_lowercase());
    }
    let mut buffer = 0u16;
    let mut bits = 0;
    let mut hex = String::with_capacity(40);
    for byte in value.bytes().map(|byte| byte.to_ascii_uppercase()) {
        let digit = if byte.is_ascii_uppercase() {
            byte - b'A'
        } else {
            byte - b'2' + 26
        };
        buffer = (buffer << 5) | u16::from(digit);
        bits += 5;
        if bits >= 8 {
            use std::fmt::Write;
            bits -= 8;
            write!(hex, "{:02x}", ((buffer >> bits) & 255) as u8).ok()?;
        }
    }
    Some(hex)
}

pub fn validated_url(value: &str) -> Result<Url, String> {
    Url::parse(value)
        .ok()
        .filter(|url| {
            url.scheme() == "https"
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none()
        })
        .ok_or_else(|| "A secure playback link wasn't available.".into())
}

pub fn contains_account_credential(url: &Url, key: &str) -> bool {
    url.as_str().contains(key)
        || percent_decode_str(url.as_str())
            .decode_utf8_lossy()
            .contains(key)
        || url
            .query_pairs()
            .any(|(field, _)| field == "token" && url.host_str() == Some("api.torbox.app"))
}

fn input_source(input: &str) -> Result<(Source, Url), String> {
    if input.len() > 8192 {
        return Err("That source link is too long.".into());
    }
    let url = Url::parse(input).map_err(|_| "Enter an HTTPS download link or a magnet link.")?;
    if url.scheme() == "magnet" {
        let valid = url.query_pairs().any(|(name, value)| {
            name == "xt"
                && value
                    .strip_prefix("urn:btih:")
                    .is_some_and(|hash| torrent_hash(hash))
        });
        return if valid {
            Ok((Source::Torrents, url))
        } else {
            Err("The magnet link needs a valid torrent hash.".into())
        };
    }
    validated_url(input)
        .map(|url| (Source::Webdl, url))
        .map_err(|_| "Enter an HTTPS download link or a magnet link.".into())
}

fn cached_hashes(data: Value, requested: &HashSet<&str>) -> HashSet<String> {
    let known = |hash: &str| -> Option<String> {
        let hash = canonical_hash(hash)?;
        requested.contains(hash.as_str()).then_some(hash)
    };
    if let Some(list) = data.as_array() {
        return list
            .iter()
            .filter(|item| item["cached"].as_bool() != Some(false))
            .filter_map(|item| {
                item.as_str()
                    .or_else(|| item["hash"].as_str())
                    .and_then(known)
            })
            .collect();
    }
    data.as_object()
        .into_iter()
        .flatten()
        .filter(|(_, value)| {
            !value.is_null()
                && value.as_bool() != Some(false)
                && value["cached"].as_bool() != Some(false)
        })
        .filter_map(|(hash, _)| known(hash))
        .collect()
}

async fn resolve_playback_endpoint(
    client: &reqwest::Client,
    endpoint: &str,
    key: &str,
    source: Source,
    download_id: u64,
    file_id: u64,
) -> Result<Url, String> {
    let response = client
        .get(endpoint)
        .query(&[
            ("token", key),
            (source.id_parameter(), &download_id.to_string()),
            ("file_id", &file_id.to_string()),
            ("redirect", "true"),
            ("zip_link", "false"),
            ("append_name", "true"),
        ])
        .send()
        .await
        .map_err(|_| "Couldn't reach TorBox. Check your connection and try again.")?;
    if matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) {
        let location = response
            .headers()
            .get(LOCATION)
            .and_then(|value| value.to_str().ok())
            .ok_or("TorBox redirected the request without a playback link.")?;
        return validated_url(location);
    }
    let result: Envelope = decode_response(response, LABEL).await?;
    let data = result.into_data()?;
    validated_url(data.as_str().unwrap_or_default())
}

impl InterludeClient {
    pub async fn torbox_verify(&self, key: &str) -> Result<(), String> {
        call(self.http.get(format!("{BASE}/user/me")).bearer_auth(key))
            .await
            .map(|_| ())
    }

    async fn torbox_list(
        &self,
        key: &str,
        source: Source,
        refresh: bool,
    ) -> Result<(Vec<FileItem>, Vec<Download>), String> {
        const LIMIT: usize = 250;
        let mut files = Vec::new();
        let mut downloads = Vec::new();
        let limit = LIMIT.to_string();
        for page in 0..40 {
            let offset = (page * LIMIT).to_string();
            let data = call(
                self.http
                    .get(format!("{BASE}/{}/mylist", source.route()))
                    .bearer_auth(key)
                    .query(&[
                        ("offset", offset.as_str()),
                        ("limit", limit.as_str()),
                        ("bypass_cache", if refresh { "true" } else { "false" }),
                    ]),
            )
            .await?;
            let count = data.as_array().map_or(0, Vec::len);
            files.extend(items(source, &data));
            for item in data.as_array().into_iter().flatten() {
                let Some(id) = item["id"].as_u64() else {
                    continue;
                };
                downloads.push(Download {
                    source,
                    id,
                    ready: ready(item),
                    name: item["name"].as_str().unwrap_or("TorBox download").into(),
                    status: item["download_state"]
                        .as_str()
                        .unwrap_or("preparing")
                        .into(),
                    progress: item["progress"]
                        .as_f64()
                        .filter(|value| (0.0..=1.0).contains(value)),
                });
            }
            if count < LIMIT {
                break;
            }
        }
        Ok((files, downloads))
    }

    pub async fn torbox_library(&self, key: &str, refresh: bool) -> Result<Library, String> {
        let (torrents, usenet, web) = tokio::join!(
            self.torbox_list(key, Source::Torrents, refresh),
            self.torbox_list(key, Source::Usenet, refresh),
            self.torbox_list(key, Source::Webdl, refresh)
        );
        let mut files = Vec::new();
        let mut downloads = Vec::new();
        let mut warnings = Vec::new();
        let mut failures = 0;
        for (label, result) in [
            ("Torrents", torrents),
            ("Usenet", usenet),
            ("Web downloads", web),
        ] {
            match result {
                Ok((items, jobs)) => {
                    files.extend(items);
                    downloads.extend(jobs);
                }
                Err(error) => {
                    failures += 1;
                    warnings.push(format!("{label}: {error}"));
                }
            }
        }
        if failures == 3 {
            return Err(warnings[0].clone());
        }
        Ok(Library {
            files,
            downloads,
            warnings,
        })
    }

    pub async fn torbox_add_source(&self, token: &str, link: &str) -> Result<Receipt, String> {
        let (source, url) = input_source(link.trim())?;
        let req = match source {
            Source::Torrents => self
                .http
                .post(format!("{BASE}/torrents/createtorrent"))
                .multipart(reqwest::multipart::Form::new().text("magnet", url.to_string())),
            Source::Webdl => self
                .http
                .post(format!("{BASE}/webdl/createwebdownload"))
                .form(&[("link", url.as_str())]),
            Source::Usenet => return Err("Use the TorBox dashboard to add an NZB.".into()),
        };
        let result: Envelope = json_response(req.bearer_auth(token), LABEL).await?;
        if !result.success {
            return Err(
                "TorBox declined this source. Check the link and your download limits.".into(),
            );
        }
        let id = ["torrent_id", "webdownload_id", "web_id", "id"]
            .into_iter()
            .find_map(|key| result.data[key].as_u64());
        Ok(Receipt { source, id })
    }

    pub async fn torbox_cache_status(
        &self,
        token: &str,
        hashes: HashSet<&str>,
    ) -> Result<HashSet<String>, String> {
        let request = self
            .http
            .post(format!("{BASE}/torrents/checkcached"))
            .bearer_auth(token)
            .query(&[("format", "list"), ("list_files", "false")])
            .json(&serde_json::json!({"hashes": hashes}));
        let result: Envelope = json_response(request, LABEL).await?;
        if !result.success {
            return Err(
                "TorBox couldn’t check its cache. You can still try a cached-only request.".into(),
            );
        }
        if !result.data.is_null() && !result.data.is_array() && !result.data.is_object() {
            return Err("TorBox returned an unexpected cache response.".into());
        }
        Ok(cached_hashes(result.data, &hashes))
    }

    pub async fn torbox_attach_torrent(
        &self,
        token: &str,
        hash: &str,
        cached_only: bool,
    ) -> Result<Attached, String> {
        if !torrent_hash(hash) {
            return Err("Invalid torrent hash.".into());
        }
        let data = reqwest::multipart::Form::new()
            .text("magnet", format!("magnet:?xt=urn:btih:{hash}"))
            .text(
                "add_only_if_cached",
                if cached_only { "true" } else { "false" },
            );
        let response: Envelope = json_response(
            self.http
                .post(format!("{BASE}/torrents/createtorrent"))
                .bearer_auth(token)
                .multipart(data),
            LABEL,
        )
        .await?;
        if !response.success {
            return Err(if cached_only {
                "TorBox couldn’t add this as a cached torrent. Refresh the results or try another source."
                    .into()
            } else {
                "TorBox declined the torrent. Check your download limits and try another source."
                    .into()
            });
        }
        let id = response.data["torrent_id"]
            .as_u64()
            .or_else(|| response.data["id"].as_u64());
        let receipt = Receipt {
            source: Source::Torrents,
            id,
        };
        let Some(id) = id.filter(|_| cached_only) else {
            return Ok(Attached {
                receipt,
                files: Vec::new(),
            });
        };
        let found = tokio::time::timeout(Duration::from_secs(8), self.ready_torrent(token, id))
            .await
            .unwrap_or_default();
        Ok(Attached {
            receipt,
            files: found,
        })
    }

    async fn ready_torrent(&self, token: &str, id: u64) -> Vec<FileItem> {
        let id = id.to_string();
        for delay in [0, 250, 500, 850, 1250, 1600] {
            if delay > 0 {
                tokio::time::sleep(Duration::from_millis(delay)).await;
            }
            let request = self
                .http
                .get(format!("{BASE}/torrents/mylist"))
                .bearer_auth(token)
                .query(&[
                    ("id", id.as_str()),
                    ("bypass_cache", "true"),
                    ("files", "true"),
                ]);
            if let Ok(value) = call(request).await {
                let rows = if value.is_array() {
                    value
                } else {
                    Value::Array(vec![value])
                };
                let files: Vec<_> = items(Source::Torrents, &rows)
                    .into_iter()
                    .filter(|file| file.ready)
                    .collect();
                if !files.is_empty() {
                    return files;
                }
            }
        }
        Vec::new()
    }

    pub async fn torbox_resolve_playback(
        &self,
        key: &str,
        source: Source,
        download_id: u64,
        file_id: u64,
    ) -> Result<Url, String> {
        resolve_playback_endpoint(
            &self.http,
            &format!("{BASE}/{}/requestdl", source.route()),
            key,
            source,
            download_id,
            file_id,
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn library_uses_file_ids_including_zero_and_filters_non_video_files() {
        let rows = json!([{
            "id": 42,
            "name": "Open films",
            "download_state": "cached",
            "files": [
                {"id": 0, "name": "folder\\Sintel.MKV", "size": 2048},
                {"id": 1, "short_name": "Read me.txt"},
                {"id": 2, "short_name": "", "name": "folder/Big Buck Bunny.mp4"}
            ]
        }]);
        let files = items(Source::Torrents, &rows);
        assert_eq!(files.len(), 2);
        assert_eq!((files[0].download_id, files[0].file_id), (42, 0));
        assert_eq!(files[0].name, "Sintel.MKV");
        assert_eq!(files[1].name, "Big Buck Bunny.mp4");
        assert!(files.iter().all(|file| file.ready));
    }

    #[test]
    fn only_secure_playback_links_without_userinfo_are_accepted() {
        assert!(validated_url("https://cdn.example.test/file.mp4?signature=test").is_ok());
        for invalid in [
            "http://cdn.example.test/file.mp4",
            "https://user:secret@cdn.example.test/file.mp4",
            "file:///C:/sample.mp4",
            "--script=unknown",
        ] {
            assert!(validated_url(invalid).is_err(), "{invalid}");
        }
    }

    #[tokio::test]
    async fn resolves_torbox_playback_redirect_and_direct_json() {
        use std::io::{BufRead, BufReader, Write};

        let cdn = "https://cdn.example.test/file.mkv?signature=short-lived";
        let json = json!({ "success": true, "data": cdn }).to_string();
        for (status, headers, body) in [
            ("302 Found", format!("Location: {cdn}\r\n"), ""),
            ("307 Temporary Redirect", format!("Location: {cdn}\r\n"), ""),
            (
                "200 OK",
                "Content-Type: application/json\r\n".into(),
                json.as_str(),
            ),
        ] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = listener.local_addr().unwrap();
            let response = format!(
                "HTTP/1.1 {status}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let server = std::thread::spawn(move || {
                let (mut connection, _) = listener.accept().unwrap();
                connection
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut lines = BufReader::new(&connection).lines();
                let request = lines.next().unwrap().unwrap();
                let target = request.split_whitespace().nth(1).unwrap();
                let url = Url::parse(&format!("http://{addr}{target}")).unwrap();
                let params: std::collections::HashMap<_, _> = url.query_pairs().collect();
                assert_eq!(url.path(), "/torrents/requestdl");
                assert_eq!(params["token"], "example-account-key");
                assert_eq!(params["redirect"], "true");
                assert_eq!(params["torrent_id"], "42");
                assert_eq!(params["file_id"], "0");
                for line in lines {
                    if line.unwrap().is_empty() {
                        break;
                    }
                }
                connection.write_all(response.as_bytes()).unwrap();
            });
            let client = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(3))
                .build()
                .unwrap();
            let result = resolve_playback_endpoint(
                &client,
                &format!("http://{addr}/torrents/requestdl"),
                "example-account-key",
                Source::Torrents,
                42,
                0,
            )
            .await;
            server.join().unwrap();
            assert_eq!(result.as_ref().map(Url::as_str), Ok(cdn));
        }
    }

    #[test]
    fn keeps_account_keys_out_of_playback_destinations() {
        let key = "example-account-key";
        for link in [
            "https://api.torbox.app/v1/api/torrents/requestdl?token=another-key",
            "https://cdn.example.test/file?sig=example-account-key",
            "https://cdn.example.test/example%2Daccount%2Dkey/movie.mkv",
        ] {
            assert!(contains_account_credential(
                &validated_url(link).unwrap(),
                key
            ));
        }
        let signed = validated_url("https://cdn.example.test/file?token=signature").unwrap();
        assert!(!contains_account_credential(&signed, key));
    }

    #[test]
    fn add_source_accepts_torrent_hashes_and_https_links() {
        assert!(matches!(
            input_source("magnet:?xt=urn:btih:1234567890000000000000000000000000000000"),
            Ok((Source::Torrents, _))
        ));
        assert!(matches!(
            input_source("https://example.test/film.mp4"),
            Ok((Source::Webdl, _))
        ));
        assert!(input_source("magnet:?xt=urn:btih:no-hash").is_err());
        assert!(input_source("ftp://example.test/film.mp4").is_err());
    }

    #[test]
    fn cache_response_ignores_explicit_misses_and_unrequested_hashes() {
        let first = "0000000000000000000000000000000000000000";
        let second = "1111111111111111111111111111111111111111";
        let requested = HashSet::from([first, second]);
        assert_eq!(
            canonical_hash("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA").as_deref(),
            Some(first)
        );
        assert_eq!(
            cached_hashes(
                json!([{ "hash": first }, {"hash": second, "cached": false }]),
                &requested
            ),
            HashSet::from([first.to_owned()])
        );
        assert_eq!(
            cached_hashes(
                json!({ (first): null, (second): {"size": 300} }),
                &requested
            ),
            HashSet::from([second.to_owned()])
        );
    }
}
