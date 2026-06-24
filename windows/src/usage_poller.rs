//! Background worker that polls Claude subscription usage into [`SharedState`].
//!
//! A single thread owns all writes to `ui.usage`. The tray sets
//! [`SharedState::usage_refresh`] when the popover opens so the worker can fetch
//! promptly without spawning a thread per click.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::claude_usage;
use crate::models::UsageInfo;
use crate::presence_controller::SharedState;

/// Wake interval while waiting for the next scheduled poll or a refresh signal.
const TICK: Duration = Duration::from_secs(1);

/// Keep showing the last good readout through transient failures (macOS parity).
const MAX_STALENESS: Duration = Duration::from_secs(30 * 60);

/// Run until `shared.quit` is set. Intended to be spawned once from [`crate::tray::run`].
pub fn run(shared: Arc<SharedState>) {
    let mut next_poll = Instant::now();
    let mut last_success = Instant::now();
    let mut published: Option<UsageInfo> = None;

    loop {
        if shared.quit.load(Ordering::Relaxed) {
            break;
        }

        let refresh_now = shared.usage_refresh.swap(false, Ordering::Relaxed);
        if refresh_now || Instant::now() >= next_poll {
            match claude_usage::fetch() {
                Some(info) => {
                    publish_usage(&shared, &mut published, Some(info));
                    last_success = Instant::now();
                }
                None if last_success.elapsed() > MAX_STALENESS => {
                    publish_usage(&shared, &mut published, None);
                }
                None => {
                    let stale = published.clone();
                    publish_usage(&shared, &mut published, stale);
                }
            }
            next_poll = Instant::now() + claude_usage::POLL_INTERVAL;
        }

        sleep(TICK);
    }
}

fn publish_usage(shared: &SharedState, published: &mut Option<UsageInfo>, next: Option<UsageInfo>) {
    if published.as_ref() == next.as_ref() {
        return;
    }
    *published = next.clone();
    shared.set_usage(next);
}
