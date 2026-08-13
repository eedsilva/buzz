use super::{query_relay_at_after_admission, relay_api_base_url_with_override};
use crate::app_state::AppState;

/// Execute an owner-authenticated relay query for a user-facing surface.
/// Unlike background work, this returns after a short admission wait so the UI
/// can show relay back-pressure rather than remaining pending for minutes.
pub async fn query_relay_interactive(
    state: &AppState,
    filters: &[serde_json::Value],
) -> Result<Vec<nostr::Event>, String> {
    crate::relay_admission::wait_for_interactive_rate_limit().await?;
    query_relay_at_after_admission(state, &relay_api_base_url_with_override(state), filters).await
}
