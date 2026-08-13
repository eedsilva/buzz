//! Tests for the desktop's three HTTP clients.
//!
//! Lives beside `app_state_http.rs` rather than in `app_state_tests.rs` so the
//! client construction and the tests that pin its invariants move together.

use super::super::*;
use super::*;

// ── HTTP client timeout split ────────────────────────────────────────────────
//
// `relay_bridge_client` carries a read timeout; `http_client` deliberately does
// not. These tests pin both halves, because each is only safe while the other
// holds: a bridge without the timeout re-opens the silent stall that leaves a
// thread panel pending forever, and a shared client with one silently truncates
// video uploads, media streams, and the ~100 MB model download.
//
// These run on the real clock with a small `TEST_READ_TIMEOUT`, not under
// `start_paused`. Paused time auto-advances whenever the runtime is idle, and a
// pending socket read is idle — so the connect timer fires immediately and the
// test passes while proving nothing. `paused_time_would_void_these_tests`
// below is the control that documents that trap.

/// Stall budget used by the tests in this section. Small enough to keep the
/// suite fast, large enough not to race a loopback connect.
const TEST_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(750);

/// A loopback server that accepts, reads the request, and then never responds
/// — the half-dead connection this whole change is about. Returns its base URL.
///
/// The listener moves into the thread and lives until the process exits, so a
/// client that is *supposed* to hang keeps hanging rather than getting a
/// spurious connection-reset that would look like a timeout.
fn spawn_silent_server() -> String {
    use std::io::Read as _;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        let mut held = Vec::new();
        while let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf);
            // Hold the socket open and silent; never write a response.
            held.push(stream);
        }
    });
    format!("http://{addr}/")
}

/// A request body that takes `chunks` × `TEST_READ_TIMEOUT` to produce — a
/// large upload on a slow uplink. Every chunk is forward progress; the client
/// is never stalled, which is precisely why an idle-looking timer must not
/// fire on it.
fn slow_upload_body(chunks: u32) -> reqwest::Body {
    let stream = futures_util::stream::unfold(0u32, move |i| async move {
        if i >= chunks {
            return None;
        }
        tokio::time::sleep(TEST_READ_TIMEOUT).await;
        Some((
            Ok::<_, std::io::Error>(bytes::Bytes::from_static(b"payload")),
            i + 1,
        ))
    });
    reqwest::Body::wrap_stream(stream)
}

#[tokio::test]
async fn relay_bridge_client_aborts_a_stalled_response() {
    // The thread-panel failure mode: a connection that accepts the request and
    // then goes silent. Without a read timeout this is indistinguishable from
    // a slow relay and waits forever.
    let url = spawn_silent_server();
    let client = relay_bridge_client_with(TEST_READ_TIMEOUT).expect("bridge client must build");

    let started = std::time::Instant::now();
    // Outer bound so that losing the read timeout FAILS this test instead of
    // hanging it — the regression is an unbounded wait, and a test that hangs
    // wedges CI rather than reporting.
    let outcome =
        tokio::time::timeout(TEST_READ_TIMEOUT * 8, client.post(&url).body("[]").send()).await;
    let elapsed = started.elapsed();

    let result = outcome.expect(
        "the bridge client hung: its read timeout is missing, which is exactly \
         the silent stall that leaves the thread panel pending forever",
    );
    assert!(
        result.is_err(),
        "the bridge client must give up on a response that never arrives"
    );
    // Attribute the failure to the read timeout, not to connect or to a reset.
    // A connect failure would land in microseconds on loopback.
    assert!(
        elapsed >= TEST_READ_TIMEOUT,
        "must fail on the read budget, not before it (failed after {elapsed:?}: {result:?})"
    );
    assert!(
        elapsed < HTTP_CONNECT_TIMEOUT,
        "must fail on the read budget, not the connect budget (took {elapsed:?})"
    );
}

#[tokio::test]
async fn http_client_has_no_response_deadline() {
    // Control for the test above: same silent server, the shared client. This
    // is the pre-existing behaviour and it must stay — a deadline here would
    // truncate media streams and the model download.
    let url = spawn_silent_server();
    let state = build_app_state();

    let outcome = tokio::time::timeout(
        TEST_READ_TIMEOUT * 4,
        state.http_client.post(&url).body("[]").send(),
    )
    .await;

    assert!(
        outcome.is_err(),
        "the shared client must still be waiting; a response deadline here \
         would abort long media streams and the ~100 MB model download \
         (got {outcome:?})"
    );
}

#[tokio::test]
async fn read_timeout_would_break_streaming_clients() {
    // Why the split exists. `read_timeout` is NOT reset by request-body
    // progress — until response headers arrive it is a hard deadline. So the
    // bridge's budget kills a healthy upload that merely takes longer than it,
    // which is routine for video (`do_upload` mints a 1-hour auth window).
    let url = spawn_silent_server();
    let bridge = relay_bridge_client_with(TEST_READ_TIMEOUT).expect("bridge client must build");

    let outcome = tokio::time::timeout(
        TEST_READ_TIMEOUT * 8,
        bridge.put(&url).body(slow_upload_body(4)).send(),
    )
    .await;

    let result = outcome.expect("the bridge client's read timeout must bound this upload");
    assert!(
        result.is_err(),
        "an upload longer than the read budget dies on the bridge client — \
         this is why uploads keep the shared client"
    );
}

#[tokio::test]
async fn shared_client_survives_a_long_upload() {
    // Positive half of the pair above: the same slow body on the shared client
    // is still in flight rather than aborted.
    let url = spawn_silent_server();
    let state = build_app_state();

    let outcome = tokio::time::timeout(
        TEST_READ_TIMEOUT * 4,
        state.http_client.put(&url).body(slow_upload_body(8)).send(),
    )
    .await;

    assert!(
        outcome.is_err(),
        "the shared client must not abort a slow upload; it should still be \
         waiting on the (deliberately silent) server (got {outcome:?})"
    );
}

#[tokio::test]
async fn only_the_bridge_client_carries_a_response_timeout() {
    // Structural counterpart to the behavioural tests above, and the one that
    // catches the tempting "simplification": moving the read timeout onto the
    // shared client. Behaviourally that regression only shows up on a request
    // that outlives the production 30s budget — too slow for a unit test — so
    // it is asserted on construction instead.
    //
    // `reqwest::Client`'s Debug prints `read_timeout` / `TotalTimeout` only
    // when they are configured, which makes this a real assertion rather than
    // a string-matching ritual. Verified against reqwest 0.13.4.
    let state = build_app_state();

    let bridge = format!("{:?}", state.relay_bridge_client);
    assert!(
        bridge.contains("read_timeout"),
        "the bridge client must carry a read timeout, else a stalled relay \
         connection leaves the thread panel pending forever: {bridge}"
    );

    for (name, client) in [
        ("http_client", &state.http_client),
        ("media_fetch_client", &state.media_fetch_client),
    ] {
        let rendered = format!("{client:?}");
        assert!(
            !rendered.contains("read_timeout") && !rendered.contains("TotalTimeout"),
            "{name} must carry no response deadline — it streams video uploads, \
             media bodies, and the ~100 MB model download, and any such budget \
             truncates them: {rendered}"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn paused_time_would_void_these_tests() {
    // Guard against a plausible "speed-up" of the tests above. Under paused
    // time the runtime advances the clock whenever it is idle, and a pending
    // socket read is idle — so both the connect and read budgets elapse in
    // essentially zero real time. Every assertion above would still see an
    // error and pass, while measuring nothing. Documented as a test so the
    // trap is discoverable rather than rediscovered.
    //
    // Asserted on real elapsed time rather than the error kind: which of the
    // two budgets wins the race depends on whether the loopback connect
    // completes before the runtime next goes idle, so the kind is not stable
    // under a loaded parallel run. That the failure is instant *is* stable,
    // and it is the whole trap.
    let url = spawn_silent_server();
    let client = build_relay_bridge_client().expect("bridge client must build");

    let started = std::time::Instant::now();
    let result = client.post(&url).body("[]").send().await;
    let elapsed = started.elapsed();

    assert!(
        result.is_err(),
        "paused time must produce an error from the production 30s budget \
         without waiting 30s (got {result:?})"
    );
    assert!(
        elapsed < RELAY_BRIDGE_READ_TIMEOUT / 10,
        "the point of this control: paused time short-circuits the real budget \
         ({elapsed:?} of {RELAY_BRIDGE_READ_TIMEOUT:?}), so a paused test \
         cannot attribute a failure to the timeout it names"
    );
}
