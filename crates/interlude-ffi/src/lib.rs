use interlude_core::{
    addons, artwork, captions, catalogue, client, profile, room, source_selection, timeline,
    torbox, CoreError,
};
use std::path::PathBuf;

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum FfiError {
    InvalidInput { detail: String },
    Expired { detail: String },
    TooLarge { detail: String },
    Network { detail: String },
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput { detail }
            | Self::Expired { detail }
            | Self::TooLarge { detail }
            | Self::Network { detail } => write!(f, "{detail}"),
        }
    }
}

impl From<CoreError> for FfiError {
    fn from(value: CoreError) -> Self {
        match value {
            CoreError::InvalidInput(detail) => Self::InvalidInput { detail },
            CoreError::Expired(detail) => Self::Expired { detail },
            CoreError::TooLarge(detail) => Self::TooLarge { detail },
            CoreError::Network(detail) => Self::Network { detail },
        }
    }
}

fn net_err(detail: String) -> FfiError {
    FfiError::Network { detail }
}

#[uniffi::export]
pub fn core_version() -> String {
    interlude_core::core_version()
}

// --- Artwork ---

#[uniffi::export]
pub fn artwork_width(pixels: u32) -> u32 {
    artwork::width(pixels)
}

#[uniffi::export]
pub fn artwork_sized(address: String, pixels: u32) -> String {
    artwork::sized(&address, pixels)
}

#[uniffi::export]
pub fn artwork_preview(address: String) -> Option<String> {
    artwork::preview(&address)
}

#[uniffi::export]
pub fn artwork_smaller(address: String) -> Option<String> {
    artwork::smaller(&address)
}

#[uniffi::export]
pub fn artwork_is_allowed_url(address: String) -> bool {
    artwork::is_allowed_url(&address)
}

// --- External Captions ---

#[derive(uniffi::Object)]
pub struct FfiCaptionTrack {
    inner: captions::CaptionTrack,
}

#[uniffi::export]
impl FfiCaptionTrack {
    #[uniffi::constructor]
    pub fn parse(text: String) -> Result<Self, FfiError> {
        Ok(Self {
            inner: captions::CaptionTrack::parse(&text)?,
        })
    }

    pub fn cue_count(&self) -> u32 {
        self.inner.cue_count()
    }

    pub fn text_at(&self, time_ms: i64) -> String {
        self.inner.text_at(time_ms)
    }
}

// --- Playback Timeline ---

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiIntervalMs {
    pub start_ms: i64,
    pub end_ms: i64,
}

impl From<timeline::IntervalMs> for FfiIntervalMs {
    fn from(v: timeline::IntervalMs) -> Self {
        Self {
            start_ms: v.start_ms,
            end_ms: v.end_ms,
        }
    }
}

impl From<FfiIntervalMs> for timeline::IntervalMs {
    fn from(v: FfiIntervalMs) -> Self {
        Self {
            start_ms: v.start_ms,
            end_ms: v.end_ms,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChapterMark {
    pub title: String,
    pub start_ms: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCommunityTimings {
    pub intro: Option<FfiIntervalMs>,
    pub recap: Option<FfiIntervalMs>,
    pub outro: Option<FfiIntervalMs>,
    pub post_credits: Option<FfiIntervalMs>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiResolvedTimeline {
    pub intro: Option<FfiIntervalMs>,
    pub recap: Option<FfiIntervalMs>,
    pub credits: Option<FfiIntervalMs>,
    pub advance_at_credits: bool,
}

#[uniffi::export]
pub fn resolve_playback_timeline(
    chapters: Vec<FfiChapterMark>,
    duration_ms: i64,
    community: Option<FfiCommunityTimings>,
) -> FfiResolvedTimeline {
    let core_chapters: Vec<timeline::ChapterMark> = chapters
        .into_iter()
        .map(|c| timeline::ChapterMark {
            title: c.title,
            start_ms: c.start_ms,
        })
        .collect();
    let core_comm = community.map(|c| timeline::CommunityTimings {
        intro: c.intro.map(Into::into),
        recap: c.recap.map(Into::into),
        outro: c.outro.map(Into::into),
        post_credits: c.post_credits.map(Into::into),
    });
    let resolved = timeline::resolve_timeline(&core_chapters, duration_ms, core_comm.as_ref());
    FfiResolvedTimeline {
        intro: resolved.intro.map(Into::into),
        recap: resolved.recap.map(Into::into),
        credits: resolved.credits.map(Into::into),
        advance_at_credits: resolved.advance_at_credits,
    }
}

// --- Watch Together / Room ---

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiIceCandidate {
    pub mid: String,
    pub index: i32,
    pub sdp: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDirectRoomInvite {
    pub room: String,
    pub role: String,
    pub expires: i64,
    pub sdp: String,
    pub ice: Vec<FfiIceCandidate>,
}

#[uniffi::export]
pub fn encode_direct_invite(invite: FfiDirectRoomInvite) -> Result<String, FfiError> {
    let core = room::DirectRoomInvite {
        room: invite.room,
        role: invite.role,
        expires: invite.expires,
        sdp: invite.sdp,
        ice: invite
            .ice
            .into_iter()
            .map(|i| room::IceCandidate {
                mid: i.mid,
                index: i.index,
                sdp: i.sdp,
            })
            .collect(),
    };
    Ok(room::encode_direct_invite(&core)?)
}

#[uniffi::export]
pub fn decode_direct_invite(input: String, now_ms: i64) -> Result<FfiDirectRoomInvite, FfiError> {
    let core = room::decode_direct_invite(&input, now_ms)?;
    Ok(FfiDirectRoomInvite {
        room: core.room,
        role: core.role,
        expires: core.expires,
        sdp: core.sdp,
        ice: core
            .ice
            .into_iter()
            .map(|i| FfiIceCandidate {
                mid: i.mid,
                index: i.index,
                sdp: i.sdp,
            })
            .collect(),
    })
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRelaySession {
    pub url: String,
    pub code: String,
    pub voice_key: Option<String>,
}

#[uniffi::export]
pub fn is_relay_invite(value: String) -> bool {
    room::is_relay_invite(&value)
}

#[uniffi::export]
pub fn join_relay_invite(value: String) -> Result<FfiRelaySession, FfiError> {
    let session = room::join_relay_invite(&value)?;
    Ok(FfiRelaySession {
        url: session.url,
        code: session.code,
        voice_key: session.voice_key,
    })
}

#[uniffi::export]
pub fn host_relay_room(address: String, hosting_key: String) -> Result<FfiRelaySession, FfiError> {
    let session = room::host_relay_room(&address, &hosting_key)?;
    Ok(FfiRelaySession {
        url: session.url,
        code: session.code,
        voice_key: session.voice_key,
    })
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiRoomTitle {
    pub kind: String,
    pub id: i32,
    pub name: String,
    pub year: String,
    pub season: Option<i32>,
    pub episode: Option<i32>,
}

#[uniffi::export]
pub fn validate_room_title(
    kind: String,
    id: i32,
    name: String,
    year: String,
    season: Option<i32>,
    episode: Option<i32>,
) -> Option<FfiRoomTitle> {
    room::validate_room_title(&kind, id, &name, &year, season, episode).map(|t| FfiRoomTitle {
        kind: t.kind,
        id: t.id,
        name: t.name,
        year: t.year,
        season: t.season,
        episode: t.episode,
    })
}

#[uniffi::export]
pub fn room_title_matches_video(title: FfiRoomTitle, filename: String, release: String) -> bool {
    let core = room::RoomTitle {
        kind: title.kind,
        id: title.id,
        name: title.name,
        year: title.year,
        season: title.season,
        episode: title.episode,
    };
    room::room_title_matches_video(&core, &filename, &release)
}

#[derive(uniffi::Object)]
pub struct FfiBufferGate {
    inner: room::BufferGate,
}

#[uniffi::export]
impl FfiBufferGate {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: room::BufferGate::new(),
        }
    }

    pub fn update(&self, waiting: bool, now_ms: i64) -> bool {
        self.inner.update(waiting, now_ms)
    }

    pub fn reset(&self) {
        self.inner.reset();
    }
}

#[derive(uniffi::Object)]
pub struct FfiDriftCorrection {
    inner: room::DriftCorrection,
}

#[uniffi::export]
impl FfiDriftCorrection {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: room::DriftCorrection::new(),
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
        self.inner
            .should_seek(drift_ms, playing, explicit, ready, now_ms)
    }

    pub fn reset(&self) {
        self.inner.reset();
    }
}

#[uniffi::export]
pub fn playback_target_ms(
    position_ms: i64,
    playing: bool,
    elapsed_ms: i64,
    duration_ms: i64,
) -> i64 {
    room::playback_target_ms(position_ms, playing, elapsed_ms, duration_ms)
}

// --- Source Selection ---

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiQualityProfile {
    Uhd4k,
    Balanced1080p,
    DataSaver,
}

impl From<FfiQualityProfile> for source_selection::QualityProfile {
    fn from(value: FfiQualityProfile) -> Self {
        match value {
            FfiQualityProfile::Uhd4k => Self::Uhd4k,
            FfiQualityProfile::Balanced1080p => Self::Balanced1080p,
            FfiQualityProfile::DataSaver => Self::DataSaver,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiReleaseMeta {
    pub clean_title: String,
    pub resolution: Option<String>,
    pub hdr: Option<String>,
    pub audio: Option<String>,
    pub source: Option<String>,
    pub codec: Option<String>,
    pub badges: Vec<String>,
}

#[uniffi::export]
pub fn parse_release_meta(raw: String) -> FfiReleaseMeta {
    let m = source_selection::parse_release_meta(&raw);
    FfiReleaseMeta {
        clean_title: m.clean_title,
        resolution: m.resolution,
        hdr: m.hdr,
        audio: m.audio,
        source: m.source,
        codec: m.codec,
        badges: m.badges,
    }
}

#[uniffi::export]
pub fn rank_source(name: String, profile: FfiQualityProfile) -> i32 {
    source_selection::rank_source(&name, profile.into())
}

// --- Profile Sync ---

#[uniffi::export]
pub fn encode_profile_code(document_json: String) -> Result<String, FfiError> {
    Ok(profile::encode_profile_code(&document_json)?)
}

#[uniffi::export]
pub fn decode_profile_code(input: String) -> Result<String, FfiError> {
    Ok(profile::decode_profile_code(&input)?)
}

#[uniffi::export]
pub fn sanitize_profile_json(document_json: String) -> Result<String, FfiError> {
    Ok(profile::sanitize_profile_json(&document_json)?)
}

#[uniffi::export]
pub fn merge_profiles_json(local_json: String, incoming_json: String) -> Result<String, FfiError> {
    Ok(profile::merge_profiles_json(&local_json, &incoming_json)?)
}

// --- Shared Network Client & Two-Level Cache (Phase 2) ---

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiTorBoxSource {
    Torrents,
    Usenet,
    Webdl,
}

impl From<FfiTorBoxSource> for torbox::Source {
    fn from(value: FfiTorBoxSource) -> Self {
        match value {
            FfiTorBoxSource::Torrents => Self::Torrents,
            FfiTorBoxSource::Usenet => Self::Usenet,
            FfiTorBoxSource::Webdl => Self::Webdl,
        }
    }
}

impl From<torbox::Source> for FfiTorBoxSource {
    fn from(value: torbox::Source) -> Self {
        match value {
            torbox::Source::Torrents => Self::Torrents,
            torbox::Source::Usenet => Self::Usenet,
            torbox::Source::Webdl => Self::Webdl,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorBoxFile {
    pub source: FfiTorBoxSource,
    pub download_id: u64,
    pub file_id: u64,
    pub collection: String,
    pub name: String,
    pub bytes: u64,
    pub ready: bool,
    pub hash: Option<String>,
}

impl From<torbox::FileItem> for FfiTorBoxFile {
    fn from(v: torbox::FileItem) -> Self {
        Self {
            source: v.source.into(),
            download_id: v.download_id,
            file_id: v.file_id,
            collection: v.collection,
            name: v.name,
            bytes: v.bytes,
            ready: v.ready,
            hash: v.hash,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorBoxDownload {
    pub source: FfiTorBoxSource,
    pub id: u64,
    pub name: String,
    pub status: String,
    pub progress: Option<f64>,
    pub ready: bool,
}

impl From<torbox::Download> for FfiTorBoxDownload {
    fn from(v: torbox::Download) -> Self {
        Self {
            source: v.source.into(),
            id: v.id,
            name: v.name,
            status: v.status,
            progress: v.progress,
            ready: v.ready,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorBoxLibrary {
    pub files: Vec<FfiTorBoxFile>,
    pub downloads: Vec<FfiTorBoxDownload>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorBoxReceipt {
    pub source: FfiTorBoxSource,
    pub id: Option<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorBoxAttached {
    pub receipt: FfiTorBoxReceipt,
    pub files: Vec<FfiTorBoxFile>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTorrentSource {
    pub hash: String,
    pub file_index: Option<u64>,
    pub filename: Option<String>,
    pub name: String,
    pub description: String,
    pub bytes: Option<u64>,
    pub cached: Option<bool>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSourceResults {
    pub torrents: Vec<FfiTorrentSource>,
    pub cache_warning: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiOnlineSubtitle {
    pub id: String,
    pub lang: String,
    pub label: String,
    pub url: String,
}

impl From<addons::OnlineSubtitle> for FfiOnlineSubtitle {
    fn from(v: addons::OnlineSubtitle) -> Self {
        Self {
            id: v.id,
            lang: v.lang,
            label: v.label,
            url: v.url,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiQueryParam {
    pub key: String,
    pub value: String,
}

#[derive(uniffi::Object)]
pub struct FfiInterludeClient {
    rt: tokio::runtime::Runtime,
    client: client::InterludeClient,
}

#[uniffi::export]
impl FfiInterludeClient {
    #[uniffi::constructor]
    pub fn new(cache_dir: String) -> Result<Self, FfiError> {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|_| net_err("Couldn't start network runtime.".into()))?;
        let client = client::InterludeClient::new(PathBuf::from(cache_dir)).map_err(net_err)?;
        Ok(Self { rt, client })
    }

    pub fn prune_cache(&self) {
        self.client.prune_cache();
    }

    // --- TMDB ---

    pub fn tmdb_verify(&self, secret: String) -> Result<(), FfiError> {
        self.rt
            .block_on(self.client.tmdb_verify(&secret))
            .map_err(net_err)
    }

    pub fn tmdb_feed_json(&self, secret: String, name: String, page: u16) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_feed(&secret, &name, page))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_search_json(
        &self,
        secret: String,
        query: String,
        page: u16,
        kind: Option<String>,
    ) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_search(&secret, &query, page, kind.as_deref()))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn tmdb_discover_json(
        &self,
        secret: String,
        kind: String,
        order: String,
        genre: Option<String>,
        decade: Option<u16>,
        language: Option<String>,
        today: String,
        page: u16,
    ) -> Result<String, FfiError> {
        let filters = catalogue::DiscoveryFilters {
            kind,
            order,
            genre,
            decade,
            language,
            today,
        };
        let value = self
            .rt
            .block_on(self.client.tmdb_discover(&secret, &filters, page))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_title_details_json(
        &self,
        secret: String,
        kind: String,
        id: u32,
    ) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_title_details(&secret, &kind, id))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_collection_json(&self, secret: String, id: u32) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_collection(&secret, id))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_episode_credits_json(
        &self,
        secret: String,
        id: u32,
        season: u16,
        episode: u16,
    ) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_episode_credits(&secret, id, season, episode))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_season_json(
        &self,
        secret: String,
        id: u32,
        number: u16,
    ) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_season(&secret, id, number))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_person_details_json(&self, secret: String, id: u32) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tmdb_person_details(&secret, id))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tmdb_raw_json(
        &self,
        secret: String,
        route: String,
        query: Vec<FfiQueryParam>,
        ttl_secs: u64,
    ) -> Result<String, FfiError> {
        let pairs: Vec<(String, String)> = query.into_iter().map(|p| (p.key, p.value)).collect();
        let value = self
            .rt
            .block_on(self.client.tmdb_raw(&secret, &route, &pairs, ttl_secs))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    // --- TVmaze ---

    pub fn tvmaze_picks_json(&self) -> Result<String, FfiError> {
        let value = self.rt.block_on(self.client.tvmaze_picks()).map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tvmaze_search_json(&self, query: String) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tvmaze_search(&query))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tvmaze_details_json(&self, id: u32) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tvmaze_details(id))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tvmaze_episodes_json(&self, id: u32) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tvmaze_episodes(id))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    pub fn tvmaze_person_credits_json(&self, id: u32) -> Result<String, FfiError> {
        let value = self
            .rt
            .block_on(self.client.tvmaze_person_credits(id))
            .map_err(net_err)?;
        serde_json::to_string(&value).map_err(|e| net_err(e.to_string()))
    }

    // --- TorBox ---

    pub fn torbox_verify(&self, key: String) -> Result<(), FfiError> {
        self.rt
            .block_on(self.client.torbox_verify(&key))
            .map_err(net_err)
    }

    pub fn torbox_library(
        &self,
        key: String,
        refresh: bool,
    ) -> Result<FfiTorBoxLibrary, FfiError> {
        let lib = self
            .rt
            .block_on(self.client.torbox_library(&key, refresh))
            .map_err(net_err)?;
        Ok(FfiTorBoxLibrary {
            files: lib.files.into_iter().map(Into::into).collect(),
            downloads: lib.downloads.into_iter().map(Into::into).collect(),
            warnings: lib.warnings,
        })
    }

    pub fn torbox_add_source(
        &self,
        key: String,
        link: String,
    ) -> Result<FfiTorBoxReceipt, FfiError> {
        let receipt = self
            .rt
            .block_on(self.client.torbox_add_source(&key, &link))
            .map_err(net_err)?;
        Ok(FfiTorBoxReceipt {
            source: receipt.source.into(),
            id: receipt.id,
        })
    }

    pub fn torbox_attach_torrent(
        &self,
        key: String,
        hash: String,
        cached_only: bool,
    ) -> Result<FfiTorBoxAttached, FfiError> {
        let attached = self
            .rt
            .block_on(self.client.torbox_attach_torrent(&key, &hash, cached_only))
            .map_err(net_err)?;
        Ok(FfiTorBoxAttached {
            receipt: FfiTorBoxReceipt {
                source: attached.receipt.source.into(),
                id: attached.receipt.id,
            },
            files: attached.files.into_iter().map(Into::into).collect(),
        })
    }

    pub fn torbox_resolve_playback(
        &self,
        key: String,
        source: FfiTorBoxSource,
        download_id: u64,
        file_id: u64,
    ) -> Result<String, FfiError> {
        let url = self
            .rt
            .block_on(
                self.client
                    .torbox_resolve_playback(&key, source.into(), download_id, file_id),
            )
            .map_err(net_err)?;
        Ok(url.into())
    }

    // --- Add-ons & Online Subtitles ---

    pub fn addon_verify(&self, raw_url: String) -> Result<(), FfiError> {
        self.rt
            .block_on(self.client.addon_verify(&raw_url))
            .map_err(net_err)
    }

    pub fn addon_torrent_sources(
        &self,
        addon_url: String,
        torbox_key: Option<String>,
        kind: String,
        imdb: String,
        season: Option<u16>,
        episode: Option<u16>,
    ) -> Result<FfiSourceResults, FfiError> {
        let res = self
            .rt
            .block_on(self.client.addon_torrent_sources(
                &addon_url,
                torbox_key.as_deref(),
                &kind,
                &imdb,
                season,
                episode,
            ))
            .map_err(net_err)?;
        Ok(FfiSourceResults {
            torrents: res
                .torrents
                .into_iter()
                .map(|t| FfiTorrentSource {
                    hash: t.hash,
                    file_index: t.file_index,
                    filename: t.filename,
                    name: t.name,
                    description: t.description,
                    bytes: t.bytes,
                    cached: t.cached,
                })
                .collect(),
            cache_warning: res.cache_warning,
        })
    }

    pub fn online_subtitles(
        &self,
        kind: String,
        imdb: String,
        season: Option<u16>,
        episode: Option<u16>,
    ) -> Result<Vec<FfiOnlineSubtitle>, FfiError> {
        let subs = self
            .rt
            .block_on(self.client.online_subtitles(&kind, &imdb, season, episode))
            .map_err(net_err)?;
        Ok(subs.into_iter().map(Into::into).collect())
    }

    pub fn download_subtitle(&self, raw_url: String) -> Result<String, FfiError> {
        self.rt
            .block_on(self.client.download_subtitle(&raw_url))
            .map_err(net_err)
    }

    // --- IntroDB Segment Timings ---

    pub fn segment_timings(
        &self,
        imdb: String,
        season: Option<u16>,
        episode: Option<u16>,
    ) -> Result<Option<FfiCommunityTimings>, FfiError> {
        let timings = self
            .rt
            .block_on(self.client.segment_timings(&imdb, season, episode))
            .map_err(net_err)?;
        Ok(timings.map(|t| {
            let comm = t.to_community_timings();
            FfiCommunityTimings {
                intro: comm.intro.map(Into::into),
                recap: comm.recap.map(Into::into),
                outro: comm.outro.map(Into::into),
                post_credits: comm.post_credits.map(Into::into),
            }
        }))
    }
}
