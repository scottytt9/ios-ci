use crate::CoreError;
use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptionCue {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct CaptionTrack {
    cues: Vec<CaptionCue>,
    prefix_max_end: Vec<i64>,
}

fn block_split_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\n[ \t]*\n").unwrap())
}

fn tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]+>").unwrap())
}

fn timestamp_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(?:([0-9]{1,3}):)?([0-9]{2}):([0-9]{2})[.,]([0-9]{3})$").unwrap())
}

fn parse_timestamp_ms(value: &str) -> Option<i64> {
    let caps = timestamp_regex().captures(value)?;
    let hours: i64 = match caps.get(1) {
        Some(m) => m.as_str().parse::<i64>().ok()?,
        None => 0,
    };
    let minutes: i64 = caps.get(2)?.as_str().parse().ok()?;
    let seconds: i64 = caps.get(3)?.as_str().parse().ok()?;
    let millis: i64 = caps.get(4)?.as_str().parse().ok()?;
    if seconds >= 60 || minutes >= 60 {
        return None;
    }
    Some((hours * 3600 + minutes * 60 + seconds) * 1000 + millis)
}

impl CaptionTrack {
    pub fn parse(text: &str) -> Result<Self, CoreError> {
        let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
        let mut cues = Vec::new();
        for block in block_split_regex().split(&normalized) {
            let lines: Vec<&str> = block.split('\n').collect();
            if lines.is_empty()
                || lines[0].starts_with("NOTE")
                || lines[0] == "STYLE"
                || lines[0] == "REGION"
            {
                continue;
            }
            for i in 0..lines.len().saturating_sub(1) {
                let Some((left, right)) = lines[i].split_once("-->") else {
                    continue;
                };
                let start = parse_timestamp_ms(left.trim());
                let end = right
                    .trim()
                    .split_whitespace()
                    .next()
                    .and_then(parse_timestamp_ms);
                if let (Some(start_ms), Some(end_ms)) = (start, end) {
                    if start_ms >= 0 && end_ms > start_ms {
                        let raw = lines[i + 1..].join("\n");
                        let stripped = tag_regex().replace_all(&raw, "");
                        let decoded = stripped
                            .replace("&amp;", "&")
                            .replace("&lt;", "<")
                            .replace("&gt;", ">")
                            .replace("&nbsp;", " ");
                        let trimmed = decoded.trim();
                        if !trimmed.is_empty() {
                            let truncated: String = trimmed.chars().take(1000).collect();
                            cues.push(CaptionCue {
                                start_ms,
                                end_ms,
                                text: truncated,
                            });
                        }
                    }
                }
                break;
            }
            if cues.len() >= 50_000 {
                break;
            }
        }
        if cues.is_empty() {
            return Err(CoreError::InvalidInput(
                "Choose an SRT or WebVTT file with readable captions.".into(),
            ));
        }
        cues.sort_by_key(|cue| cue.start_ms);
        let mut prefix_max_end = Vec::with_capacity(cues.len());
        let mut latest = 0i64;
        for cue in &cues {
            latest = latest.max(cue.end_ms);
            prefix_max_end.push(latest);
        }
        Ok(Self {
            cues,
            prefix_max_end,
        })
    }

    pub fn cue_count(&self) -> u32 {
        self.cues.len() as u32
    }

    pub fn cues(&self) -> &[CaptionCue] {
        &self.cues
    }

    pub fn text_at(&self, time_ms: i64) -> String {
        let mut lo = 0usize;
        let mut hi = self.cues.len();
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.cues[mid].start_ms <= time_ms {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        let mut output = Vec::new();
        let mut idx = lo;
        while idx > 0 {
            idx -= 1;
            if self.prefix_max_end[idx] <= time_ms || output.len() >= 6 {
                break;
            }
            let cue = &self.cues[idx];
            if cue.end_ms > time_ms {
                output.push(cue.text.as_str());
            }
        }
        output.reverse();
        output.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_srt_and_vtt_with_overlapping_cues() {
        let srt = "1\r\n00:00:01,000 --> 00:00:08,000\r\n<i>First</i>\r\n\r\n2\r\n00:00:03,000 --> 00:00:06,000\r\nSecond\r\n";
        let track = CaptionTrack::parse(srt).unwrap();
        assert_eq!(track.text_at(900), "");
        assert_eq!(track.text_at(3000), "First\nSecond");
        assert_eq!(track.text_at(6000), "First");
        assert_eq!(track.text_at(8000), "");

        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:center\nReady.\n";
        let track = CaptionTrack::parse(vtt).unwrap();
        assert_eq!(track.text_at(1500), "Ready.");
    }
}
