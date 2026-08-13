//! HTTP client construction for the desktop.
//!
//! Three clients exist for three different reasons, and the reason each is
//! separate is the whole content of this module: `http_client` streams
//! (uploads, media proxy, model downloads), `relay_bridge_client` carries
//! small interactive JSON and so can afford a stall budget, and
//! `media_fetch_client` is a no-redirect security boundary. Their shared
//! configuration lives in [`http_client_base`] so the three cannot drift.

/// Connect-phase budget shared by every desktop HTTP client.
///
/// Bounds only DNS + TCP + TLS. Safe on the streaming clients because it
/// stops at the moment the connection is established — a 100 MB download or
/// an hour-long video upload is never measured against it.
pub const HTTP_CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// Stall budget for the relay bridge.
///
/// `read_timeout` is two budgets in one: a hard deadline on time-to-response-
/// headers, and — only after headers arrive — an idle timer between body
/// frames. Both are correct for the bridge, whose requests carry small JSON
/// bodies and are awaited by interactive UI. Both are wrong for uploads and
/// model downloads, which is why this lives on a separate client.
pub const RELAY_BRIDGE_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Shared builder for every desktop HTTP client.
///
/// Three clients now exist for three different reasons — `http_client`
/// (streaming: uploads, media proxy, model downloads), `relay_bridge_client`
/// (small interactive JSON), and `media_fetch_client` (no-redirect security
/// boundary). Only their *differences* belong at the call sites; the localhost
/// `resolve`, pool sizing, and connect budget are common ground, and are here
/// so the three cannot drift apart.
pub(super) fn http_client_base() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .resolve("localhost", std::net::SocketAddr::from(([127, 0, 0, 1], 0)))
        .pool_idle_timeout(std::time::Duration::from_secs(10))
        .pool_max_idle_per_host(1)
        .connect_timeout(HTTP_CONNECT_TIMEOUT)
}

/// Build the client used for the relay's JSON bridge.
///
/// The bridge is the one HTTP surface where an unbounded wait is a bug rather
/// than a feature: `get_thread_replies` and friends await these requests to
/// paint the UI, so a half-dead pooled connection would leave the panel
/// pending with no data, no error, and no spinner resolution.
///
/// This client is deliberately NOT the app-wide `http_client`. `read_timeout`
/// is not reset by request-body progress, so any budget small enough to catch
/// a dead thread read would also abort a healthy large upload
/// (`commands::media::do_upload` mints a 1-hour auth window for video), the
/// media proxy's streamed response bodies, and the ~100 MB STT model download.
/// A per-request override is not available either: reqwest 0.13's
/// `RequestBuilder` exposes only the total `.timeout()`, never read semantics.
/// One number cannot serve both; two clients can. Covered by
/// `read_timeout_would_break_streaming_clients` in `app_state_tests.rs`.
pub fn build_relay_bridge_client() -> reqwest::Result<reqwest::Client> {
    relay_bridge_client_with(RELAY_BRIDGE_READ_TIMEOUT)
}

/// [`build_relay_bridge_client`] with an explicit stall budget.
///
/// Exists so the tests can exercise the real construction path on a budget
/// small enough to run in a second. They cannot simply pause tokio's clock:
/// under `start_paused` the runtime auto-advances time whenever it is idle,
/// and a pending real socket read counts as idle — so the *connect* timer
/// fires instantly and the test proves nothing about the read timer.
pub(super) fn relay_bridge_client_with(
    read_timeout: std::time::Duration,
) -> reqwest::Result<reqwest::Client> {
    http_client_base().read_timeout(read_timeout).build()
}

/// Build the no-redirect HTTP client used for authenticated relay media
/// fetches (download / copy).
///
/// This client is a security boundary, not a convenience: it carries a minted
/// media `Authorization` header, so it MUST NOT follow redirects. A relay 3xx
/// to an off-origin or private host would otherwise forward that header across
/// origins (a redirect-hop SSRF). `redirect::Policy::none()` returns the 3xx
/// verbatim so the caller can reject it.
///
/// Returned as a `Result` so the fail-closed invariant is testable — callers
/// must never substitute a redirect-following client on build failure. Shares
/// [`http_client_base`] with the other two clients.
pub fn build_media_fetch_client() -> reqwest::Result<reqwest::Client> {
    http_client_base()
        .redirect(reqwest::redirect::Policy::none())
        .build()
}

#[cfg(test)]
#[path = "app_state_http_tests.rs"]
mod tests;
