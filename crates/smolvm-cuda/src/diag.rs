//! Opt-in stall/wedge diagnostics for the CUDA-RPC transport (issue #667).
//!
//! The intermittent cold-load wedge freezes GPU work and guest disk I/O at the
//! same tick with no host `Xid`. The plain guest-side `SMOLVM_CUDA_SHIM_TRACE`
//! is `eprintln!` from inside the guest, so when the guest wedges its stderr is
//! never drained and the last forwarded call is lost. These hooks are designed
//! to survive that:
//!
//! - `SMOLVM_CUDA_STALL_MS=<ms>` — when a transport **spin-wait** (ring push /
//!   response wait, on either side) exceeds `<ms>`, log a `[ring-stall …]` line
//!   and repeat every `<ms>` while stuck. A spinning thread is *alive*, so this
//!   fires even when the guest is otherwise wedged — exactly the case plain
//!   stderr trace misses.
//! - `SMOLVM_CUDA_STALL_FILE=<path>` — also append every diag line to `<path>`,
//!   flushed per line, for when stderr itself isn't drained. Default: stderr.
//! - `SMOLVM_CUDA_WATCHDOG_MS=<ms>` — spawn a host watchdog thread that logs
//!   `[watchdog] dispatch stuck …` when a single dispatched op (a forwarded
//!   CUDA call) stays in flight longer than `<ms>`. That catches a hang *inside*
//!   a call, which no spin-wait would show.
//!
//! Everything is OFF unless its env var is set, and the hot path pays at most
//! one cached load + branch when off.

use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

/// Process-monotonic clock base, so every diag line shares one timeline.
fn now_ms() -> u64 {
    static BASE: OnceLock<Instant> = OnceLock::new();
    BASE.get_or_init(Instant::now).elapsed().as_millis() as u64
}

fn env_u64(key: &str) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Spin-wait stall threshold in ms (0 = disabled). Cached.
fn stall_ms() -> u64 {
    static V: OnceLock<u64> = OnceLock::new();
    *V.get_or_init(|| env_u64("SMOLVM_CUDA_STALL_MS"))
}

/// Host dispatch watchdog threshold in ms (0 = disabled). Cached.
fn watchdog_ms() -> u64 {
    static V: OnceLock<u64> = OnceLock::new();
    *V.get_or_init(|| env_u64("SMOLVM_CUDA_WATCHDOG_MS"))
}

/// Optional durable sink path for diag lines. Cached.
fn stall_file() -> Option<&'static std::path::Path> {
    static P: OnceLock<Option<std::path::PathBuf>> = OnceLock::new();
    P.get_or_init(|| std::env::var_os("SMOLVM_CUDA_STALL_FILE").map(Into::into))
        .as_deref()
}

/// Emit one diag line to stderr and (if configured) append+flush it to the
/// durable sink. Called only when a threshold has already tripped, so the I/O
/// cost is off the hot path.
fn emit(line: &str) {
    eprintln!("{line}");
    if let Some(path) = stall_file() {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(f, "{line}");
            let _ = f.flush();
        }
    }
}

/// Watches a single spin-wait loop. Construct once before the loop, call
/// [`StallWatch::tick`] every spin. Near-free when `SMOLVM_CUDA_STALL_MS` is
/// unset (one branch per tick); when set it samples the clock only every 64k
/// spins, so a hot ring pays a bounded, coarse cost.
pub struct StallWatch {
    threshold: u64,
    site: &'static str,
    detail: u64,
    spins: u64,
    start_ms: Option<u64>,
    next_log_ms: u64,
}

impl StallWatch {
    #[inline]
    pub fn new(site: &'static str) -> Self {
        Self::with_detail(site, 0)
    }

    /// `detail` is an opaque per-site value (e.g. the op byte or frame len)
    /// echoed in the log to identify which op the wait is blocked on.
    #[inline]
    pub fn with_detail(site: &'static str, detail: u64) -> Self {
        StallWatch {
            threshold: stall_ms(),
            site,
            detail,
            spins: 0,
            start_ms: None,
            next_log_ms: 0,
        }
    }

    #[inline]
    pub fn tick(&mut self) {
        if self.threshold == 0 {
            return;
        }
        // Spins are ~ns; the threshold is coarse ms. Sample the clock sparsely
        // so an enabled run doesn't syscall on every iteration.
        self.spins = self.spins.wrapping_add(1);
        if self.spins & 0xFFFF != 0 {
            return;
        }
        let t = now_ms();
        match self.start_ms {
            None => {
                self.start_ms = Some(t);
                self.next_log_ms = t + self.threshold;
            }
            Some(start) => {
                if t >= self.next_log_ms {
                    emit(&format!(
                        "[ring-stall] site={} waited_ms={} detail=0x{:x} pid={}",
                        self.site,
                        t.saturating_sub(start),
                        self.detail,
                        std::process::id()
                    ));
                    self.next_log_ms = t + self.threshold;
                }
            }
        }
    }
}

// --- Host dispatch watchdog -------------------------------------------------
//
// A forwarded CUDA call that hangs on the GPU blocks the host dispatch thread
// *inside* the call — it isn't spinning, so it can't log itself. A separate
// watchdog thread samples the last dispatch start/end and reports a call that
// never returns.

static WD_OP: AtomicU8 = AtomicU8::new(0);
/// ms timestamp of the in-flight dispatch's start; 0 = idle.
static WD_START_MS: AtomicU64 = AtomicU64::new(0);
/// ms timestamp of the last dispatch completion.
static WD_END_MS: AtomicU64 = AtomicU64::new(0);

/// Spawn the host watchdog thread once, if `SMOLVM_CUDA_WATCHDOG_MS` is set.
/// Safe to call on every connection — the spawn happens at most once.
pub fn ensure_watchdog() {
    let ms = watchdog_ms();
    if ms == 0 {
        return;
    }
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let poll = ms.clamp(50, 1000);
        let _ = std::thread::Builder::new()
            .name("cuda-watchdog".into())
            .spawn(move || {
                let mut next_report_ms = 0u64;
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(poll));
                    let start = WD_START_MS.load(Ordering::Relaxed);
                    let end = WD_END_MS.load(Ordering::Relaxed);
                    // Idle (no op in flight) or the in-flight op already ended.
                    if start == 0 || end >= start {
                        next_report_ms = 0;
                        continue;
                    }
                    let now = now_ms();
                    let waited = now.saturating_sub(start);
                    if waited >= ms && (next_report_ms == 0 || now >= next_report_ms) {
                        emit(&format!(
                            "[watchdog] dispatch stuck op=0x{:02x} in_flight_ms={} pid={}",
                            WD_OP.load(Ordering::Relaxed),
                            waited,
                            std::process::id()
                        ));
                        next_report_ms = now + ms;
                    }
                }
            });
    });
}

/// Mark a dispatch as starting. `op` is the request opcode byte. No-op unless
/// the watchdog is enabled.
#[inline]
pub fn note_dispatch_start(op: u8) {
    if watchdog_ms() == 0 {
        return;
    }
    WD_OP.store(op, Ordering::Relaxed);
    // max(1) so a start at t=0 is never mistaken for "idle".
    WD_START_MS.store(now_ms().max(1), Ordering::Relaxed);
}

/// Mark the current dispatch as complete. No-op unless the watchdog is enabled.
#[inline]
pub fn note_dispatch_end() {
    if watchdog_ms() == 0 {
        return;
    }
    WD_END_MS.store(now_ms().max(1), Ordering::Relaxed);
}
