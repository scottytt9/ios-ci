use regex::Regex;
use std::sync::OnceLock;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IntervalMs {
    pub start_ms: i64,
    pub end_ms: i64,
}

impl IntervalMs {
    fn fitted(self, duration_ms: i64) -> Option<Self> {
        if self.start_ms >= 0
            && self.end_ms - self.start_ms >= 2_000
            && self.end_ms <= duration_ms + 8_000
            && self.start_ms < duration_ms
        {
            Some(Self {
                start_ms: self.start_ms,
                end_ms: self.end_ms.min(duration_ms),
            })
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChapterMark {
    pub title: String,
    pub start_ms: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CommunityTimings {
    pub intro: Option<IntervalMs>,
    pub recap: Option<IntervalMs>,
    pub outro: Option<IntervalMs>,
    pub post_credits: Option<IntervalMs>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedTimeline {
    pub intro: Option<IntervalMs>,
    pub recap: Option<IntervalMs>,
    pub credits: Option<IntervalMs>,
    pub advance_at_credits: bool,
}

fn opening_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(?:(?:intro(?:duction)?|opening)(?: (?:credits|theme|sequence))?|title sequence|op)$")
            .unwrap()
    })
}

fn recap_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(?:recap|previously on(?: .+)?|previous episode recap|last time(?: on .+)?)$")
            .unwrap()
    })
}

fn ending_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(?:(?:(?:end|ending|closing|final) )?credits(?: roll)?|outro|ending theme|ed)$")
            .unwrap()
    })
}

fn dash_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[-_]+").unwrap())
}

fn space_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").unwrap())
}

fn matches_chapter(chapter: &ChapterMark, pattern: &Regex) -> bool {
    let normalized: String = chapter.title.nfkc().collect::<String>().to_lowercase();
    let spaced = dash_regex().replace_all(&normalized, " ");
    let collapsed = space_regex().replace_all(spaced.trim(), " ");
    pattern.is_match(&collapsed)
}

fn chapter_interval(ordered: &[ChapterMark], pattern: &Regex) -> Option<IntervalMs> {
    for i in 0..ordered.len().saturating_sub(1) {
        let chapter = &ordered[i];
        let end_ms = ordered[i + 1].start_ms;
        if matches_chapter(chapter, pattern) && end_ms > chapter.start_ms + 1_000 {
            return Some(IntervalMs {
                start_ms: chapter.start_ms,
                end_ms,
            });
        }
    }
    None
}

pub fn resolve_timeline(
    chapters: &[ChapterMark],
    duration_ms: i64,
    community: Option<&CommunityTimings>,
) -> ResolvedTimeline {
    if duration_ms <= 0 {
        return ResolvedTimeline {
            intro: None,
            recap: None,
            credits: None,
            advance_at_credits: false,
        };
    }

    let mut ordered: Vec<ChapterMark> = chapters
        .iter()
        .filter(|c| c.start_ms >= 0 && c.start_ms < duration_ms)
        .cloned()
        .collect();
    ordered.sort_by_key(|c| c.start_ms);

    let mut intro = chapter_interval(&ordered, opening_regex());
    let mut recap = chapter_interval(&ordered, recap_regex());
    let mut credits: Option<IntervalMs> = None;
    let mut after_credits = false;

    for i in 0..ordered.len() {
        if credits.is_none() && matches_chapter(&ordered[i], ending_regex()) {
            let mut end_ms = duration_ms;
            for later in &ordered[i + 1..] {
                if !matches_chapter(later, ending_regex()) {
                    end_ms = later.start_ms;
                    after_credits = true;
                    break;
                }
            }
            credits = Some(IntervalMs {
                start_ms: ordered[i].start_ms,
                end_ms,
            });
        }
    }

    if let Some(comm) = community {
        let outro_aligned = match comm.outro {
            None => true,
            Some(outro) => {
                let reference_end = comm.post_credits.map(|p| p.end_ms).unwrap_or(outro.end_ms);
                (reference_end - duration_ms).abs() <= 8_000
            }
        };
        if outro_aligned {
            if intro.is_none() {
                if let Some(c_intro) = comm.intro {
                    if c_intro.end_ms - c_intro.start_ms <= 300_000 {
                        intro = c_intro.fitted(duration_ms);
                    }
                }
            }
            if recap.is_none() {
                if let Some(c_recap) = comm.recap {
                    if c_recap.end_ms - c_recap.start_ms <= 300_000 {
                        recap = c_recap.fitted(duration_ms);
                    }
                }
            }
            if credits.is_none() {
                if let Some(c_outro) = comm.outro {
                    credits = c_outro.fitted(duration_ms);
                }
            }
        }
    }

    let has_community_post = community.and_then(|c| c.post_credits).is_some();
    let advance_at_credits = match credits {
        Some(c) => {
            !after_credits
                && !has_community_post
                && (duration_ms - c.end_ms) <= 8_000
                && (c.start_ms as f64) >= (duration_ms as f64) * 0.55
                && (duration_ms - c.start_ms) <= 900_000
        }
        None => false,
    };

    if let (Some(r), Some(i)) = (recap, intro) {
        if i.start_ms > r.start_ms {
            let end_ms = r.end_ms.min(i.start_ms);
            recap = if end_ms > r.start_ms + 1_000 {
                Some(IntervalMs {
                    start_ms: r.start_ms,
                    end_ms,
                })
            } else {
                None
            };
        }
    }

    ResolvedTimeline {
        intro,
        recap,
        credits,
        advance_at_credits,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn waits_for_post_credits_and_rejects_other_cuts() {
        let chapters = vec![
            ChapterMark {
                title: "Opening credits".into(),
                start_ms: 20_000,
            },
            ChapterMark {
                title: "Part 1".into(),
                start_ms: 60_000,
            },
            ChapterMark {
                title: "End credits".into(),
                start_ms: 3_450_000,
            },
        ];
        let tl = resolve_timeline(&chapters, 3_600_000, None);
        assert_eq!(
            tl.intro,
            Some(IntervalMs {
                start_ms: 20_000,
                end_ms: 60_000
            })
        );
        assert!(tl.advance_at_credits);

        let mut with_stinger = chapters.clone();
        with_stinger.push(ChapterMark {
            title: "Epilogue".into(),
            start_ms: 3_540_000,
        });
        let tl = resolve_timeline(&with_stinger, 3_600_000, None);
        assert_eq!(tl.credits.unwrap().end_ms, 3_540_000);
        assert!(!tl.advance_at_credits);

        let other_cut = CommunityTimings {
            intro: Some(IntervalMs {
                start_ms: 30_000,
                end_ms: 70_000,
            }),
            recap: Some(IntervalMs {
                start_ms: 0,
                end_ms: 40_000,
            }),
            outro: Some(IntervalMs {
                start_ms: 3_150_000,
                end_ms: 3_300_000,
            }),
            post_credits: None,
        };
        let tl = resolve_timeline(&[], 3_600_000, Some(&other_cut));
        assert_eq!(tl.intro, None);
        assert_eq!(tl.recap, None);
        assert!(!tl.advance_at_credits);

        let comm_recap = CommunityTimings {
            recap: Some(IntervalMs {
                start_ms: 0,
                end_ms: 28_000,
            }),
            ..Default::default()
        };
        let tl = resolve_timeline(&chapters, 3_600_000, Some(&comm_recap));
        assert_eq!(
            tl.recap,
            Some(IntervalMs {
                start_ms: 0,
                end_ms: 20_000
            })
        );

        let mut chapter_recap = chapters;
        chapter_recap.push(ChapterMark {
            title: "Previously on Interlude".into(),
            start_ms: 0,
        });
        let tl = resolve_timeline(&chapter_recap, 3_600_000, None);
        assert_eq!(
            tl.recap,
            Some(IntervalMs {
                start_ms: 0,
                end_ms: 20_000
            })
        );
    }
}
