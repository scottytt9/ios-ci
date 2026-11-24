use crate::CoreError;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use flate2::{read::GzDecoder, write::GzEncoder, Compression};
use regex::Regex;
use serde_json::{json, Map, Value};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    sync::OnceLock,
};

pub const PROFILE_PREFIX: &str = "INTERLUDE-PROFILE1:";
const PROFILE_FORMAT: &str = "interlude-profile";
const HISTORY_FORMAT: &str = "interlude-watch-history";
pub const PROFILE_CODE_LIMIT: usize = 3 * 1024 * 1024;
pub const PROFILE_DATA_LIMIT: usize = 8 * 1024 * 1024;
const MAX_STAMP: i64 = 8_640_000_000_000_000;

pub const PRESET_THEME_IDS: [&str; 12] = [
    "interlude",
    "oled",
    "midnight",
    "plum",
    "ember",
    "daylight",
    "crimson",
    "cyber",
    "emerald",
    "gold",
    "rose",
    "nord",
];

fn id_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(?:movie:[0-9]+|(?:tv|tvmaze):[0-9]+(?::[0-9]+:[0-9]+)?|file:(?:torrents|usenet|webdl):[0-9]+:[0-9]+)$")
            .unwrap()
    })
}

fn color_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^#[a-fA-F0-9]{6}$").unwrap())
}

fn base64url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[A-Za-z0-9_-]+$").unwrap())
}

fn valid_id(value: &str) -> bool {
    value.len() <= 100 && id_regex().is_match(value)
}

pub fn is_valid_hex_color(value: &str) -> bool {
    color_regex().is_match(value)
}

fn valid_stamp(value: i64) -> bool {
    value > 0 && value < MAX_STAMP
}

fn select_primitives(source: &Map<String, Value>, keys: &[&str]) -> Map<String, Value> {
    let mut out = Map::new();
    for &key in keys {
        if let Some(val) = source.get(key) {
            if val.is_string() || val.is_number() || val.is_boolean() {
                out.insert(key.to_owned(), val.clone());
            }
        }
    }
    out
}

fn clean_media(value: &Value) -> Result<Value, CoreError> {
    let obj = value
        .as_object()
        .ok_or_else(|| CoreError::InvalidInput("Invalid media.".into()))?;
    let key = obj
        .get("key")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidInput("Invalid media.".into()))?;
    let kind = obj
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidInput("Invalid media.".into()))?;
    let title = obj
        .get("title")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidInput("Invalid media.".into()))?;
    if !valid_id(key) || !matches!(kind, "movie" | "tv" | "file") || title.trim().is_empty() {
        return Err(CoreError::InvalidInput("Invalid media.".into()));
    }
    let mut clean = select_primitives(
        obj,
        &[
            "year",
            "description",
            "id",
            "rating",
            "runtime",
            "releaseDate",
            "genre",
            "imdbId",
            "provider",
        ],
    );
    clean.insert("key".into(), Value::String(key.to_owned()));
    clean.insert("kind".into(), Value::String(kind.to_owned()));
    clean.insert("title".into(), Value::String(title.to_owned()));
    if kind == "file" {
        clean.insert("description".into(), Value::String(String::new()));
    }
    for field in ["poster", "backdrop"] {
        if let Some(url) = obj.get(field).and_then(Value::as_str) {
            if url.starts_with("https://image.tmdb.org/")
                || url.starts_with("https://static.tvmaze.com/")
            {
                clean.insert(field.into(), Value::String(url.to_owned()));
            }
        }
    }
    if let Some(genres) = obj.get("genres").and_then(Value::as_array) {
        let strings: Vec<Value> = genres
            .iter()
            .take(20)
            .filter_map(|v| v.as_str().map(|s| Value::String(s.to_owned())))
            .collect();
        clean.insert("genres".into(), Value::Array(strings));
    }
    Ok(Value::Object(clean))
}

fn clean_playback(value: &Value) -> Result<(String, Value), CoreError> {
    let obj = value
        .as_object()
        .ok_or_else(|| CoreError::InvalidInput("Invalid playback identifier.".into()))?;
    let id = obj
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::InvalidInput("Invalid playback identifier.".into()))?;
    if !valid_id(id) {
        return Err(CoreError::InvalidInput(
            "Invalid playback identifier.".into(),
        ));
    }
    let media = clean_media(
        obj.get("media")
            .ok_or_else(|| CoreError::InvalidInput("Invalid media.".into()))?,
    )?;
    let mut clean = select_primitives(obj, &["label"]);
    clean.insert("id".into(), Value::String(id.to_owned()));
    clean.insert("media".into(), media);
    if let Some(ep) = obj.get("episode").and_then(Value::as_object) {
        clean.insert(
            "episode".into(),
            Value::Object(select_primitives(ep, &["season", "number", "title"])),
        );
    }
    Ok((id.to_owned(), Value::Object(clean)))
}

fn entry_edited(entry: &Value) -> i64 {
    entry
        .get("modified")
        .and_then(Value::as_i64)
        .or_else(|| entry.get("updated").and_then(Value::as_i64))
        .unwrap_or(0)
}

struct ParsedProfile {
    entries: BTreeMap<String, Value>,
    removals: BTreeMap<String, i64>,
    list: Vec<(String, Value)>,
    custom_themes: Vec<(String, Value)>,
    selected_theme: String,
}

impl ParsedProfile {
    fn from_json(json_str: &str) -> Result<Self, CoreError> {
        let doc: Value = serde_json::from_str(json_str)
            .map_err(|_| CoreError::InvalidInput("This profile code is incomplete or unsupported.".into()))?;
        let obj = doc
            .as_object()
            .ok_or_else(|| CoreError::InvalidInput("Unknown profile version.".into()))?;
        if obj.get("format").and_then(Value::as_str) != Some(PROFILE_FORMAT)
            || obj.get("version").and_then(Value::as_i64) != Some(1)
        {
            return Err(CoreError::InvalidInput("Unknown profile version.".into()));
        }

        let history = obj
            .get("history")
            .and_then(Value::as_object)
            .ok_or_else(|| CoreError::InvalidInput("Unknown history version.".into()))?;
        if history.get("format").and_then(Value::as_str) != Some(HISTORY_FORMAT)
            || history.get("version").and_then(Value::as_i64) != Some(1)
        {
            return Err(CoreError::InvalidInput("Unknown history version.".into()));
        }

        let raw_entries = history
            .get("entries")
            .and_then(Value::as_array)
            .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?;

        let mut removals = BTreeMap::new();
        if let Some(raw_removals) = history.get("removals").and_then(Value::as_object) {
            for (id, val) in raw_removals {
                if let Some(ts) = val.as_i64() {
                    if valid_id(id) && valid_stamp(ts) {
                        removals.insert(id.clone(), ts);
                    }
                }
            }
        }

        let mut entries: BTreeMap<String, Value> = BTreeMap::new();
        for raw in raw_entries {
            let e = raw
                .as_object()
                .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?;
            let (id, playback) = clean_playback(
                e.get("playback")
                    .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?,
            )?;
            let time = e
                .get("time")
                .and_then(Value::as_f64)
                .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?;
            let duration = e
                .get("duration")
                .and_then(Value::as_f64)
                .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?;
            let updated = e
                .get("updated")
                .and_then(Value::as_i64)
                .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?;
            let modified = e.get("modified").and_then(Value::as_i64).unwrap_or(updated);
            let complete = e
                .get("complete")
                .and_then(Value::as_bool)
                .ok_or_else(|| CoreError::InvalidInput("Invalid watch history.".into()))?;

            if !(time.is_finite()
                && (0.0..=1_000_000.0).contains(&time)
                && duration.is_finite()
                && (0.0..=1_000_000.0).contains(&duration)
                && valid_stamp(updated)
                && valid_stamp(modified))
            {
                return Err(CoreError::InvalidInput("Invalid watch history.".into()));
            }

            let mut clean = Map::new();
            clean.insert("playback".into(), playback);
            clean.insert("time".into(), json!(time));
            clean.insert("duration".into(), json!(duration));
            clean.insert("updated".into(), json!(updated));
            clean.insert("modified".into(), json!(modified));
            clean.insert("complete".into(), json!(complete));
            if let Some(so) = e.get("seriesOverride").and_then(Value::as_i64) {
                if valid_stamp(so) {
                    clean.insert("seriesOverride".into(), json!(so));
                }
            }
            if let Some(orig) = e.get("importedFromStremio").and_then(Value::as_object) {
                clean.insert(
                    "importedFromStremio".into(),
                    Value::Object(select_primitives(
                        orig,
                        &[
                            "title",
                            "importedAt",
                            "watchedDate",
                            "imdbRating",
                            "reportedPercent",
                        ],
                    )),
                );
            }
            let val = Value::Object(clean);
            let edited = entry_edited(&val);
            let removed_at = removals.get(&id).copied().unwrap_or(0);
            let prev_edited = entries.get(&id).map(entry_edited).unwrap_or(0);
            if edited > prev_edited && edited > removed_at {
                entries.insert(id, val);
            }
        }

        let raw_list = obj
            .get("list")
            .and_then(Value::as_array)
            .ok_or_else(|| CoreError::InvalidInput("Invalid profile list.".into()))?;
        let mut list: Vec<(String, Value)> = Vec::new();
        for item in raw_list {
            let media = clean_media(item)?;
            let key = media["key"].as_str().unwrap_or("").to_owned();
            if let Some(existing) = list.iter_mut().find(|(k, _)| k == &key) {
                existing.1 = media;
            } else {
                list.push((key, media));
            }
        }

        let themes = obj
            .get("themes")
            .and_then(Value::as_object)
            .ok_or_else(|| CoreError::InvalidInput("Invalid profile themes.".into()))?;
        let raw_custom = themes
            .get("custom")
            .and_then(Value::as_array)
            .ok_or_else(|| CoreError::InvalidInput("Invalid profile themes.".into()))?;
        let mut custom_themes: Vec<(String, Value)> = Vec::new();
        for item in raw_custom {
            let Some(t) = item.as_object() else {
                continue;
            };
            let (Some(id), Some(name), Some(bg), Some(accent)) = (
                t.get("id").and_then(Value::as_str),
                t.get("name").and_then(Value::as_str),
                t.get("background").and_then(Value::as_str),
                t.get("accent").and_then(Value::as_str),
            ) else {
                continue;
            };
            if id.starts_with("custom-")
                && !name.trim().is_empty()
                && name.chars().count() <= 48
                && is_valid_hex_color(bg)
                && is_valid_hex_color(accent)
            {
                let theme_val = json!({
                    "id": id,
                    "name": name,
                    "background": bg,
                    "accent": accent,
                });
                if let Some(existing) = custom_themes.iter_mut().find(|(k, _)| k == id) {
                    existing.1 = theme_val;
                } else {
                    custom_themes.push((id.to_owned(), theme_val));
                }
            }
        }

        let requested = themes
            .get("selected")
            .and_then(Value::as_str)
            .unwrap_or("interlude");
        let is_known = PRESET_THEME_IDS.contains(&requested)
            || custom_themes.iter().any(|(id, _)| id == requested);
        let selected_theme = if is_known {
            requested.to_owned()
        } else {
            "interlude".to_owned()
        };

        Ok(Self {
            entries,
            removals,
            list,
            custom_themes,
            selected_theme,
        })
    }

    fn to_json(&self) -> Result<String, CoreError> {
        let mut entries_vec: Vec<Value> = self.entries.values().cloned().collect();
        entries_vec.sort_by(|a, b| {
            let ua = a.get("updated").and_then(Value::as_i64).unwrap_or(0);
            let ub = b.get("updated").and_then(Value::as_i64).unwrap_or(0);
            ub.cmp(&ua)
        });
        let removals_map: Map<String, Value> = self
            .removals
            .iter()
            .map(|(k, &v)| (k.clone(), json!(v)))
            .collect();
        let list_vec: Vec<Value> = self.list.iter().map(|(_, v)| v.clone()).collect();
        let custom_vec: Vec<Value> = self.custom_themes.iter().map(|(_, v)| v.clone()).collect();
        let doc = json!({
            "format": PROFILE_FORMAT,
            "version": 1,
            "history": {
                "format": HISTORY_FORMAT,
                "version": 1,
                "entries": entries_vec,
                "removals": removals_map,
            },
            "list": list_vec,
            "themes": {
                "selected": self.selected_theme,
                "custom": custom_vec,
            }
        });
        serde_json::to_string(&doc)
            .map_err(|_| CoreError::InvalidInput("Couldn't serialize profile.".into()))
    }
}

/// Validates and canonicalizes a profile document JSON string.
pub fn sanitize_profile_json(document_json: &str) -> Result<String, CoreError> {
    ParsedProfile::from_json(document_json)?.to_json()
}

/// Encodes a profile document JSON string into an `INTERLUDE-PROFILE1:` transfer code.
pub fn encode_profile_code(document_json: &str) -> Result<String, CoreError> {
    let canonical = sanitize_profile_json(document_json)?;
    let bytes = canonical.as_bytes();
    if bytes.len() > PROFILE_DATA_LIMIT {
        return Err(CoreError::TooLarge(
            "This profile is too large to copy as a code.".into(),
        ));
    }
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(bytes)
        .map_err(|_| CoreError::InvalidInput("Couldn't compress profile.".into()))?;
    let compressed = encoder
        .finish()
        .map_err(|_| CoreError::InvalidInput("Couldn't compress profile.".into()))?;
    let code = format!("{PROFILE_PREFIX}{}", URL_SAFE_NO_PAD.encode(compressed));
    if code.len() > PROFILE_CODE_LIMIT {
        return Err(CoreError::TooLarge(
            "This profile is too large to copy as a code.".into(),
        ));
    }
    Ok(code)
}

/// Decodes and sanitizes an `INTERLUDE-PROFILE1:` transfer code into canonical profile JSON.
pub fn decode_profile_code(input: &str) -> Result<String, CoreError> {
    if input.len() > PROFILE_CODE_LIMIT + 4096 {
        return Err(CoreError::TooLarge("This profile code is too large.".into()));
    }
    let code: String = input.chars().filter(|c| !c.is_whitespace()).collect();
    let Some(payload) = code.strip_prefix(PROFILE_PREFIX) else {
        return Err(CoreError::InvalidInput(
            "Paste a complete Interlude profile code.".into(),
        ));
    };
    if code.len() > PROFILE_CODE_LIMIT || !base64url_regex().is_match(payload) {
        return Err(CoreError::InvalidInput(
            "Paste a complete Interlude profile code.".into(),
        ));
    }
    let compressed = URL_SAFE_NO_PAD.decode(payload).map_err(|_| {
        CoreError::InvalidInput("This profile code is incomplete or unsupported.".into())
    })?;
    let mut decoder = GzDecoder::new(&compressed[..]).take((PROFILE_DATA_LIMIT + 1) as u64);
    let mut decompressed = Vec::new();
    decoder.read_to_end(&mut decompressed).map_err(|_| {
        CoreError::InvalidInput("This profile code is incomplete or unsupported.".into())
    })?;
    if decompressed.len() > PROFILE_DATA_LIMIT {
        return Err(CoreError::TooLarge("This profile code is too large.".into()));
    }
    let json_str = String::from_utf8(decompressed).map_err(|_| {
        CoreError::InvalidInput("This profile code is incomplete or unsupported.".into())
    })?;
    sanitize_profile_json(&json_str)
}

/// Merges an incoming profile into a local profile (last-write-wins history + removals, incoming list & themes).
pub fn merge_profiles_json(local_json: &str, incoming_json: &str) -> Result<String, CoreError> {
    let mut local = ParsedProfile::from_json(local_json)?;
    let incoming = ParsedProfile::from_json(incoming_json)?;

    for (id, ts) in incoming.removals {
        local
            .removals
            .entry(id)
            .and_modify(|existing| *existing = (*existing).max(ts))
            .or_insert(ts);
    }
    for (id, entry) in incoming.entries {
        let edited = entry_edited(&entry);
        let prev = local.entries.get(&id).map(entry_edited).unwrap_or(0);
        let removed = local.removals.get(&id).copied().unwrap_or(0);
        if edited > prev && edited > removed {
            local.entries.insert(id, entry);
        }
    }
    local.entries.retain(|id, entry| {
        let removed = local.removals.get(id).copied().unwrap_or(0);
        entry_edited(entry) > removed
    });
    local.list = incoming.list;
    local.custom_themes = incoming.custom_themes;
    local.selected_theme = incoming.selected_theme;
    local.to_json()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_and_roundtrips_windows_fixture() {
        let fixture = include_str!("../../../ios/Tests/Fixtures/profile-code.txt");
        let decoded_json = decode_profile_code(fixture).unwrap();
        let doc: Value = serde_json::from_str(&decoded_json).unwrap();
        assert_eq!(doc["history"]["entries"][0]["time"].as_f64(), Some(123.5));
        assert_eq!(
            doc["history"]["removals"]["movie:40"].as_i64(),
            Some(1_777_000_000_001)
        );
        assert_eq!(doc["list"][0]["title"].as_str(), Some("Épisode test"));
        assert_eq!(doc["themes"]["custom"][0]["accent"].as_str(), Some("#fbe44a"));

        let reencoded = encode_profile_code(&decoded_json).unwrap();
        assert!(reencoded.starts_with(PROFILE_PREFIX));
        let roundtrip: Value =
            serde_json::from_str(&decode_profile_code(&reencoded).unwrap()).unwrap();
        assert_eq!(
            roundtrip["history"]["entries"][0]["playback"]["episode"]["number"].as_i64(),
            Some(3)
        );
    }
}
