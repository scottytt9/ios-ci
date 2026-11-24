use crate::CoreError;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use flate2::{read::GzDecoder, write::GzEncoder, Compression};
use hmac::{Hmac, Mac};
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    sync::{Mutex, OnceLock},
};
use unicode_normalization::UnicodeNormalization;

pub const DIRECT_INVITE_PREFIX: &str = "INTERLUDE1:";
pub const DIRECT_INVITE_LIFETIME_MS: i64 = 15 * 60 * 1000;
const MAX_DIRECT_CODE_LEN: usize = 24_000;
const MAX_DIRECT_SDP_BYTES: usize = 48_000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IceCandidate {
    pub mid: String,
    pub index: i32,
    pub sdp: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirectRoomInvite {
    pub room: String,
    pub role: String,
    pub expires: i64,
    pub sdp: String,
    pub ice: Vec<IceCandidate>,
}

fn uuid_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-f0-9-]{36}$").unwrap())
}

fn mid_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[A-Za-z0-9_-]{1,40}$").unwrap())
}

pub fn encode_direct_invite(invite: &DirectRoomInvite) -> Result<String, CoreError> {
    let json = serde_json::to_vec(invite)
        .map_err(|_| CoreError::InvalidInput("Couldn't encode room code.".into()))?;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(&json)
        .map_err(|_| CoreError::InvalidInput("Couldn't compress room code.".into()))?;
    let compressed = encoder
        .finish()
        .map_err(|_| CoreError::InvalidInput("Couldn't finish room code.".into()))?;
    Ok(format!(
        "{DIRECT_INVITE_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(compressed)
    ))
}

pub fn decode_direct_invite(input: &str, now_ms: i64) -> Result<DirectRoomInvite, CoreError> {
    let code = input.trim();
    let Some(payload) = code.strip_prefix(DIRECT_INVITE_PREFIX) else {
        return Err(CoreError::InvalidInput("Paste a full Interlude code.".into()));
    };
    if code.len() > MAX_DIRECT_CODE_LEN {
        return Err(CoreError::TooLarge("Paste a full Interlude code.".into()));
    }
    let compressed = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| CoreError::InvalidInput("This room code has an unsupported format.".into()))?;
    let mut decoder = GzDecoder::new(&compressed[..]).take((MAX_DIRECT_SDP_BYTES + 1) as u64);
    let mut decompressed = Vec::new();
    decoder
        .read_to_end(&mut decompressed)
        .map_err(|_| CoreError::InvalidInput("This room code has an unsupported format.".into()))?;
    if decompressed.len() > MAX_DIRECT_SDP_BYTES {
        return Err(CoreError::TooLarge("The room code is too large.".into()));
    }
    let invite: DirectRoomInvite = serde_json::from_slice(&decompressed)
        .map_err(|_| CoreError::InvalidInput("This room code has an unsupported format.".into()))?;

    if !uuid_regex().is_match(&invite.room)
        || !matches!(invite.role.as_str(), "offer" | "answer")
        || !invite.sdp.starts_with("v=0")
        || !invite.sdp.contains("m=application")
        || invite.sdp.contains("\nm=video")
    {
        return Err(CoreError::InvalidInput(
            "This room code has an unsupported format.".into(),
        ));
    }
    if now_ms > invite.expires || invite.expires > now_ms + DIRECT_INVITE_LIFETIME_MS + 120_000 {
        return Err(CoreError::Expired(
            "That code expired. Create a new invite.".into(),
        ));
    }
    if invite.ice.len() > 64 {
        return Err(CoreError::TooLarge(
            "The room code has too many connection routes.".into(),
        ));
    }
    for entry in &invite.ice {
        if !mid_regex().is_match(&entry.mid)
            || !(0..=4).contains(&entry.index)
            || !entry.sdp.starts_with("candidate:")
            || entry.sdp.len() > 1000
        {
            return Err(CoreError::InvalidInput("Invalid connection route.".into()));
        }
    }
    Ok(invite)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelaySession {
    pub url: String,
    pub code: String,
    pub voice_key: Option<String>,
}

fn workers_domain_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^[a-z0-9][a-z0-9-]{0,62}\.[a-z0-9][a-z0-9-]{0,62}\.workers\.dev$").unwrap()
    })
}

fn relay_invite_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"^INTERLUDE-R([12]):([a-z0-9][a-z0-9-]{0,62}\.[a-z0-9][a-z0-9-]{0,62}\.workers\.dev):([a-f0-9]{32}):([a-f0-9]{32})(?::([a-f0-9]{64}))?$",
        )
        .unwrap()
    })
}

fn hex64_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-f0-9]{64}$").unwrap())
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

fn random_hex(num_bytes: usize) -> Result<String, CoreError> {
    let mut buf = vec![0u8; num_bytes];
    getrandom::fill(&mut buf)
        .map_err(|_| CoreError::InvalidInput("Couldn't generate secure random bytes.".into()))?;
    Ok(hex_encode(&buf))
}

pub fn is_relay_invite(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.starts_with("INTERLUDE-R1:") || trimmed.starts_with("INTERLUDE-R2:")
}

pub fn join_relay_invite(value: &str) -> Result<RelaySession, CoreError> {
    let trimmed = value.trim();
    let Some(caps) = relay_invite_regex().captures(trimmed) else {
        return Err(CoreError::InvalidInput(
            "Enter a valid Interlude relay invite.".into(),
        ));
    };
    let version = &caps[1];
    let host = &caps[2];
    let room = &caps[3];
    let key = &caps[4];
    let voice_key = caps.get(5).map(|m| m.as_str().to_owned());
    if (version == "2") != voice_key.is_some() {
        return Err(CoreError::InvalidInput(
            "Enter a valid Interlude relay invite.".into(),
        ));
    }
    let suffix = if voice_key.is_some() { "&voice=1" } else { "" };
    Ok(RelaySession {
        url: format!("wss://{host}/rooms/{room}?role=guest&key={key}{suffix}"),
        code: String::new(),
        voice_key,
    })
}

pub fn host_relay_room(address: &str, hosting_key: &str) -> Result<RelaySession, CoreError> {
    let mut host = address.trim().to_ascii_lowercase();
    if let Some(stripped) = host.strip_prefix("https://") {
        host = stripped.to_owned();
    }
    if let Some(stripped) = host.strip_suffix('/') {
        host = stripped.to_owned();
    }
    if !workers_domain_regex().is_match(&host) {
        return Err(CoreError::InvalidInput(
            "Enter your relay’s workers.dev address.".into(),
        ));
    }
    let secret = random_hex(16)?;
    let guest = random_hex(16)?;
    let digest = Sha256::digest(secret.as_bytes());
    let room = hex_encode(&digest[..16]);
    let base_url = format!("wss://{host}/rooms/{room}?role=host&key={secret}&invite={guest}");
    let key_value = hosting_key.trim().to_ascii_lowercase();
    if key_value.is_empty() {
        return Ok(RelaySession {
            url: base_url,
            code: format!("INTERLUDE-R1:{host}:{room}:{guest}"),
            voice_key: None,
        });
    }
    if !hex64_regex().is_match(&key_value) {
        return Err(CoreError::InvalidInput(
            "Enter the 64-character voice hosting key.".into(),
        ));
    }
    type HmacSha256 = Hmac<Sha256>;
    let mut mac = HmacSha256::new_from_slice(key_value.as_bytes())
        .map_err(|_| CoreError::InvalidInput("Enter the 64-character voice hosting key.".into()))?;
    mac.update(format!("interlude-voice:{room}").as_bytes());
    let proof = hex_encode(&mac.finalize().into_bytes());
    let voice_key = random_hex(32)?;
    Ok(RelaySession {
        url: format!("{base_url}&voice=1&proof={proof}"),
        code: format!("INTERLUDE-R2:{host}:{room}:{guest}:{voice_key}"),
        voice_key: Some(voice_key),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomTitle {
    pub kind: String,
    pub id: i32,
    pub name: String,
    pub year: String,
    pub season: Option<i32>,
    pub episode: Option<i32>,
}

fn year_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[0-9]{4}$").unwrap())
}

fn non_alnum_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[^\p{L}\p{N}]+").unwrap())
}

fn ext_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\.[^.]+$").unwrap())
}

fn sample_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?:^| )(?:sample|trailer|extras)(?: |$)").unwrap())
}

fn movie_suffix_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(?:[0-9]{3,4}p|4k|uhd|bluray|web dl|web rip)(?: .*)?$").unwrap())
}

fn normalize_words(value: &str) -> String {
    let stripped: String = value
        .nfd()
        .filter(|&c| !unicode_normalization::char::is_combining_mark(c))
        .collect();
    let lower = stripped.to_lowercase();
    non_alnum_regex().replace_all(&lower, " ").trim().to_owned()
}

pub fn validate_room_title(
    kind: &str,
    id: i32,
    name: &str,
    year: &str,
    season: Option<i32>,
    episode: Option<i32>,
) -> Option<RoomTitle> {
    if id < 1 || name.trim().is_empty() || name.len() > 200 || !matches!(kind, "movie" | "tv") {
        return None;
    }
    let clean_year = if year_regex().is_match(year) {
        year.to_owned()
    } else {
        String::new()
    };
    if kind == "tv" {
        let s = season?;
        let e = episode?;
        if !(0..=999).contains(&s) || !(1..=9999).contains(&e) {
            return None;
        }
        Some(RoomTitle {
            kind: kind.to_owned(),
            id,
            name: name.to_owned(),
            year: clean_year,
            season: Some(s),
            episode: Some(e),
        })
    } else {
        Some(RoomTitle {
            kind: kind.to_owned(),
            id,
            name: name.to_owned(),
            year: clean_year,
            season: None,
            episode: None,
        })
    }
}

pub fn room_title_matches_video(title: &RoomTitle, filename: &str, release: &str) -> bool {
    let clean_title = normalize_words(&title.name);
    let stem = ext_regex().replace(filename, "");
    let clean_file = normalize_words(&stem);
    let clean_folder = normalize_words(release);
    if clean_title.is_empty() || sample_regex().is_match(&clean_file) {
        return false;
    }
    if let (Some(season), Some(episode)) = (title.season, title.episode) {
        let pattern = format!(
            r"(?:^| )(?:s0*{season} *e0*{episode}|0*{season}x0*{episode})(?: |$)"
        );
        let Ok(ep_re) = Regex::new(&pattern) else {
            return false;
        };
        let prefix = format!("{clean_title} ");
        return (clean_file.starts_with(&prefix)
            || clean_folder == clean_title
            || clean_folder.starts_with(&prefix))
            && ep_re.is_match(&clean_file);
    }
    if clean_file == clean_title {
        return true;
    }
    let prefix = format!("{clean_title} ");
    let Some(suffix) = clean_file.strip_prefix(&prefix) else {
        return false;
    };
    (!title.year.is_empty()
        && (suffix == title.year || suffix.starts_with(&format!("{} ", title.year))))
        || movie_suffix_regex().is_match(suffix)
}

#[derive(Default)]
struct BufferGateState {
    holding: bool,
    changed_at: Option<i64>,
}

pub struct BufferGate {
    state: Mutex<BufferGateState>,
}

impl Default for BufferGate {
    fn default() -> Self {
        Self::new()
    }
}

impl BufferGate {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(BufferGateState::default()),
        }
    }

    pub fn update(&self, waiting: bool, now_ms: i64) -> bool {
        let mut s = self.state.lock().unwrap();
        if waiting == s.holding {
            s.changed_at = None;
        } else if let Some(since) = s.changed_at {
            let threshold = if waiting { 1_200 } else { 700 };
            if now_ms - since >= threshold {
                s.holding = waiting;
                s.changed_at = None;
            }
        } else {
            s.changed_at = Some(now_ms);
        }
        s.holding
    }

    pub fn reset(&self) {
        let mut s = self.state.lock().unwrap();
        s.holding = false;
        s.changed_at = None;
    }
}

#[derive(Default)]
struct DriftState {
    last_seek: Option<i64>,
}

pub struct DriftCorrection {
    state: Mutex<DriftState>,
}

impl Default for DriftCorrection {
    fn default() -> Self {
        Self::new()
    }
}

impl DriftCorrection {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(DriftState::default()),
        }
    }

    pub fn should_seek(
        &self,
        drift_ms: i64,
        playing: bool,
        explicit: bool,
        ready: bool,
        now_ms: i64,
    ) -> bool {
        let threshold = if explicit || !playing { 250 } else { 1_400 };
        if drift_ms <= threshold {
            return false;
        }
        let mut s = self.state.lock().unwrap();
        if !explicit && (!ready || s.last_seek.is_some_and(|last| now_ms - last < 3_000)) {
            return false;
        }
        s.last_seek = Some(now_ms);
        true
    }

    pub fn reset(&self) {
        let mut s = self.state.lock().unwrap();
        s.last_seek = None;
    }
}

fn clamp_position(position_ms: i64, duration_ms: i64) -> i64 {
    let bound = if duration_ms > 0 {
        duration_ms
    } else {
        86_400_000
    };
    position_ms.clamp(0, bound)
}

pub fn playback_target_ms(
    position_ms: i64,
    playing: bool,
    elapsed_ms: i64,
    duration_ms: i64,
) -> i64 {
    let clamped = clamp_position(position_ms, duration_ms);
    let delta = if playing {
        elapsed_ms.clamp(0, 2_500)
    } else {
        0
    };
    clamp_position(clamped + delta, duration_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SDP: &str =
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";

    #[test]
    fn direct_invite_round_trip_and_guards() {
        let now = 100_000;
        let room = "12345678-1234-1234-1234-123456789012".to_owned();
        for role in ["offer", "answer"] {
            let invite = DirectRoomInvite {
                room: room.clone(),
                role: role.to_owned(),
                expires: now + DIRECT_INVITE_LIFETIME_MS,
                sdp: SDP.to_owned(),
                ice: vec![IceCandidate {
                    mid: "0".into(),
                    index: 0,
                    sdp: "candidate:1 1 UDP 5 192.0.2.1 5000 typ host".into(),
                }],
            };
            let encoded = encode_direct_invite(&invite).unwrap();
            let decoded = decode_direct_invite(&format!("  {encoded}\n"), now).unwrap();
            assert_eq!(decoded, invite);
        }

        let expired = encode_direct_invite(&DirectRoomInvite {
            room: room.clone(),
            role: "offer".into(),
            expires: 500,
            sdp: SDP.into(),
            ice: vec![],
        })
        .unwrap();
        assert!(decode_direct_invite(&expired, 501).is_err());

        let camera = encode_direct_invite(&DirectRoomInvite {
            room,
            role: "offer".into(),
            expires: 500,
            sdp: format!("{SDP}m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"),
            ice: vec![],
        })
        .unwrap();
        assert!(decode_direct_invite(&camera, 400).is_err());
    }

    #[test]
    fn relay_host_and_join_round_trip() {
        let r1 = host_relay_room("https://my-room.my-acct.workers.dev/", "").unwrap();
        assert!(r1.code.starts_with("INTERLUDE-R1:my-room.my-acct.workers.dev:"));
        assert!(is_relay_invite(&r1.code));
        assert_eq!(r1.voice_key, None);
        let joined = join_relay_invite(&r1.code).unwrap();
        assert!(joined.url.starts_with("wss://my-room.my-acct.workers.dev/rooms/"));
        assert!(joined.url.contains("role=guest"));
        assert_eq!(joined.voice_key, None);

        let key = "0123456789abcdef".repeat(4);
        let r2 = host_relay_room("my-room.my-acct.workers.dev", &key).unwrap();
        assert!(r2.code.starts_with("INTERLUDE-R2:"));
        assert!(r2.url.contains("&voice=1&proof="));
        let joined2 = join_relay_invite(&r2.code).unwrap();
        assert_eq!(joined2.voice_key, r2.voice_key);
        assert!(joined2.url.ends_with("&voice=1"));
    }

    #[test]
    fn buffer_gate_drift_and_target_math() {
        let gate = BufferGate::new();
        assert!(!gate.update(true, 0));
        assert!(!gate.update(false, 500));
        assert!(!gate.update(true, 600));
        assert!(gate.update(true, 1_800));
        assert!(gate.update(false, 2_000));
        assert!(gate.update(true, 2_600));
        assert!(gate.update(false, 2_700));
        assert!(!gate.update(false, 3_400));

        let drift = DriftCorrection::new();
        assert!(!drift.should_seek(900, true, false, true, 0));
        assert!(!drift.should_seek(2_000, true, false, false, 0));
        assert!(drift.should_seek(2_000, true, false, true, 1));
        assert!(!drift.should_seek(2_000, true, false, true, 1_000));
        assert!(drift.should_seek(2_000, true, true, false, 1_000));
        assert!(drift.should_seek(2_000, true, false, true, 4_000));

        assert_eq!(playback_target_ms(1900, true, 300, 8_000), 2200);
        assert_eq!(playback_target_ms(1900, false, 300, 8_000), 1900);
        assert_eq!(playback_target_ms(1900, true, -1, 8_000), 1900);
        assert_eq!(playback_target_ms(7900, true, 500, 8_000), 8_000);
    }

    #[test]
    fn room_title_matching() {
        let title = validate_room_title("tv", 1396, "Breaking Bad", "2008", Some(2), Some(3)).unwrap();
        assert!(room_title_matches_video(
            &title,
            "Breaking.Bad.S02E03.1080p.mkv",
            "Breaking Bad"
        ));
        assert!(!room_title_matches_video(
            &title,
            "Breaking.Bad.S02E04.1080p.mkv",
            "Breaking Bad"
        ));
        assert!(validate_room_title("tv", 1396, "Breaking Bad", "2008", Some(2), Some(0)).is_none());
    }
}
