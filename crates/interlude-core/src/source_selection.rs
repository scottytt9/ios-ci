use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QualityProfile {
    Uhd4k,
    Balanced1080p,
    DataSaver,
}

impl QualityProfile {
    pub fn from_id(value: &str) -> Self {
        if value.eq_ignore_ascii_case("4k") {
            Self::Uhd4k
        } else if value.eq_ignore_ascii_case("saver") {
            Self::DataSaver
        } else {
            Self::Balanced1080p
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Uhd4k => "4k",
            Self::Balanced1080p => "1080p",
            Self::DataSaver => "saver",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseMeta {
    pub clean_title: String,
    pub resolution: Option<String>,
    pub hdr: Option<String>,
    pub audio: Option<String>,
    pub source: Option<String>,
    pub codec: Option<String>,
    pub badges: Vec<String>,
}

struct Patterns {
    separators: Regex,
    avoid: Regex,
    full_hd: Regex,
    ultra_hd: Regex,
    hd: Regex,
    sd: Regex,
    release: Regex,
    bluray: Regex,
    web: Regex,
    avc: Regex,
    hevc: Regex,
    av1: Regex,
    dolby_vision: Regex,
    hdr10_plus: Regex,
    hdr: Regex,
    atmos: Regex,
    truehd: Regex,
    dtshd: Regex,
    ddp: Regex,
    surround: Regex,
    remux: Regex,
    ext: Regex,
    cut_at_tech: Regex,
    spaces: Regex,
    trailing_punct: Regex,
}

fn patterns() -> &'static Patterns {
    static PATS: OnceLock<Patterns> = OnceLock::new();
    PATS.get_or_init(|| Patterns {
        separators: Regex::new(r"[^a-z0-9]+").unwrap(),
        avoid: Regex::new(r"\b(?:cam|camrip|hdcam|telesync|hdts|telecine|sample|trailer|extras)\b")
            .unwrap(),
        full_hd: Regex::new(r"\b(?:1080p|1080i)\b").unwrap(),
        ultra_hd: Regex::new(r"\b(?:2160p|4k|uhd)\b").unwrap(),
        hd: Regex::new(r"\b720p\b").unwrap(),
        sd: Regex::new(r"\b480p\b").unwrap(),
        release: Regex::new(r"\b(?:web|bluray|bdrip|webdl|webrip)\b").unwrap(),
        bluray: Regex::new(r"\b(?:bluray|blu ray|bdrip)\b").unwrap(),
        web: Regex::new(r"\b(?:web dl|webdl|webrip|web)\b").unwrap(),
        avc: Regex::new(r"\b(?:h264|x264|avc)\b").unwrap(),
        hevc: Regex::new(r"\b(?:h265|x265|hevc|av1)\b").unwrap(),
        av1: Regex::new(r"\bav1\b").unwrap(),
        dolby_vision: Regex::new(r"\b(?:dv|dovi|dolby vision)\b").unwrap(),
        hdr10_plus: Regex::new(r"\b(?:hdr10plus|hdr10 plus)\b").unwrap(),
        hdr: Regex::new(r"\b(?:hdr10|hdr10plus|hdr)\b").unwrap(),
        atmos: Regex::new(r"\batmos\b").unwrap(),
        truehd: Regex::new(r"\btruehd\b").unwrap(),
        dtshd: Regex::new(r"\b(?:dts hd|dtshd|dts x|dtsx)\b").unwrap(),
        ddp: Regex::new(r"\b(?:ddp|ddp5|eac3)\b").unwrap(),
        surround: Regex::new(r"\b(?:truehd|dts|dtshd|ddp5|eac3|ac3|aac|5 1|7 1)\b").unwrap(),
        remux: Regex::new(r"\bremux\b").unwrap(),
        ext: Regex::new(r"(?i)\.(mkv|mp4|avi|mov|m4v|webm)$").unwrap(),
        cut_at_tech: Regex::new(
            r"(?i)\b(2160p|4k|uhd|1080p|1080i|720p|480p|web[-. ]?dl|webrip|bluray|bdrip|remux|hdr10\+?|hdr|dovi|dolby|x264|x265|h\.?264|h\.?265|hevc|av1|aac|ddp|eac3|atmos|truehd|dts|10bit)\b.*$",
        )
        .unwrap(),
        spaces: Regex::new(r"\s+").unwrap(),
        trailing_punct: Regex::new(r"[\s(\[\-]+$").unwrap(),
    })
}

pub fn parse_release_meta(raw: &str) -> ReleaseMeta {
    let p = patterns();
    let base = raw
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(raw);
    let base = p.ext.replace(base, "");
    let lower = raw.to_ascii_lowercase();
    let label = p.separators.replace_all(&lower, " ");

    let resolution = if p.ultra_hd.is_match(&label) {
        Some("4K UHD".to_owned())
    } else if p.full_hd.is_match(&label) {
        Some("1080p".to_owned())
    } else if p.hd.is_match(&label) {
        Some("720p".to_owned())
    } else if p.sd.is_match(&label) {
        Some("480p".to_owned())
    } else {
        None
    };

    let hdr = if p.dolby_vision.is_match(&label) {
        Some("Dolby Vision".to_owned())
    } else if lower.contains("hdr10+") || p.hdr10_plus.is_match(&label) {
        Some("HDR10+".to_owned())
    } else if p.hdr.is_match(&label) {
        Some("HDR".to_owned())
    } else {
        None
    };

    let audio = if p.atmos.is_match(&label) {
        Some("Atmos".to_owned())
    } else if p.truehd.is_match(&label) {
        Some("TrueHD".to_owned())
    } else if p.dtshd.is_match(&label) {
        Some("DTS-HD".to_owned())
    } else if lower.contains("dd+") || p.ddp.is_match(&label) {
        Some("Dolby Digital+".to_owned())
    } else if p.surround.is_match(&label) {
        Some("5.1".to_owned())
    } else {
        None
    };

    let source = if p.remux.is_match(&label) {
        Some("Remux".to_owned())
    } else if p.bluray.is_match(&label) {
        Some("Blu-ray".to_owned())
    } else if p.web.is_match(&label) {
        Some("WEB-DL".to_owned())
    } else {
        None
    };

    let codec = if p.av1.is_match(&label) {
        Some("AV1".to_owned())
    } else if p.hevc.is_match(&label) {
        Some("HEVC".to_owned())
    } else if p.avc.is_match(&label) {
        Some("H.264".to_owned())
    } else {
        None
    };

    let mut badges = Vec::new();
    if let Some(ref r) = resolution {
        if r != "480p" {
            badges.push(r.clone());
        }
    }
    if let Some(ref h) = hdr {
        badges.push(h.clone());
    }
    if let Some(ref a) = audio {
        badges.push(a.clone());
    }
    if source.as_deref() == Some("Remux") {
        badges.push("Remux".to_owned());
    } else if codec.as_deref() == Some("HEVC") || codec.as_deref() == Some("AV1") {
        badges.push("HEVC".to_owned());
    } else if let Some(ref s) = source {
        badges.push(s.clone());
    }
    badges.truncate(4);

    let spaced = base.replace(['.', '_'], " ");
    let cut = p.cut_at_tech.replace(&spaced, "");
    let collapsed = p.spaces.replace_all(&cut, " ");
    let cleaned = p.trailing_punct.replace(&collapsed, "").trim().to_owned();
    let fallback = spaced.trim().to_owned();
    let clean_title = if cleaned.len() >= 2 {
        cleaned
    } else if !fallback.is_empty() {
        fallback
    } else {
        raw.to_owned()
    };

    ReleaseMeta {
        clean_title,
        resolution,
        hdr,
        audio,
        source,
        codec,
        badges,
    }
}

pub fn rank_source(name: &str, profile: QualityProfile) -> i32 {
    let p = patterns();
    let lower = name.to_ascii_lowercase();
    let label = p.separators.replace_all(&lower, " ");
    if p.avoid.is_match(&label) {
        return -1;
    }
    let uhd = p.ultra_hd.is_match(&label);
    let fhd = p.full_hd.is_match(&label);
    let hd = p.hd.is_match(&label);
    let mut score = match profile {
        QualityProfile::Uhd4k => {
            let mut s = if uhd {
                50
            } else if fhd {
                38
            } else if hd {
                22
            } else {
                10
            };
            if p.dolby_vision.is_match(&label) || p.hdr.is_match(&label) {
                s += 6;
            }
            if p.atmos.is_match(&label) || p.remux.is_match(&label) {
                s += 4;
            }
            s
        }
        QualityProfile::DataSaver => {
            let mut s = if hd {
                46
            } else if fhd {
                34
            } else if uhd {
                16
            } else {
                24
            };
            if p.hevc.is_match(&label) {
                s += 6;
            }
            s
        }
        QualityProfile::Balanced1080p => {
            if fhd {
                40
            } else if uhd {
                32
            } else if hd {
                24
            } else {
                12
            }
        }
    };
    if p.release.is_match(&label) {
        score += 4;
    }
    if p.avc.is_match(&label) {
        score += 2;
    }
    score
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranks_clean_releases_by_profile() {
        assert_eq!(
            rank_source("Night.Station.S01E02.1080p.HDCAM.mkv", QualityProfile::Balanced1080p),
            -1
        );
        let ultra = rank_source("Night.Station.S01E02.2160p.mkv", QualityProfile::Balanced1080p);
        let full_hd = rank_source(
            "Night.Station.S01E02.1080p.WEB-DL.x264.mkv",
            QualityProfile::Balanced1080p,
        );
        assert!(full_hd > ultra);

        let ultra_4k = rank_source(
            "Night.Station.S01E02.2160p.DV.Atmos.mkv",
            QualityProfile::Uhd4k,
        );
        let fhd_4k = rank_source(
            "Night.Station.S01E02.1080p.WEB-DL.x264.mkv",
            QualityProfile::Uhd4k,
        );
        assert!(ultra_4k > fhd_4k);
    }

    #[test]
    fn parses_release_badges() {
        let meta = parse_release_meta("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265.mkv");
        assert_eq!(meta.clean_title, "Dune Part Two 2024");
        assert_eq!(meta.resolution.as_deref(), Some("4K UHD"));
        assert_eq!(meta.hdr.as_deref(), Some("Dolby Vision"));
        assert_eq!(meta.audio.as_deref(), Some("Atmos"));
    }
}
