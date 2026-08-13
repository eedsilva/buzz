use super::*;
use nostr::{EventBuilder, Kind, Tag};

fn thread_page_event_at(kind: u32, content: &str, root: Option<&str>, created_at: u64) -> Event {
    let tags = root
        .map(|root| vec![Tag::parse(["e", root]).expect("valid root tag")])
        .unwrap_or_default();
    EventBuilder::new(Kind::Custom(kind as u16), content)
        .tags(tags)
        .custom_created_at(nostr::Timestamp::from(created_at))
        .sign_with_keys(&Keys::generate())
        .expect("test event should sign")
}

fn thread_page_event(kind: u32, content: &str, root: Option<&str>) -> Event {
    thread_page_event_at(kind, content, root, 1_700_000_000)
}

fn bounds_event(root: &str, content: &str) -> Event {
    thread_page_event(buzz_core_pkg::kind::KIND_THREAD_BOUNDS, content, Some(root))
}

#[test]
fn marker_author_scope_validates_scope_and_required_pubkey() {
    assert_eq!(
        marker_author_for_scope(None, Some("agent")),
        Ok(Some("agent"))
    );
    assert_eq!(
        marker_author_for_scope(Some("agent"), Some("agent")),
        Ok(Some("agent"))
    );
    assert_eq!(marker_author_for_scope(Some("channel"), None), Ok(None));
    assert_eq!(
        marker_author_for_scope(Some("agent"), None),
        Err("agent pubkey is required for agent-scoped markers".to_string())
    );
    assert_eq!(
        marker_author_for_scope(None, None),
        Err("agent pubkey is required for agent-scoped markers".to_string())
    );
    assert_eq!(
        marker_author_for_scope(Some("unexpected"), Some("agent")),
        Err("unsupported marker scope: unexpected".to_string())
    );
}

#[test]
fn managed_agent_message_builder_adds_mentions_and_client_marker() {
    let pubkey = Keys::generate().public_key().to_hex();
    let event = build_managed_agent_channel_message(
        uuid::Uuid::new_v4(),
        "Welcome!",
        None,
        std::slice::from_ref(&pubkey),
        &[vec!["client".to_string(), "welcome-v1".to_string()]],
    )
    .expect("message should build")
    .sign_with_keys(&Keys::generate())
    .expect("message should sign");

    assert!(event.tags.iter().any(|tag| {
        let parts = tag.as_slice();
        parts.len() >= 2 && parts[0] == "p" && parts[1] == pubkey
    }));
    assert!(event_has_client_marker(&event, "welcome-v1"));
}

#[test]
fn managed_agent_message_builder_can_carry_multiple_client_markers() {
    let event = build_managed_agent_channel_message(
        uuid::Uuid::new_v4(),
        "Welcome!",
        None,
        &[],
        &[
            vec!["client".to_string(), "opener-v1".to_string()],
            vec!["client".to_string(), "closer-v1".to_string()],
        ],
    )
    .expect("message should build")
    .sign_with_keys(&Keys::generate())
    .expect("message should sign");

    assert!(event_has_client_marker(&event, "opener-v1"));
    assert!(event_has_client_marker(&event, "closer-v1"));
}

#[test]
fn managed_agent_message_builder_rejects_invalid_mentions() {
    let error = build_managed_agent_channel_message(
        uuid::Uuid::new_v4(),
        "Welcome!",
        None,
        &["not-a-pubkey".to_string()],
        &[],
    )
    .expect_err("invalid mentions should fail");
    assert!(error.contains("pubkey must be a 64-character hex string"));
}
#[test]
fn search_messages_filter_requests_prefix_mode_for_topbar_typeahead() {
    let filter = build_search_messages_filter("  pro  ", 12, Some("channel-1"), None, None, None);

    assert_eq!(filter["search"], serde_json::json!("pro"));
    assert_eq!(filter["search_mode"], serde_json::json!("prefix"));
    assert_eq!(filter["limit"], serde_json::json!(12));
    assert_eq!(filter["#h"], serde_json::json!(["channel-1"]));
    assert!(filter.get("authors").is_none());
    assert!(filter.get("since").is_none());
    assert!(filter.get("until").is_none());
}

#[test]
fn search_messages_filter_emits_operator_fields() {
    let authors =
        vec!["aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899".to_string()];
    let filter = build_search_messages_filter(
        "deploy",
        20,
        Some("channel-uuid"),
        Some(&authors),
        Some(1_700_000_000),
        Some(1_700_086_400),
    );

    assert_eq!(filter["search"], serde_json::json!("deploy"));
    assert_eq!(filter["#h"], serde_json::json!(["channel-uuid"]));
    assert_eq!(
        filter["authors"],
        serde_json::json!(["aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"])
    );
    assert_eq!(filter["since"], serde_json::json!(1_700_000_000));
    assert_eq!(filter["until"], serde_json::json!(1_700_086_400));
}

#[test]
fn channel_messages_before_filter_sends_before_id_the_relay_reads() {
    // The relay bridge's `extract_before_id` reads the composite tiebreak
    // from `before_id`. If this filter sent the id under any other key (an
    // earlier cut used `n`), the relay would silently drop the tiebreak and
    // the dense-second keyset would degrade to a bare inclusive `until` —
    // re-returning the same page forever. Pin the field name here so the
    // client/relay contract can't drift without a red test (the Playwright
    // mock reimplements the keyset in JS and cannot catch this).
    let filter = build_channel_messages_before_filter("channel-1", 1_700_000_000, Some("ab"), 200);

    assert_eq!(filter["until"], serde_json::json!(1_700_000_000));
    assert_eq!(filter["before_id"], serde_json::json!("ab"));
    assert_eq!(filter["limit"], serde_json::json!(200));
    assert_eq!(filter["#h"], serde_json::json!(["channel-1"]));
    assert!(
        !filter.contains_key("n"),
        "tiebreak must be `before_id`, not the `n` alias the relay ignores"
    );
}

#[test]
fn thread_replies_filter_carries_non_p_gated_kinds_to_clear_the_gate() {
    // The relay bridge p-gates EVERY filter before routing
    // (`p_gated_filters_authorized`): a kindless filter "could match" a
    // p-gated kind, so it demands a `#p` tag we don't send -> HTTP 403,
    // before the thread-subtree query runs. The headline Lane-1 fix
    // (`useThreadReplies` closing the descendant gap) then fails on every
    // call against a real relay. So the thread filter MUST carry `kinds`,
    // and every kind MUST be non-p-gated (else the gate still fires). The
    // Playwright mock does not model p-gating, so this unit test is the
    // only guard against the client/relay auth contract drifting.
    let filter =
        build_thread_replies_filter("root-hex", Some("channel-1"), 64, 200, None, None, true);

    let kinds = filter
        .get("kinds")
        .and_then(|v| v.as_array())
        .expect("thread filter must carry `kinds` so the p-gate passes");
    assert!(!kinds.is_empty(), "kinds must be non-empty");
    for kind in kinds {
        let k = kind.as_u64().expect("kind is a number") as u32;
        assert!(
            !buzz_core_pkg::kind::P_GATED_KINDS.contains(&k),
            "kind {k} is p-gated; a p-gated kind in the filter re-triggers the \
                 403 that this fix exists to prevent"
        );
    }
    assert_eq!(filter["#e"], serde_json::json!(["root-hex"]));
    assert_eq!(filter["depth_limit"], serde_json::json!(64));
    assert_eq!(filter["thread_bounds"], serde_json::json!(true));
    assert_eq!(filter["#h"], serde_json::json!(["channel-1"]));
}

#[test]
fn thread_replies_filter_pages_with_composite_cursor() {
    // When a cursor is supplied, both the timestamp and the event-id
    // tiebreak must be emitted (`thread_cursor` + `thread_cursor_id`), else
    // paging degrades to timestamp-only and drops same-second replies.
    let cursor = crate::models::ThreadCursor {
        created_at: 1_700_000_000,
        event_id: "abcd".to_string(),
    };
    let filter = build_thread_replies_filter(
        "root-hex",
        None,
        64,
        200,
        Some("newest"),
        Some(&cursor),
        true,
    );
    assert_eq!(filter["thread_order"], serde_json::json!("newest"));
    assert_eq!(filter["thread_cursor"], serde_json::json!(1_700_000_000));
    assert_eq!(filter["thread_cursor_id"], serde_json::json!("abcd"));
    assert!(
        !filter.contains_key("#h"),
        "no channel_id -> no #h scope in the filter"
    );
}

#[test]
fn legacy_thread_filter_omits_modern_extensions_but_keeps_composite_cursor() {
    let cursor = crate::models::ThreadCursor {
        created_at: 1_700_000_000,
        event_id: "abcd".to_string(),
    };
    let filter = build_thread_replies_filter(
        "root-hex",
        Some("channel-1"),
        64,
        200,
        None,
        Some(&cursor),
        false,
    );

    assert!(!filter.contains_key("thread_bounds"));
    assert!(!filter.contains_key("thread_order"));
    assert_eq!(filter["thread_cursor"], serde_json::json!(1_700_000_000));
    assert_eq!(filter["thread_cursor_id"], serde_json::json!("abcd"));
}

#[test]
fn legacy_thread_pages_converge_past_two_same_second_boundaries() {
    let mut all_events: Vec<Event> = (0..401)
        .map(|_| thread_page_event_at(9, "reply", Some("root"), 1_700_000_000))
        .collect();
    // Old relays order and keyset on (created_at ASC, event_id ASC).
    all_events.sort_by_key(|event| (event.created_at.as_secs(), event.id.to_hex()));
    let expected_ids: Vec<String> = all_events.iter().map(|event| event.id.to_hex()).collect();
    let mut received_ids = Vec::new();
    let mut cursor: Option<crate::models::ThreadCursor> = None;

    loop {
        let modern_filter = build_thread_replies_filter(
            "root",
            Some("channel-1"),
            64,
            200,
            Some("newest"),
            cursor.as_ref(),
            true,
        );
        assert_eq!(modern_filter["thread_bounds"], serde_json::json!(true));
        assert_eq!(modern_filter["thread_order"], serde_json::json!("newest"));

        let select_old_relay_page = |request: &serde_json::Map<String, serde_json::Value>| {
            let cursor_created_at = request
                .get("thread_cursor")
                .and_then(|value| value.as_i64());
            let cursor_id = request
                .get("thread_cursor_id")
                .and_then(|value| value.as_str());
            all_events
                .iter()
                .filter(|event| match (cursor_created_at, cursor_id) {
                    (Some(created_at), Some(event_id)) => {
                        (event.created_at.as_secs() as i64, event.id.to_hex())
                            > (created_at, event_id.to_string())
                    }
                    _ => true,
                })
                .take(200)
                .cloned()
                .collect::<Vec<_>>()
        };

        // An old relay ignores the modern extensions and omits the overlay.
        let modern_response = select_old_relay_page(&modern_filter);
        assert!(matches!(
            thread_page::parse(modern_response, "root"),
            Err(thread_page::ParseError::MissingBounds)
        ));

        let legacy_filter = build_thread_replies_filter(
            "root",
            Some("channel-1"),
            64,
            200,
            None,
            cursor.as_ref(),
            false,
        );
        assert!(!legacy_filter.contains_key("thread_bounds"));
        assert!(!legacy_filter.contains_key("thread_order"));
        if let Some(expected_cursor) = cursor.as_ref() {
            assert_eq!(
                legacy_filter["thread_cursor"],
                serde_json::json!(expected_cursor.created_at)
            );
            assert_eq!(
                legacy_filter["thread_cursor_id"],
                serde_json::json!(expected_cursor.event_id)
            );
        }

        let page = thread_page::parse_legacy(select_old_relay_page(&legacy_filter), 200);
        received_ids.extend(
            page.events
                .iter()
                .map(|event| event["id"].as_str().expect("event id").to_string()),
        );
        if !page.has_more {
            assert!(page.next_cursor.is_none());
            break;
        }
        cursor = page.next_cursor;
    }

    assert_eq!(received_ids, expected_ids);
    let unique_ids: std::collections::HashSet<_> = received_ids.iter().collect();
    assert_eq!(unique_ids.len(), 401);
}

#[test]
fn thread_page_parser_accepts_valid_empty_and_non_empty_pages() {
    let empty = thread_page::parse(
        vec![bounds_event(
            "root",
            r#"{"has_more":false,"next_cursor":null}"#,
        )],
        "root",
    )
    .expect("valid terminal page should parse");
    assert!(empty.events.is_empty());
    assert!(!empty.has_more);
    assert!(empty.next_cursor.is_none());

    let reply = thread_page_event(9, "reply", Some("root"));
    let reply_id = reply.id.to_hex();
    let page = thread_page::parse(
        vec![
            reply,
            bounds_event(
                "root",
                r#"{"has_more":true,"next_cursor":{"created_at":1700000000,"id":"cursor-id"}}"#,
            ),
        ],
        "root",
    )
    .expect("valid continuing page should parse");
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0]["id"], serde_json::json!(reply_id));
    assert!(page.has_more);
    let cursor = page.next_cursor.expect("continuing page needs a cursor");
    assert_eq!(cursor.created_at, 1_700_000_000);
    assert_eq!(cursor.event_id, "cursor-id");
}

#[test]
fn thread_page_parser_rejects_missing_duplicate_and_wrong_root_bounds() {
    let reply = thread_page_event(9, "reply", Some("root"));
    assert!(thread_page::parse(vec![reply], "root")
        .err()
        .expect("missing bounds must fail closed")
        .to_string()
        .contains("omitted"));

    let terminal = r#"{"has_more":false,"next_cursor":null}"#;
    assert!(thread_page::parse(
        vec![
            bounds_event("root", terminal),
            bounds_event("root", terminal)
        ],
        "root",
    )
    .err()
    .expect("duplicate bounds must fail closed")
    .to_string()
    .contains("multiple"));

    assert!(
        thread_page::parse(vec![bounds_event("other-root", terminal)], "root")
            .err()
            .expect("mismatched root must fail closed")
            .to_string()
            .contains("does not match")
    );
}

#[test]
fn thread_page_parser_rejects_malformed_and_inconsistent_bounds() {
    assert!(
        thread_page::parse(vec![bounds_event("root", "not-json")], "root")
            .err()
            .expect("malformed bounds must fail closed")
            .to_string()
            .contains("Invalid thread bounds")
    );

    for content in [
        r#"{"has_more":true,"next_cursor":null}"#,
        r#"{"has_more":false,"next_cursor":{"created_at":1700000000,"id":"cursor-id"}}"#,
    ] {
        assert!(
            thread_page::parse(vec![bounds_event("root", content)], "root")
                .err()
                .expect("cursor presence must agree with has_more")
                .to_string()
                .contains("disagree")
        );
    }
}

#[test]
fn stored_managed_agent_auth_tag_trims_blank_values() {
    assert_eq!(
        stored_managed_agent_auth_tag(Some("  [\"auth\",\"owner\",\"\",\"sig\"]  ")),
        Some("[\"auth\",\"owner\",\"\",\"sig\"]".to_string())
    );
    assert_eq!(stored_managed_agent_auth_tag(Some("   ")), None);
    assert_eq!(stored_managed_agent_auth_tag(None), None);
}

#[test]
fn legacy_managed_agent_auth_tag_verifies_for_agent_pubkey() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();

    let tag = legacy_managed_agent_auth_tag(&owner_keys, &agent_keys.public_key())
        .expect("legacy auth tag should compute")
        .expect("legacy auth tag should be present");

    let owner = buzz_sdk_pkg::nip_oa::verify_auth_tag(&tag, &agent_keys.public_key())
        .expect("legacy auth tag should verify");
    assert_eq!(owner, owner_keys.public_key());
}

#[test]
fn legacy_managed_agent_auth_tag_skips_self_attestation() {
    let owner_keys = Keys::generate();

    let tag = legacy_managed_agent_auth_tag(&owner_keys, &owner_keys.public_key())
        .expect("self-attestation should be skipped");

    assert_eq!(tag, None);
}
