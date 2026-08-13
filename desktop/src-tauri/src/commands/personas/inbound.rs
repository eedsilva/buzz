//! Inbound relay → local store reconciliation for persona/team/managed-agent
//! projections and their NIP-09 tombstones. Extracted from the parent module to
//! keep it under the file-size cap.

use tauri::{AppHandle, Emitter, Manager};

use crate::{
    app_state::AppState,
    managed_agents::{
        agent_events::ManagedAgentEventContent, load_agent_definitions, load_personas,
        persona_events::persona_d_tag, save_personas, team_events::TeamEventContent,
        try_regenerate_nest, AgentDefinition, ManagedAgentRecord, MutationRoute, TeamRecord,
    },
    util::now_iso,
};

#[cfg(test)]
mod inbound_tests;

/// Apply an inbound kind:30175 persona event from the relay onto the local
/// store. The frontend's live subscription invokes this per event for our own
/// authored coordinate so Device B inherits Device A's edits.
///
/// Retention is a sync channel that writes INTO `personas.json`, never an
/// authoritative read source — `load_personas` is untouched, so every agent
/// keeps resolving its persona by UUID and keeps its provider keys.
///
/// MATCH KEY (single source of truth, both directions): an inbound event
/// matches the local record whose `persona_d_tag(record)` equals the event's
/// d-tag. Reusing the same derivation the outbound path uses guarantees the
/// inbound key can never drift from the outbound key — in particular, an
/// in-app persona (`source_team_persona_slug == None`) whose d-tag IS its
/// `id` matches its existing UUID row instead of minting a duplicate.
///
/// On match: patch ONLY the projected fields; preserve local `id`, `env_vars`,
/// `source_team`, and `created_at`. On no match: insert the parsed record as-is
/// — `persona_from_event` already sets `id = d_tag`, so an in-app persona reuses
/// its d-tag as the id and a re-received event stays idempotent (no duplicate).
///
/// The retention store decides whether the inbound event wins over a pending
/// local edit (`retain_inbound_event`): `personas.json` is only patched when the
/// retain reports [`InboundOutcome::Applied`], so an equal-second collision with
/// a pending local edit leaves the local record — and its queued publish —
/// untouched.
///
/// `arrival_relay_url` is the relay the calling subscription is bound to. The
/// retention store this event belongs to is decided by the community that
/// DELIVERED it, not by whichever community happens to be active when the
/// reconcile runs — a workspace switch in flight would otherwise file community
/// A's event into community B's scoped database. An event whose arrival relay is
/// no longer the active scope is dropped: it was already durable in its own
/// community's store when it arrived there, and that community's next boot
/// reconcile refetches it.
#[tauri::command]
pub async fn reconcile_inbound_persona_event(
    event_json: String,
    arrival_relay_url: String,
    app: AppHandle,
) -> Result<InboundReconcileOutcome, String> {
    tokio::task::spawn_blocking(move || {
        reconcile_inbound_persona_event_blocking(event_json, arrival_relay_url, app)
    })
    .await
    .map_err(|e| format!("spawn_blocking failed: {e}"))?
}

fn reconcile_inbound_persona_event_blocking(
    event_json: String,
    arrival_relay_url: String,
    app: AppHandle,
) -> Result<InboundReconcileOutcome, String> {
    use crate::managed_agents::persona_events::persona_from_event;
    use buzz_core_pkg::kind::{KIND_DELETION, KIND_MANAGED_AGENT, KIND_PERSONA, KIND_TEAM};

    let state = app.state::<AppState>();
    let event = parse_verified_inbound_event(&event_json)?;

    // The live filter subscribes to 30175/30176/30177 (upserts) plus kind:5
    // (NIP-09 deletions). d-tags are NOT unique across kinds, so every path
    // below dispatches on kind FIRST and only ever touches its own store — a
    // cross-kind d-tag collision can never link a team to a persona or agent.
    let kind = event.kind.as_u16() as u32;

    // kind:5 deletion: a tombstone removes the local record at the coordinate
    // in its `a` tag (`<target_kind>:<owner>:<d_tag>`). Handled before the
    // upsert dispatch because its coordinate and retention key differ.
    if kind == KIND_DELETION {
        return reconcile_inbound_tombstone(&event, &arrival_relay_url, &app, &state)
            .map(|()| InboundReconcileOutcome::default());
    }

    if !matches!(kind, KIND_PERSONA | KIND_TEAM | KIND_MANAGED_AGENT) {
        return Ok(InboundReconcileOutcome::default());
    }

    // The d-tag identifies the record within its kind. Persona derives it from
    // the parsed record (`persona_d_tag`); team/agent carry it as the event's
    // d-tag directly. The persona is parsed once here and reused in the apply
    // branch below — team/agent content is parsed in-branch since their d-tag
    // comes from the event tag, not the content.
    let inbound_persona = (kind == KIND_PERSONA)
        .then(|| persona_from_event(&event))
        .transpose()?;
    let d_tag = match &inbound_persona {
        Some(persona) => persona_d_tag(persona),
        None => event_d_tag(&event)?,
    };

    let _store_guard = state
        .managed_agents_store_lock
        .lock()
        .map_err(|error| error.to_string())?;

    // Resolve inbound vs. any pending local edit before touching the store, in
    // the scope the event ARRIVED on. A workspace switch since arrival leaves
    // this event to its own community's store — dropping it here is what keeps
    // community A's head out of community B's database. Match on both relay and
    // owner: an in-flight old-owner event on the same relay must not land in
    // the new owner's active store after an identity switch.
    let arrival_owner_pubkey = event.pubkey.to_hex();
    let Some(scope) = crate::managed_agents::retention::arrival_retention_scope(
        &app,
        &state,
        &arrival_relay_url,
        &arrival_owner_pubkey,
    )?
    else {
        return Ok(InboundReconcileOutcome::default());
    };

    // Library-projection preflight (§2.7): a projected persona is
    // library-authoritative, so an inbound plain-persona upsert targeting it must
    // NOT overwrite the local cache OR advance the retention head — the future
    // library-aware inbound handler owns that coordinate. Return WITHOUT retaining
    // (Ok, unretained), so once that handler lands the event is reprocessed;
    // retaining here would move the head and make the retry look stale. Routes on
    // `persona_d_tag` (the exact match key `apply_inbound_persona` uses) against
    // the RAW keyless record — `library_ref` is not view-carried. Only KIND_PERSONA
    // targets the persona store; team/agent projections are out of scope here.
    if kind == KIND_PERSONA {
        let raw_definitions = load_agent_definitions(&app)?;
        if MutationRoute::for_persona_d_tag(&raw_definitions, &d_tag)
            == MutationRoute::LibraryProjected
        {
            return Ok(InboundReconcileOutcome::default());
        }
    }

    apply_inbound_upsert_in_scope(&app, &scope, kind, d_tag, inbound_persona, &event)
}

/// Retain an inbound upsert into `scope`'s store and apply it to disk — the
/// command core the blocking wrapper calls once it has resolved the arrival
/// retention scope and cleared the §2.7 preflight.
///
/// Split out from [`reconcile_inbound_persona_event_blocking`] so a test can
/// drive the real retain → apply → §2.8 convergence sequence against a mock
/// app and a scope whose retention DB path it controls — crossing the exact
/// `?` on the corrective re-retain rather than exercising the helper in
/// isolation. Store I/O keys off the app's active scope; retention keys off
/// the passed `scope`, exactly as in production.
fn apply_inbound_upsert_in_scope<R: tauri::Runtime>(
    app: &AppHandle<R>,
    scope: &crate::managed_agents::retention::RetentionScope,
    kind: u32,
    d_tag: String,
    inbound_persona: Option<AgentDefinition>,
    event: &nostr::Event,
) -> Result<InboundReconcileOutcome, String> {
    use crate::managed_agents::{
        agent_events::managed_agent_content_from_event,
        load_managed_agents, load_teams,
        retention::{open_retention_db, retain_inbound_event, InboundOutcome, RetainedEvent},
        save_managed_agents, save_teams,
        team_events::team_content_from_event,
    };
    use buzz_core_pkg::kind::{KIND_MANAGED_AGENT, KIND_PERSONA, KIND_TEAM};
    use nostr::JsonUtil;

    let conn = open_retention_db(&scope.db_path)?;
    let outcome = retain_inbound_event(
        &conn,
        &RetainedEvent {
            kind,
            pubkey: event.pubkey.to_hex(),
            d_tag: d_tag.clone(),
            content: event.content.to_string(),
            created_at: event.created_at.as_secs() as i64,
            raw_event: event.as_json(),
            pending_sync: false,
        },
    )?;
    if outcome == InboundOutcome::Skipped {
        return Ok(InboundReconcileOutcome::default());
    }

    let mut result = InboundReconcileOutcome::default();
    match kind {
        KIND_PERSONA => {
            let mut personas = load_personas(app)?;
            // `inbound_persona` is `Some` for KIND_PERSONA (set above).
            apply_inbound_persona(
                &mut personas,
                inbound_persona.expect("persona parsed above"),
            );
            save_personas(app, &personas)?;
        }
        KIND_TEAM => {
            let mut teams = load_teams(app)?;
            apply_inbound_team(&mut teams, d_tag, team_content_from_event(event)?);
            save_teams(app, &teams)?;
        }
        KIND_MANAGED_AGENT => {
            let mut agents = load_managed_agents(app)?;
            // §2.8 canonical linkage is resolved against the raw keyless
            // definition store (`library_ref` is not wire-carried).
            let definitions = load_agent_definitions(app)?;
            let linkage = apply_inbound_managed_agent(
                &mut agents,
                &definitions,
                &d_tag,
                managed_agent_content_from_event(event)?,
            );
            save_managed_agents(app, &agents)?;

            // §2.8 convergence: a frozen linkage means the retained head (the
            // inbound event, retained above) authored a library-owned or
            // inadmissible linkage change. Re-retain the LOCAL record's
            // projection at a monotonically newer `created_at` so the relay head
            // converges back to the library-authoritative linkage — the same
            // mechanism §2.7's 30175 rule uses. The frozen record still exists
            // (only its linkage was left intact), so it always has a projection
            // to reassert.
            //
            // The corrective retain is NOT best-effort: if it fails, the
            // non-authoritative inbound head is left retained and ordinary
            // replay cannot repair it (the same event re-arriving is `Skipped`
            // at the equal-`created_at` guard above). Propagating the error is
            // what keeps the command from reporting success over a divergent
            // head — the durable retry owner is the boot-time
            // `reconcile_agents_to_events` pass, which re-diffs the
            // still-authoritative on-disk record against the retained head every
            // launch and re-queues this same corrective row.
            if let InboundAgentLinkage::Frozen(reason) = linkage {
                converge_frozen_linkage(&conn, &scope.owner_keys, &agents, &d_tag)?;
                result.degradation = Some(LinkageDegradation::new(reason, &d_tag));
                eprintln!("buzz-desktop: {}", reason.note(&d_tag));
            }
        }
        _ => unreachable!("kind gated above"),
    }
    try_regenerate_nest(app).ok();

    // Signal the live UI to refetch agents data — inbound relay events otherwise
    // land on disk silently, leaving the Agents tab stale until restart.
    let _ = app.emit("agents-data-changed", ());

    Ok(result)
}

/// Parse an inbound wire event and enforce the signature gate. Everything
/// downstream trusts `event.pubkey` (ownership routing, tombstone scoping,
/// behavioral-quad application), so a forged pubkey must die here — the
/// TS-side owner filter reads the same attacker-controlled field and is no
/// defense.
fn parse_verified_inbound_event(event_json: &str) -> Result<nostr::Event, String> {
    use nostr::JsonUtil;
    let event = nostr::Event::from_json(event_json)
        .map_err(|e| format!("failed to parse inbound event: {e}"))?;
    event
        .verify()
        .map_err(|e| format!("inbound event failed signature verification: {e}"))?;
    Ok(event)
}

/// Parse a NIP-09 `a`-tag coordinate `<kind>:<owner_pubkey>:<d_tag>` into its
/// target kind and d-tag. Returns `None` if the tag is absent or malformed, so
/// the caller no-ops on a tombstone it can't route.
fn parse_deletion_coordinate(event: &nostr::Event) -> Option<(u32, String)> {
    event.tags.iter().find_map(|tag| {
        let values: Vec<&str> = tag.as_slice().iter().map(|s| s.as_str()).collect();
        if values.first() != Some(&"a") {
            return None;
        }
        let coord = values.get(1)?;
        // `<kind>:<owner>:<d_tag>` — d_tag may itself contain ':' so split at
        // most twice and keep the remainder as the d_tag.
        let mut parts = coord.splitn(3, ':');
        let kind: u32 = parts.next()?.parse().ok()?;
        let owner = parts.next()?;
        // NIP-09 scoping: only the record's author may tombstone it. The
        // signature gate upstream proves `event.pubkey`; requiring the
        // coordinate owner to match closes the other half — a validly
        // signed kind:5 naming ANOTHER owner's coordinate must no-op.
        if owner != event.pubkey.to_hex() {
            return None;
        }
        let d_tag = parts.next()?;
        Some((kind, d_tag.to_string()))
    })
}

/// Apply an inbound kind:5 NIP-09 deletion: remove the local record at the
/// tombstone's target coordinate, scoped per-kind. Mirrors the upsert spine —
/// arrival-scoped retention resolution under the store lock, then a per-kind
/// store mutation — but removes rather than patches. Unknown/malformed
/// coordinates no-op, as does a tombstone whose arrival community is no longer
/// active.
fn reconcile_inbound_tombstone(
    event: &nostr::Event,
    arrival_relay_url: &str,
    app: &AppHandle,
    state: &AppState,
) -> Result<(), String> {
    use crate::managed_agents::{
        load_managed_agents, load_teams,
        retention::{
            open_retention_db, retain_inbound_event, tombstone_retention_d_tag, InboundOutcome,
            RetainedEvent,
        },
        save_managed_agents, save_teams,
    };
    use buzz_core_pkg::kind::{KIND_DELETION, KIND_MANAGED_AGENT, KIND_PERSONA, KIND_TEAM};
    use nostr::JsonUtil;

    let Some((target_kind, target_d_tag)) = parse_deletion_coordinate(event) else {
        return Ok(()); // no routable coordinate — nothing to delete
    };
    if !matches!(target_kind, KIND_PERSONA | KIND_TEAM | KIND_MANAGED_AGENT) {
        return Ok(()); // deletion for a kind we don't track locally
    }

    let _store_guard = state
        .managed_agents_store_lock
        .lock()
        .map_err(|error| error.to_string())?;

    // Resolve against the retained tombstone row (keyed by the target
    // coordinate, F2c) so a re-received tombstone or one older than a pending
    // local edit is a no-op. Scoped to the arrival community + owner, so a
    // workspace switch since arrival drops the tombstone instead of retaining
    // it — and deleting a record — in the wrong community's or owner's store.
    let tombstone_owner_pubkey = event.pubkey.to_hex();
    let Some(scope) = crate::managed_agents::retention::arrival_retention_scope(
        app,
        state,
        arrival_relay_url,
        &tombstone_owner_pubkey,
    )?
    else {
        return Ok(());
    };

    // Library-projection preflight (§2.7): a projected persona is
    // library-authoritative, so an inbound tombstone targeting it must NOT delete
    // the local record OR advance the retention head — the future library-aware
    // handler owns removing that coordinate (as a §3.4 workspace-remove). Return
    // WITHOUT retaining (Ok, unretained) so the tombstone is reprocessed once that
    // handler lands. Routes on the tombstone's `target_d_tag` — the same
    // `persona_d_tag`-derived key the KIND_PERSONA `retain` below matches on —
    // against the RAW keyless record. Only KIND_PERSONA tombstones touch the
    // persona store; team/agent removals are out of scope here.
    if target_kind == KIND_PERSONA {
        let raw_definitions = load_agent_definitions(app)?;
        if MutationRoute::for_persona_d_tag(&raw_definitions, &target_d_tag)
            == MutationRoute::LibraryProjected
        {
            return Ok(());
        }
    }

    let conn = open_retention_db(&scope.db_path)?;
    let outcome = retain_inbound_event(
        &conn,
        &RetainedEvent {
            kind: KIND_DELETION,
            pubkey: event.pubkey.to_hex(),
            d_tag: tombstone_retention_d_tag(target_kind, &target_d_tag),
            content: event.content.to_string(),
            created_at: event.created_at.as_secs() as i64,
            raw_event: event.as_json(),
            pending_sync: false,
        },
    )?;
    if outcome == InboundOutcome::Skipped {
        return Ok(());
    }

    // Remove the local record using the SAME per-kind match rule the apply fns
    // use: persona by `persona_d_tag`, team by `id`, managed-agent by `pubkey`.
    match target_kind {
        KIND_PERSONA => {
            let mut personas = load_personas(app)?;
            personas.retain(|record| persona_d_tag(record) != target_d_tag);
            save_personas(app, &personas)?;
        }
        KIND_TEAM => {
            let mut teams = load_teams(app)?;
            teams.retain(|record| record.id != target_d_tag);
            save_teams(app, &teams)?;
        }
        KIND_MANAGED_AGENT => {
            let mut agents = load_managed_agents(app)?;
            agents.retain(|record| record.pubkey != target_d_tag);
            save_managed_agents(app, &agents)?;
        }
        _ => unreachable!("target kind gated above"),
    }
    try_regenerate_nest(app).ok();

    // Refresh the live UI on inbound deletion — a removal is as user-visible as
    // an upsert and the Agents tab must drop the tombstoned record without restart.
    let _ = app.emit("agents-data-changed", ());

    Ok(())
}

/// Extract the `d` tag value from an event, the match key for team (= team id)
/// and managed-agent (= agent pubkey) inbound reconcile.
fn event_d_tag(event: &nostr::Event) -> Result<String, String> {
    event
        .tags
        .iter()
        .find_map(|tag| {
            let values: Vec<&str> = tag.as_slice().iter().map(|s| s.as_str()).collect();
            (values.first() == Some(&"d"))
                .then(|| values.get(1).map(|s| s.to_string()))
                .flatten()
        })
        .ok_or_else(|| "inbound event missing d-tag".to_string())
}

/// Merge a parsed inbound persona into the local set: patch the matching record
/// in place, or push it when none matches.
///
/// The match key is `persona_d_tag` — the same derivation the outbound path
/// uses — so the inbound and outbound keys can never drift. On match, only the
/// projected fields are overwritten; local `id`, `env_vars`, `source_team`, and
/// `created_at` survive. On no match, the parsed record is inserted as-is; since
/// `persona_from_event` sets `id = d_tag`, an in-app persona reuses its d-tag as
/// the id and a re-received event stays idempotent (no duplicate row).
fn apply_inbound_persona(personas: &mut Vec<AgentDefinition>, inbound: AgentDefinition) {
    let d_tag = persona_d_tag(&inbound);
    match personas
        .iter_mut()
        .find(|record| persona_d_tag(record) == d_tag)
    {
        Some(local) => {
            local.display_name = inbound.display_name;
            local.avatar_url = inbound.avatar_url;
            local.system_prompt = inbound.system_prompt;
            local.runtime = inbound.runtime;
            local.model = inbound.model;
            local.provider = inbound.provider;
            local.name_pool = inbound.name_pool;
            local.respond_to = inbound.respond_to;
            local.respond_to_allowlist = inbound.respond_to_allowlist;
            local.parallelism = inbound.parallelism;
            local.shared = inbound.shared;
            local.updated_at = inbound.updated_at;
        }
        None => personas.push(inbound),
    }
}

/// The typed result of an inbound persona/team/managed-agent reconcile.
///
/// Non-agent kinds, no-match, and admissible-linkage reconciles return the
/// default (`degradation: None`). Only a §2.8 frozen-linkage reconcile sets
/// `degradation`, so the frontend can observe the interim posture rather than
/// having it discarded to stderr. No new UI is wired in this phase — the field
/// is a surface the frontend CAN consume.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InboundReconcileOutcome {
    /// Set when an inbound kind:30177 event's linkage authorship was rejected
    /// under the §2.8 canonical-linkage rule and the local head was re-retained
    /// to converge the relay back.
    pub degradation: Option<LinkageDegradation>,
}

/// A typed, frontend-consumable description of a frozen-linkage degradation
/// (§2.8). Carries the machine-readable reason and the affected agent pubkey.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkageDegradation {
    /// Machine-readable freeze reason.
    pub reason: LinkageFreezeReason,
    /// The affected managed-agent pubkey (the event's d-tag).
    pub agent_pubkey: String,
    /// Human-readable note, identical to the log line.
    pub message: String,
}

impl LinkageDegradation {
    fn new(reason: LinkageFreezeReason, agent_pubkey: &str) -> Self {
        Self {
            reason,
            agent_pubkey: agent_pubkey.to_string(),
            message: reason.note(agent_pubkey),
        }
    }
}

/// The outcome of applying an inbound kind:30177 event under the §2.8
/// canonical-linkage rule.
#[derive(Debug, Clone, PartialEq, Eq)]
enum InboundAgentLinkage {
    /// No local match, or any linkage change the event carried was admissible:
    /// the event applied exactly as at head.
    Applied,
    /// The event tried to author or clear a library-owned linkage, or to admit
    /// a projected link that only the Phase-4b coordinator may admit. The
    /// linkage change (and the definition quad it derives) was IGNORED and only
    /// safe per-instance fields were applied. The caller must re-retain the
    /// local record at a newer `created_at` so the relay head converges back
    /// (§2.8, mirroring §2.7's 30175 rule) and surface the typed reason.
    Frozen(LinkageFreezeReason),
}

/// Why an inbound kind:30177 event's linkage authorship was rejected (§2.8).
/// Typed so the convergence + degradation surfacing at the call site is not a
/// bare string.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkageFreezeReason {
    /// The matched instance is currently linked to a library-projected
    /// definition and the inbound event would clear or re-point its
    /// `persona_id`. Linkage is owned by the library machinery — the same
    /// OUTPUT-ONLY discipline §2.7 applies to projected definition metadata.
    OwnedByLibrary,
    /// The inbound event would newly link a plain instance to a projected
    /// definition. Admitting a projected link requires the coordinator's
    /// `admit_instance_link()` step (Phase 4b); until it lands the interim
    /// posture fails the new link closed.
    InadmissibleNewLink,
}

impl LinkageFreezeReason {
    /// A human-readable degradation note for logging (§2.8 surfacing). The
    /// coordinator (Phase 4b) will replace this interim posture with an
    /// admission decision.
    fn note(self, agent_pubkey: &str) -> String {
        match self {
            Self::OwnedByLibrary => format!(
                "inbound kind:30177 for {agent_pubkey}: refused to re-point/clear a \
                 library-owned linkage; safe fields applied, re-retaining local head (§2.8)"
            ),
            Self::InadmissibleNewLink => format!(
                "inbound kind:30177 for {agent_pubkey}: refused to newly link a plain \
                 instance to a library-projected definition (needs the Phase-4b \
                 coordinator); safe fields applied, re-retaining local head (§2.8)"
            ),
        }
    }
}

/// Merge an inbound kind:30177 managed-agent projection into the local set
/// under the §2.8 canonical-linkage rule.
///
/// Matches the local record whose `pubkey` equals the event's d-tag (the d-tag
/// IS the agent pubkey — see `build_agent_event`). On match, overwrite ONLY the
/// 10 projected fields; every secret (`private_key_nsec`, `auth_tag`,
/// `env_vars`, `backend`), the harness pins (`agent_command`,
/// `agent_command_override`), and all runtime/local fields are preserved
/// untouched. The projection type carries none of them, so they cannot be
/// reached here even if a foreign event tried to inject them.
///
/// # §2.8 canonical linkage
///
/// A library-linked instance's `persona_id` is owned by the library machinery,
/// not the relay. `definitions` is the raw keyless definition store, resolved
/// through the [`MutationRoute::for_linked_definition`] read-side resolver so
/// this arm and every other library mechanism discover the instance↔definition
/// relationship one way. Two linkage changes fail closed (returning
/// [`InboundAgentLinkage::Frozen`], applying only safe per-instance fields):
/// - the matched instance is currently linked to a projected definition and the
///   event would clear or re-point `persona_id` ([`OwnedByLibrary`]);
/// - the event would newly link a currently-plain instance to a projected
///   definition ([`InadmissibleNewLink`]) — a Phase-4b coordinator admission.
///
/// Every other case (no local match, no linkage change, or a plain↔plain
/// relink) applies exactly as at head.
///
/// No match is a no-op: managed agents carry device-local secrets and are never
/// minted from a relay event — an agent that does not already exist locally has
/// no secret key to run with, so inserting a secretless shell would be useless
/// and misleading. This diverges from the persona path, which DOES insert on no
/// match (personas are secretless definitions). Flagged in the reconcile docs.
///
/// [`OwnedByLibrary`]: LinkageFreezeReason::OwnedByLibrary
/// [`InadmissibleNewLink`]: LinkageFreezeReason::InadmissibleNewLink
fn apply_inbound_managed_agent(
    agents: &mut [ManagedAgentRecord],
    definitions: &[ManagedAgentRecord],
    d_tag: &str,
    inbound: ManagedAgentEventContent,
) -> InboundAgentLinkage {
    let Some(local) = agents.iter_mut().find(|record| record.pubkey == d_tag) else {
        return InboundAgentLinkage::Applied;
    };

    // Safe per-instance fields apply as at head regardless of the linkage
    // decision — they are genuinely instance-local and never library-authored.
    local.name = inbound.name;
    local.parallelism = inbound.parallelism;
    local.respond_to = inbound.respond_to;
    local.respond_to_allowlist = inbound.respond_to_allowlist;

    // §2.8 canonical-linkage classification, resolved through the read-side
    // resolver against the raw keyless definition store. `library_ref` is not
    // wire-carried; the linkage's library status can only be read from the
    // definition the instance's `persona_id` resolves to.
    let linkage_changes = local.persona_id.as_deref() != inbound.persona_id.as_deref();
    let freeze = if !linkage_changes {
        None
    } else if MutationRoute::for_linked_definition(definitions, local.persona_id.as_deref())
        == MutationRoute::LibraryProjected
    {
        Some(LinkageFreezeReason::OwnedByLibrary)
    } else if MutationRoute::for_linked_definition(definitions, inbound.persona_id.as_deref())
        == MutationRoute::LibraryProjected
    {
        Some(LinkageFreezeReason::InadmissibleNewLink)
    } else {
        None
    };

    if let Some(reason) = freeze {
        // Linkage authorship rejected: leave `persona_id` and the
        // definition-resolved quad exactly as the local record holds them. The
        // caller re-retains this record so the relay head converges back.
        return InboundAgentLinkage::Frozen(reason);
    }

    // Admissible: head behavior. A definition-linked event omits the definition
    // quad because those fields resolve through the kind:30175 definition —
    // absent means "not carried", never "clear". Definition-less events still
    // carry the quad and apply it unconditionally (including clears).
    let definition_linked = inbound.persona_id.is_some();
    local.persona_id = inbound.persona_id;
    if !definition_linked {
        local.system_prompt = inbound.system_prompt;
        local.model = inbound.model;
        local.provider = inbound.provider;
        local.persona_source_version = inbound.persona_source_version;
    }
    InboundAgentLinkage::Applied
}

/// §2.8 convergence: re-retain the local managed-agent record's projection at a
/// monotonically newer `created_at` so the relay head converges back to the
/// library-authoritative linkage after a frozen inbound event was retained.
///
/// This is the corrective step that must NOT be best-effort. The inbound event
/// is already the retained head (retained before the store apply); if this
/// re-retain fails, that non-authoritative head is left in place and ordinary
/// replay cannot repair it — the same event re-arriving is `Skipped` at the
/// equal-`created_at` guard before the convergence branch runs. Propagating the
/// error keeps the command from reporting success over a divergent head; the
/// durable retry owner is the boot-time `reconcile_agents_to_events` pass, which
/// re-diffs the still-authoritative on-disk record and re-queues this same row.
///
/// The frozen record still exists (only its linkage was left intact), so it
/// always has a projection to reassert; a missing local record would mean the
/// freeze classification and the store diverged and is treated as an error.
fn converge_frozen_linkage(
    conn: &rusqlite::Connection,
    owner_keys: &nostr::Keys,
    agents: &[ManagedAgentRecord],
    d_tag: &str,
) -> Result<(), String> {
    let local = agents
        .iter()
        .find(|record| record.pubkey == d_tag)
        .ok_or_else(|| {
            format!("inbound 30177 convergence: frozen record {d_tag} not found locally")
        })?;
    crate::managed_agents::reconcile::retain_agent_record(conn, owner_keys, local)
        .map_err(|e| format!("inbound 30177 convergence re-retain failed for {d_tag}: {e}"))?;
    Ok(())
}

/// Merge an inbound kind:30176 team projection into the local set.
///
/// Matches the local record whose `id` equals the event's d-tag (the d-tag IS
/// the team id — see `build_team_event`). On match, overwrite ONLY the three
/// shared fields (`name`, `description`, `persona_ids`); install-specific local
/// fields (`source_dir`, `is_symlink`, `symlink_target`, `is_builtin`,
/// `version`, `created_at`) are preserved. On no match, insert a fresh record
/// reusing the d-tag as the id so a re-received event stays idempotent —
/// symmetric to the persona path, since a team (like a persona) is a secretless
/// definition that another device may legitimately learn about from the relay.
fn apply_inbound_team(teams: &mut Vec<TeamRecord>, d_tag: String, inbound: TeamEventContent) {
    match teams.iter_mut().find(|record| record.id == d_tag) {
        Some(local) => {
            local.name = inbound.name;
            local.description = inbound.description;
            // `None` means the event came from a client that predates
            // always-publish — its true value is unknown, so preserve
            // local. Only `Some` (including the explicit-clear variants)
            // overwrites. See `TeamEventContent` for the wire rules.
            if let Some(instructions) = inbound.instructions {
                local.instructions = instructions;
            }
            if let Some(persona_ids) = inbound.persona_ids {
                local.persona_ids = persona_ids;
            }
        }
        None => teams.push(TeamRecord {
            id: d_tag,
            name: inbound.name,
            description: inbound.description,
            // Fresh insert has no local value to preserve; `None` from a
            // pre-fix client simply means no known value.
            instructions: inbound.instructions.unwrap_or_default(),
            persona_ids: inbound.persona_ids.unwrap_or_default(),
            is_builtin: false,
            source_dir: None,
            is_symlink: false,
            symlink_target: None,
            version: None,
            created_at: now_iso(),
            updated_at: now_iso(),
        }),
    }
}
