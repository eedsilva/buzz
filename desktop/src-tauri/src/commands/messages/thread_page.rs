use nostr::Event;
use serde::Deserialize;
use std::fmt;

use crate::models::{ThreadCursor, ThreadRepliesResponse};

#[derive(Debug, PartialEq, Eq)]
pub(super) enum ParseError {
    MissingBounds,
    InvalidBounds(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingBounds => {
                formatter.write_str("Thread response omitted its bounds overlay")
            }
            Self::InvalidBounds(message) => formatter.write_str(message),
        }
    }
}

#[derive(Deserialize)]
struct BoundsCursor {
    created_at: i64,
    id: String,
}

#[derive(Deserialize)]
struct BoundsPayload {
    has_more: bool,
    next_cursor: Option<BoundsCursor>,
}

pub(super) fn parse(
    events: Vec<Event>,
    root_event_id: &str,
) -> Result<ThreadRepliesResponse, ParseError> {
    let mut replies = Vec::new();
    let mut bounds = None;
    for event in events {
        if event.kind.as_u16() as u32 == buzz_core_pkg::kind::KIND_THREAD_BOUNDS {
            if bounds.is_some() {
                return Err(ParseError::InvalidBounds(
                    "Thread response contained multiple bounds overlays".to_string(),
                ));
            }
            let matches_root = event.tags.iter().any(|tag| {
                let values = tag.as_slice();
                values.first().map(String::as_str) == Some("e")
                    && values.get(1).map(String::as_str) == Some(root_event_id)
            });
            if !matches_root {
                return Err(ParseError::InvalidBounds(
                    "Thread bounds overlay does not match the requested root".to_string(),
                ));
            }
            bounds = Some(
                serde_json::from_str::<BoundsPayload>(&event.content).map_err(|error| {
                    ParseError::InvalidBounds(format!("Invalid thread bounds overlay: {error}"))
                })?,
            );
        } else if let Ok(value) = serde_json::to_value(&event) {
            replies.push(value);
        }
    }
    let bounds = bounds.ok_or(ParseError::MissingBounds)?;
    let next_cursor = bounds.next_cursor.map(|cursor| ThreadCursor {
        created_at: cursor.created_at,
        event_id: cursor.id,
    });
    if bounds.has_more != next_cursor.is_some() {
        return Err(ParseError::InvalidBounds(
            "Thread bounds has_more and next_cursor disagree".to_string(),
        ));
    }
    Ok(ThreadRepliesResponse {
        events: replies,
        has_more: bounds.has_more,
        next_cursor,
    })
}

pub(super) fn parse_legacy(events: Vec<Event>, cap: u32) -> ThreadRepliesResponse {
    let has_more = events.len() as u32 >= cap;
    let next_cursor = if has_more {
        events.last().map(|event| ThreadCursor {
            created_at: event.created_at.as_secs() as i64,
            event_id: event.id.to_hex(),
        })
    } else {
        None
    };
    let events = events
        .iter()
        .filter_map(|event| serde_json::to_value(event).ok())
        .collect();

    ThreadRepliesResponse {
        events,
        has_more,
        next_cursor,
    }
}
