# Live Session Protocol (Phase 2)

Ephemeral 1:1 sessions for the private fork. A live session exists only while
both parties are connected. When either party disconnects (clean exit, network
blip, or heartbeat timeout) the session dies **instantly**: messages wiped,
keys destroyed, relay torn down. Both parties then automatically start a brand
**new** session with fresh keys. There is no resume.

## Design decision (Battles, 2026-10-12)

If a connection blips, the session dies instantly — dead, deleted, nothing
preserved. Both parties automatically reconnect to a **new** session. They get
the reconnect, but nothing is preserved and there is nothing to connect back
to, because once a disconnection happens the old session is gone forever.

## Haskell API

### Starting a session

```
APIStartLiveSession {userId, contactId} -> CRLiveSessionStarted {user, session}
```

Before calling this, the mobile app MUST:
1. Generate a next-session invitation: call `APIAddContact` (or equivalent)
   to create a one-time invitation link. Store it as `nextInvitation`.
2. Send `nextInvitation` to the peer through the current (pre-session) channel,
   or through the session itself as the first message.
3. Store the peer's `nextInvitation` for use on reconnect.

The response includes `LiveSessionInfo {lsiSessionId, lsiContactId,
lsiContactName, lsiStartedAt}`. Show "New secure session" in the UI —
never imply continuity with a previous session.

### Heartbeats

While a session is active, the mobile app MUST:

1. Every 10 seconds, call `APILiveSessionPing {userId}`. The core sends a
   heartbeat marker message to the peer:
   ```
   \x1fLIVE_HB:<sessionId>:<reconnectToken>
   ```
2. **Filter** incoming messages starting with `\x1fLIVE_HB:` — never display
   them. Parse with `parseHeartbeatMsg` semantics: extract session ID and
   peer reconnect token.
3. On receipt, immediately call:
   ```
   APILiveSessionPeerPing {userId, sessionId, peerToken}
   ```
   The core records the peer's last-seen timestamp and token.
4. Track locally: if no heartbeat received from peer within 30 seconds,
   the session is dead. Call:
   ```
   APIEndLiveSession {userId, endReason = LSEndHeartbeatTimeout}
   ```

### Ending a session

```
APIEndLiveSession {userId, endReason} -> CRLiveSessionEnded {user, sessionId, reason}
```

This **wipes everything**: deletes the 1:1 contact, all messages, files, and
keys (`CDMFull`). It also fires the `onLiveSessionEnded` hook (for relay
teardown). This is irreversible.

End reasons:
- `LSEndPeerDisconnect` — peer cleanly disconnected
- `LSEndHeartbeatTimeout` — heartbeat timeout (blip)
- `LSEndUserEnded` — local user ended the session

### Auto-reconnect

On `CRLiveSessionEnded`:

1. Determine who initiates: compare local `lsReconnectToken` with the peer's
   token (received via heartbeat). **Smaller token initiates**; larger waits.
   If peer token was never received (no heartbeat yet), the session starter
   initiates.
2. Initiator: call `APIConnect` with the peer's stored `nextInvitation`.
   This creates a new 1:1 contact with fresh keys.
3. Waiter: auto-accept the incoming contact request from the peer
   (it will arrive via the normal contact request flow).
4. On new contact established: repeat the "Starting a session" steps above
   (generate new next-invitation, exchange, `APIStartLiveSession`).
5. Show "New secure session" — a different session ID proves it's fresh.

**Critical:** Never reuse a session ID. Never attempt to "resume" a dead
session. The old contact is deleted; the old keys are gone.

### Querying session state

```
APIGetLiveSession {userId} -> CRLiveSessionInfo {user, session :: Maybe LiveSessionInfo}
```

## Relay lifecycle

The `ChatHooks.liveSessionHooks` field accepts:

```haskell
LiveSessionHooks
  { onLiveSessionStarted :: LiveSessionInfo -> IO (),
    onLiveSessionEnded :: LiveSessionId -> LiveSessionEndReason -> IO ()
  }
```

- `onLiveSessionStarted`: provision a dedicated relay for the session
  (simplexmq-private), configure the session to use it.
- `onLiveSessionEnded`: **destroy the relay immediately**. The session is
  dead; the relay must not outlive it.

If no hooks are set (`Nothing`, the default), sessions work without dedicated
relays (using the user's configured SMP servers). Relay teardown is then a
no-op.

## Group commands

All 96 group/multi-party commands are rejected at the controller level with
`CECommandError "group chats are disabled in this build (1:1 live sessions
only)"`. This includes creating, joining, managing, or messaging groups,
even programmatically. The 1:1-only invariant is enforced in
`processChatCommand` via `isGroupCommand`.

## Threat model notes

- Heartbeat messages are visible to the SMP server as opaque encrypted
  blobs (same as regular messages). They reveal coarse timing
  (jittered ±2 s) but not content.
- The `nextInvitation` exchange is the only cross-session linkage. Invitations
  are single-use; once consumed, they cannot be reused.
- If the app crashes before `APIEndLiveSession`, heartbeat markers may remain
  in the local database. They contain only session IDs and timestamps, no
  message content. The next app start should call `APIEndLiveSession` for any
  stale session (or simply not resume it).
- Relay servers see encrypted traffic only. Destroying the relay removes the
  queue data; client-side wipe removes keys and messages.

## Implementation Notes (Android)

The Android app implements this protocol natively in Kotlin
(`LiveSessionManager` in `chat.simplex.common.model`), using existing core
primitives. It does not call the Haskell `APILiveSession*` commands, because
the prototype APK is built with prebuilt upstream native libraries (the
Haskell `LiveSession` API is available for future builds that compile the
fork's Haskell core).

Behavioral compliance with this spec:

- **Heartbeat**: sent every 10 seconds as a marked text message
  (with ±2 s random jitter per send, so the send times do not form an
  exact 10 s beacon for a timing observer)
  (`\u001fLIVE_HB:<sessionId>:<token>`), via the standard send-message API.
- **Filtering**: incoming heartbeats and session invites are intercepted in
  the chat-response pipeline, never surface in the UI, and are deleted from
  the local store immediately. The filter applies at EVERY UI-insertion
  point — `NewChatItems`, `ChatItemUpdated`, `ChatItemsStatusesUpdated`,
  plus guards in `ChatsContext.addChatItem`/`upsertChatItem` — because a
  status update for a sent protocol message otherwise re-inserts it into
  the chat view after the initial filter deleted it (the bug found in
  Battles's 2026-10-15 two-phone test). Bare `LIVE_HB:` / `LIVE_INVITE:`
  prefixes are also treated as protocol, in case any stage strips the
  `\u001f` marker.
- **Timeout**: a watchdog checks every 5 seconds; if no peer heartbeat
  arrives within 30 seconds, the session is declared dead.
- **Wipe**: on session end the contact is fully deleted
  (`ChatDeleteMode.Full`), which destroys all messages, keys, and server
  queues. Nothing carries over. The wipe also removes the chat from the
  UI model and clears the open chat view — the core delete alone leaves
  stale history on screen. Leaving the app (Android `onStop`, except
  rotation) ends the session and wipes it immediately; the 30 s timeout
  alone is not enough, since a seconds-long backgrounding never trips
  it. If the peer deleted the session contact, the local side wipes too
  (without notifying back).
- **Reconnect**: next-session invitations are exchanged at session start
  (marked `\u001fLIVE_INVITE:` messages). On timeout, the smaller token
  initiates a new contact via the stored invitation; the waiter auto-accepts.
  A brand-new session starts with fresh IDs, tokens, and invitations.
- **Relay lifecycle**: the per-contact SMP queues are the session's relay.
  They exist only while the session's contact exists and are destroyed by the
  full delete on session end. No dedicated relay server is provisioned in
  this prototype.

The Haskell `LiveSession` API (`APILiveSessionStart`, `APILiveSessionPing`,
etc.) remains the reference implementation of the session state machine and
is invocable via the `/_live` terminal commands for testing.
