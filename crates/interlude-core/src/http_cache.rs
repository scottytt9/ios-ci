//! Two-level cache for catalogue JSON (TMDB, TVmaze).
//!
//! * Memory: a small LRU of parsed responses, so revisiting a page or title costs no disk or
//!   network work.
//! * Disk: one JSON file per request under the app cache directory, so the catalogue opens
//!   instantly after a restart. Disk work runs on the blocking pool, not on async workers.
//! * Concurrent requests for the same resource share one network call.
//! * Stale-while-revalidate: a recently expired entry is returned immediately while a background
//!   task refreshes it. Older entries wait for the network but are still used if it fails.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

/// How long past its TTL an entry may be served instantly while it refreshes.
const REVALIDATE_WINDOW: Duration = Duration::from_secs(3 * 86400);
/// Parsed responses kept in memory.
const MEMORY_ENTRIES: usize = 400;
/// Disk entries older than this are removed at startup.
const DISK_MAX_AGE: Duration = Duration::from_secs(30 * 86400);
/// Upper bound on disk entries; the least recently written are removed first.
const DISK_MAX_ENTRIES: usize = 6000;

#[derive(Clone)]
struct Entry {
    stored: SystemTime,
    value: Arc<Value>,
    used: u64,
}

#[derive(Default)]
struct Memory {
    entries: HashMap<String, Entry>,
    tick: u64,
}

pub struct HttpCache {
    dir: PathBuf,
    memory: Mutex<Memory>,
    inflight: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    refreshing: Mutex<HashSet<String>>,
}

enum Freshness {
    Fresh,
    Revalidate,
    Expired,
}

fn freshness(stored: SystemTime, ttl: Duration) -> Freshness {
    // A clock moved backwards counts as fresh rather than discarding the entry.
    let age = SystemTime::now().duration_since(stored).unwrap_or_default();
    if age < ttl {
        Freshness::Fresh
    } else if age < ttl + REVALIDATE_WINDOW {
        Freshness::Revalidate
    } else {
        Freshness::Expired
    }
}

impl HttpCache {
    pub fn new(dir: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            dir,
            memory: Mutex::default(),
            inflight: Mutex::default(),
            refreshing: Mutex::default(),
        })
    }

    /// The stable cache key for a provider route and query.
    pub fn key(label: &str, route: &str, query: &[(&str, &str)]) -> String {
        let encoded =
            serde_json::to_vec(&(label, route, query)).expect("serializing a route and query");
        format!("{:x}", Sha256::digest(encoded))
    }

    fn remember(&self, key: &str, stored: SystemTime, value: Arc<Value>) {
        let mut memory = self
            .memory
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        memory.tick += 1;
        let used = memory.tick;
        memory
            .entries
            .insert(key.to_owned(), Entry { stored, value, used });
        if memory.entries.len() > MEMORY_ENTRIES {
            if let Some(oldest) = memory
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.used)
                .map(|(key, _)| key.clone())
            {
                memory.entries.remove(&oldest);
            }
        }
    }

    fn recall(&self, key: &str) -> Option<Entry> {
        let mut memory = self
            .memory
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        memory.tick += 1;
        let tick = memory.tick;
        let entry = memory.entries.get_mut(key)?;
        entry.used = tick;
        Some(entry.clone())
    }

    fn lock_for(&self, key: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut inflight = self
            .inflight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        inflight.entry(key.to_owned()).or_default().clone()
    }

    fn release(&self, key: &str, lock: Arc<tokio::sync::Mutex<()>>) {
        let mut inflight = self
            .inflight
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Two references remain when nobody else waits: the map's and ours.
        if Arc::strong_count(&lock) <= 2 {
            inflight.remove(key);
        }
    }

    fn path(&self, key: &str) -> PathBuf {
        self.dir.join(format!("{key}.json"))
    }

    async fn read_disk(&self, key: &str) -> Option<(SystemTime, Arc<Value>)> {
        let path = self.path(key);
        let (stored, value) = tokio::task::spawn_blocking(move || read_entry(&path))
            .await
            .ok()??;
        let value = Arc::new(value);
        self.remember(key, stored, value.clone());
        Some((stored, value))
    }

    fn store(&self, key: &str, value: Arc<Value>) {
        self.remember(key, SystemTime::now(), value.clone());
        let dir = self.dir.clone();
        let path = self.path(key);
        tokio::task::spawn_blocking(move || write_entry(&dir, &path, &value));
    }

    async fn cached(&self, key: &str) -> Option<(SystemTime, Arc<Value>)> {
        match self.recall(key) {
            Some(entry) => Some((entry.stored, entry.value)),
            None => self.read_disk(key).await,
        }
    }

    /// Returns the response for `request`, using the cache when `ttl` is set.
    pub async fn fetch<F, Fut>(
        self: &Arc<Self>,
        key: String,
        ttl: Option<Duration>,
        load: F,
    ) -> Result<Value, String>
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<Value, String>> + Send + 'static,
    {
        let Some(ttl) = ttl else { return load().await };
        if let Some(entry) = self.recall(&key) {
            if matches!(freshness(entry.stored, ttl), Freshness::Fresh) {
                return Ok((*entry.value).clone());
            }
        }

        let lock = self.lock_for(&key);
        let guard = lock.lock().await;
        let cached = self.cached(&key).await;
        let result = match cached.as_ref().map(|(stored, _)| freshness(*stored, ttl)) {
            Some(Freshness::Fresh) => Ok((*cached.unwrap().1).clone()),
            Some(Freshness::Revalidate) => {
                self.revalidate(key.clone(), load);
                Ok((*cached.unwrap().1).clone())
            }
            Some(Freshness::Expired) | None => match load().await {
                Ok(value) => {
                    self.store(&key, Arc::new(value.clone()));
                    Ok(value)
                }
                // Offline or rate-limited: an old answer beats an error.
                Err(error) => cached.map(|(_, value)| (*value).clone()).ok_or(error),
            },
        };
        drop(guard);
        self.release(&key, lock);
        result
    }

    fn revalidate<F, Fut>(self: &Arc<Self>, key: String, load: F)
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<Value, String>> + Send + 'static,
    {
        {
            let mut refreshing = self
                .refreshing
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if !refreshing.insert(key.clone()) {
                return;
            }
        }
        let cache = self.clone();
        tokio::spawn(async move {
            if let Ok(value) = load().await {
                cache.store(&key, Arc::new(value));
            }
            cache
                .refreshing
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&key);
        });
    }

    /// Removes old, excess and leftover temporary files. Runs on a blocking thread at startup.
    pub fn prune(&self) {
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return;
        };
        let now = SystemTime::now();
        let mut kept = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            let modified = entry
                .metadata()
                .and_then(|meta| meta.modified())
                .unwrap_or(now);
            let age = now.duration_since(modified).unwrap_or_default();
            let temporary = path.extension().is_some_and(|ext| ext == "tmp");
            if (temporary && age > Duration::from_secs(3600)) || age > DISK_MAX_AGE {
                let _ = fs::remove_file(&path);
            } else if !temporary {
                kept.push((modified, path));
            }
        }
        if kept.len() > DISK_MAX_ENTRIES {
            kept.sort_by_key(|(modified, _)| *modified);
            for (_, path) in &kept[..kept.len() - DISK_MAX_ENTRIES] {
                let _ = fs::remove_file(path);
            }
        }
    }
}

fn read_entry(path: &Path) -> Option<(SystemTime, Value)> {
    let file = fs::File::open(path).ok()?;
    let stored = file.metadata().ok()?.modified().ok()?;
    let value = serde_json::from_reader(std::io::BufReader::new(file)).ok()?;
    Some((stored, value))
}

fn write_entry(dir: &Path, path: &Path, value: &Value) {
    let _ = fs::create_dir_all(dir);
    let temp = path.with_extension(format!(
        "{}-{}.tmp",
        std::process::id(),
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let write = fs::File::create(&temp).and_then(|file| {
        let mut writer = std::io::BufWriter::new(file);
        serde_json::to_writer(&mut writer, value)?;
        writer.flush()
    });
    if write.is_err() || fs::rename(&temp, path).is_err() {
        let _ = fs::remove_file(&temp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn cache() -> Arc<HttpCache> {
        let dir = std::env::temp_dir().join(format!(
            "interlude-core-cache-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        HttpCache::new(dir)
    }

    fn counted(
        calls: &Arc<AtomicUsize>,
        value: Value,
    ) -> impl FnOnce() -> std::future::Ready<Result<Value, String>> + Send + 'static {
        let calls = calls.clone();
        move || {
            calls.fetch_add(1, Ordering::SeqCst);
            std::future::ready(Ok(value))
        }
    }

    #[tokio::test]
    async fn fresh_entries_are_served_from_memory() {
        let cache = cache();
        let calls = Arc::new(AtomicUsize::new(0));
        let ttl = Some(Duration::from_secs(60));
        let first = cache
            .fetch("k".into(), ttl, counted(&calls, json!({"page": 1})))
            .await
            .unwrap();
        let second = cache
            .fetch("k".into(), ttl, counted(&calls, json!({"page": 2})))
            .await
            .unwrap();
        assert_eq!(first, json!({"page": 1}));
        assert_eq!(second, json!({"page": 1}));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn concurrent_requests_share_one_load() {
        let cache = cache();
        let calls = Arc::new(AtomicUsize::new(0));
        let ttl = Some(Duration::from_secs(60));
        let slow = |calls: Arc<AtomicUsize>| {
            move || async move {
                calls.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(50)).await;
                Ok::<_, String>(json!(1))
            }
        };
        let (a, b, c) = tokio::join!(
            cache.fetch("same".into(), ttl, slow(calls.clone())),
            cache.fetch("same".into(), ttl, slow(calls.clone())),
            cache.fetch("same".into(), ttl, slow(calls.clone())),
        );
        assert_eq!((a.unwrap(), b.unwrap(), c.unwrap()), (json!(1), json!(1), json!(1)));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(cache.inflight.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn recently_expired_entries_are_returned_and_refreshed() {
        let cache = cache();
        let key = "stale".to_owned();
        cache.remember(
            &key,
            SystemTime::now() - Duration::from_secs(120),
            Arc::new(json!("old")),
        );
        let calls = Arc::new(AtomicUsize::new(0));
        let ttl = Some(Duration::from_secs(60));
        let served = cache
            .fetch(key.clone(), ttl, counted(&calls, json!("new")))
            .await
            .unwrap();
        assert_eq!(served, json!("old"));
        for _ in 0..50 {
            if cache
                .recall(&key)
                .is_some_and(|entry| *entry.value == json!("new"))
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            cache
                .fetch(key, ttl, counted(&calls, json!("newer")))
                .await
                .unwrap(),
            json!("new")
        );
    }

    #[tokio::test]
    async fn expired_entries_are_used_when_the_network_fails() {
        let cache = cache();
        let key = "offline".to_owned();
        cache.remember(
            &key,
            SystemTime::now() - REVALIDATE_WINDOW * 2,
            Arc::new(json!("saved")),
        );
        let failing = || std::future::ready(Err::<Value, _>("offline".to_owned()));
        let served = cache
            .fetch(key, Some(Duration::from_secs(60)), failing)
            .await
            .unwrap();
        assert_eq!(served, json!("saved"));
    }

    #[tokio::test]
    async fn entries_survive_a_restart_on_disk() {
        let first = cache();
        let calls = Arc::new(AtomicUsize::new(0));
        let ttl = Some(Duration::from_secs(60));
        first
            .fetch("disk".into(), ttl, counted(&calls, json!([1, 2])))
            .await
            .unwrap();
        let path = first.path("disk");
        for _ in 0..100 {
            if path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let second = HttpCache::new(first.dir.clone());
        let value = second
            .fetch("disk".into(), ttl, counted(&calls, json!("network")))
            .await
            .unwrap();
        assert_eq!(value, json!([1, 2]));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let _ = fs::remove_dir_all(&first.dir);
    }

    #[test]
    fn memory_stays_bounded() {
        let cache = cache();
        for index in 0..(MEMORY_ENTRIES + 25) {
            cache.remember(
                &index.to_string(),
                SystemTime::now(),
                Arc::new(json!(index)),
            );
        }
        assert_eq!(cache.memory.lock().unwrap().entries.len(), MEMORY_ENTRIES);
        assert!(cache.recall("0").is_none());
        assert!(cache.recall(&(MEMORY_ENTRIES + 24).to_string()).is_some());
    }
}
