use regex::Regex;
use std::sync::OnceLock;

/// TMDB widths, narrowest first. TMDB serves every width for any image.
pub const WIDTHS: [u32; 8] = [92, 154, 185, 300, 342, 500, 780, 1280];

fn tmdb_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)^https://image\.tmdb\.org/t/p/(w\d+|h\d+|original)(/[A-Za-z0-9_.-]+\.(?:jpe?g|png|webp))$",
        )
        .unwrap()
    })
}

fn tvmaze_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^https://static\.tvmaze\.com/(uploads/images/[A-Za-z0-9_./-]+)$").unwrap()
    })
}

fn match_tmdb(address: &str) -> Option<(&str, &str)> {
    let caps = tmdb_regex().captures(address)?;
    let size = caps.get(1)?.as_str();
    let file = caps.get(2)?.as_str();
    if file.contains("..") {
        return None;
    }
    Some((size, file))
}

fn width_of(size: &str) -> u32 {
    if let Some(rest) = size.strip_prefix('w').or_else(|| size.strip_prefix('W')) {
        rest.parse::<u32>().unwrap_or(2000)
    } else {
        2000
    }
}

/// The narrowest TMDB width that is sharp at `pixels`, capped at 1280.
pub fn width(pixels: u32) -> u32 {
    let threshold = (pixels as f64) * 0.92;
    for &candidate in &WIDTHS {
        if (candidate as f64) >= threshold {
            return candidate;
        }
    }
    WIDTHS[WIDTHS.len() - 1]
}

/// The smallest TMDB rendition string (`w92`..`w1280`) for `css_width` at `device_pixel_ratio`.
pub fn rendition_for(css_width: f64, device_pixel_ratio: f64) -> String {
    let ratio = if device_pixel_ratio.is_finite() {
        device_pixel_ratio.clamp(1.0, 2.5)
    } else {
        1.0
    };
    let pixels = (css_width.max(0.0) * ratio).round() as u32;
    format!("w{}", width(pixels))
}

/// `address` resized for a view `pixels` wide. Non-TMDB or invalid addresses are returned unchanged.
pub fn sized(address: &str, pixels: u32) -> String {
    match match_tmdb(address) {
        Some((_, file)) => format!("https://image.tmdb.org/t/p/w{}{file}", width(pixels)),
        None => address.to_owned(),
    }
}

/// A tiny `w92` rendition to show while a large one loads, or `None` when it wouldn't help.
pub fn preview(address: &str) -> Option<String> {
    let (size, file) = match_tmdb(address)?;
    if width_of(size) >= 300 {
        Some(format!("https://image.tmdb.org/t/p/w92{file}"))
    } else {
        None
    }
}

/// Roughly 60% of the width of `address` for slow/failing connections, or `None` when already small.
pub fn smaller(address: &str) -> Option<String> {
    let (size, file) = match_tmdb(address)?;
    let current = width_of(size);
    let mut best = 0;
    for &candidate in &WIDTHS {
        if (candidate as f64) <= (current as f64) * 0.62 && candidate >= 154 {
            best = candidate;
        }
    }
    if best == 0 || best >= current {
        None
    } else {
        Some(format!("https://image.tmdb.org/t/p/w{best}{file}"))
    }
}

/// Validates that `address` is an HTTPS TMDB or TVmaze artwork URL without path traversal.
pub fn is_allowed_url(address: &str) -> bool {
    if match_tmdb(address).is_some() {
        return true;
    }
    if let Some(caps) = tvmaze_regex().captures(address) {
        let path = caps.get(1).map(|m| m.as_str()).unwrap_or("");
        return !path.contains("..");
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    const POSTER: &str = "https://image.tmdb.org/t/p/w500/qJ2tW6WMUDux911r6m7haRef0WH.jpg";

    #[test]
    fn narrowest_sharp_width() {
        assert_eq!(width(60), 92);
        assert_eq!(width(180), 185);
        assert_eq!(width(330), 342);
        assert_eq!(width(1440), 1280);
    }

    #[test]
    fn resizes_only_valid_tmdb() {
        assert_eq!(
            sized(POSTER, 170),
            "https://image.tmdb.org/t/p/w185/qJ2tW6WMUDux911r6m7haRef0WH.jpg"
        );
        assert_eq!(
            sized("https://image.tmdb.org/t/p/original/b.png", 1300),
            "https://image.tmdb.org/t/p/w1280/b.png"
        );
        let tvmaze = "https://static.tvmaze.com/uploads/images/medium_portrait/610/1525272.jpg";
        assert_eq!(sized(tvmaze, 300), tvmaze);
        let unsafe_url = "https://image.tmdb.org/t/p/w500/../x.jpg";
        assert_eq!(sized(unsafe_url, 300), unsafe_url);
        assert!(!is_allowed_url("http://image.tmdb.org/t/p/w500/a.jpg"));
        assert!(is_allowed_url(tvmaze));
    }

    #[test]
    fn preview_and_smaller_fallback() {
        assert_eq!(
            preview(POSTER).as_deref(),
            Some("https://image.tmdb.org/t/p/w92/qJ2tW6WMUDux911r6m7haRef0WH.jpg")
        );
        assert_eq!(preview("https://image.tmdb.org/t/p/w185/a.jpg"), None);
        assert_eq!(preview("https://static.tvmaze.com/uploads/images/a.jpg"), None);

        assert_eq!(
            smaller("https://image.tmdb.org/t/p/w1280/a.jpg").as_deref(),
            Some("https://image.tmdb.org/t/p/w780/a.jpg")
        );
        assert_eq!(
            smaller("https://image.tmdb.org/t/p/w342/a.jpg").as_deref(),
            Some("https://image.tmdb.org/t/p/w185/a.jpg")
        );
        assert_eq!(
            smaller("https://image.tmdb.org/t/p/w500/a.jpg").as_deref(),
            Some("https://image.tmdb.org/t/p/w300/a.jpg")
        );
        assert_eq!(smaller("https://image.tmdb.org/t/p/w185/a.jpg"), None);
        assert_eq!(
            smaller("https://image.tmdb.org/t/p/original/a.jpg").as_deref(),
            Some("https://image.tmdb.org/t/p/w780/a.jpg")
        );
    }
}
