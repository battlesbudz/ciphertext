package chat.simplex.common.model

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import chat.simplex.common.platform.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.coroutines.*
import kotlinx.datetime.Clock
import kotlin.random.Random

// Live (ephemeral) 1:1 sessions — private fork.
//
// Implements the ephemeral session protocol from docs/LIVE_SESSION_PROTOCOL.md
// using existing core primitives (no new native code required):
//
// - Session state lives in this manager (session ID, tokens, next-session invitations).
// - Heartbeats are marked text messages sent every 10 seconds:
//     \u001fLIVE_HB:<sessionId>:<token>
// - Session invitations are marked text messages:
//     \u001fLIVE_INVITE:<sessionId>:<initiatorId>:<token>:<link>
// - Incoming protocol messages are filtered before reaching the UI and deleted
//   from the store (hooked in SimpleXAPI.processChatResponse).
// - If no peer heartbeat arrives within 30 seconds, the session is dead:
//   the contact is fully deleted (messages, keys, queues), all state is wiped.
//   There is NO automatic reconnect. The chat list keeps one retained
//   Reconnect entry (peer display name + single-use next-session
//   invitation); tapping Reconnect starts a brand-new session.
// - Nothing carries over between sessions: new session ID, new tokens,
//   new contact, new invitations, no history.
//
// Relay lifecycle: the per-contact SMP queues are the session's relay. They are
// created with the session's contact and fully destroyed on session end via
// ChatDeleteMode.Full (which deletes server queues). No dedicated relay server
// is provisioned in this prototype; sessions use the user's configured SMP
// servers, and the queue-per-session lifecycle gives the same guarantee:
// the relay exists only while both parties are connected.

object LiveSessionManager {
  const val HEARTBEAT_PREFIX = "\u001fLIVE_HB:"
  const val INVITE_PREFIX = "\u001fLIVE_INVITE:"
  const val HEARTBEAT_INTERVAL_MS = 10_000L
  const val HEARTBEAT_TIMEOUT_MS = 30_000L
  // Grace window after the app backgrounds before the session is wiped.
  // Quick returns (image picker, permission dialog, brief app switch)
  // cancel the pending wipe via onAppForegrounded(); if the app is
  // still backgrounded when the delay elapses, the session is wiped.
  const val BACKGROUND_WIPE_DELAY_MS = 10_000L
  // Random jitter applied to each heartbeat delay so send times do not
  // form an exact 10 s beacon for a timing observer. Worst-case gap
  // between peer heartbeats is ~12 s + network latency, far inside
  // the 30 s timeout, so session liveness is unaffected.
  const val HEARTBEAT_JITTER_MS = 2_000L
  const val WATCHDOG_INTERVAL_MS = 5_000L
  private const val TAG = "LiveSessionManager"

  // UI-observable session state. Null = no active live session.
  val sessionState: MutableState<LiveSessionState?> = mutableStateOf(null)
  // UI-observable: true while a Reconnect-button attempt is in flight.
  val reconnecting: MutableState<Boolean> = mutableStateOf(false)
  // UI-observable retained Reconnect entry. Null = no one to reconnect with.
  // Loaded from durable storage on first access; updated on save/clear.
  val reconnectEntry: MutableState<ReconnectEntry?> = mutableStateOf(loadReconnectEntry())
  // UI-observable: last Reconnect-button failure, shown in the chat-list row.
  val reconnectError: MutableState<String?> = mutableStateOf(null)
  // UI-observable: human-readable status for the banner.
  val statusText: MutableState<String?> = mutableStateOf(null)

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private var heartbeatJob: Job? = null
  private var watchdogJob: Job? = null
  private var reconnectTimeoutJob: Job? = null
  private var backgroundWipeJob: Job? = null

  // Pending outgoing reconnect: display name of the peer we are
  // reconnecting to via the Reconnect button. Set on tap; cleared when
  // the new contact connects (the session starts), on failure, or on
  // timeout. No automatic reconnect is ever attempted from this state.
  private var pendingOutgoingReconnect: String? = null

  data class LiveSessionState(
    val sessionId: String,
    val contactId: Long,
    val contactName: String,
    val myToken: ULong,
    val peerToken: ULong?,
    val myNextInvitation: String,
    val peerNextInvitation: String?,
    val startedAtMillis: Long,
    val lastPeerHeartbeatMillis: Long
  )

  // Reconnect entry: the ONLY live-session record persisted durably.
  // Holds the peer's display name + the peer's single-use next-session
  // invitation. No session ID, tokens, keys, messages, or history are
  // ever persisted. Saved when a session's INVITE exchange completes
  // (so it survives process death), retained across session end, and
  // replaced when the next session exchanges fresh invitations. On
  // failure it stays for retry; the user can dismiss it from the chat list.
  @Serializable
  data class ReconnectEntry(
    val displayName: String,
    val invitation: String
  )

  // Lazy: loadReconnectEntry() runs during reconnectEntry init, so the
  // codec must not depend on property-declaration order.
  private val reconnectJson by lazy { Json { ignoreUnknownKeys = true } }

  private fun loadReconnectEntry(): ReconnectEntry? {
    return try {
      val raw = ChatController.appPrefs.liveSessionReconnectEntry.get() ?: return null
      reconnectJson.decodeFromString<ReconnectEntry>(raw)
    } catch (e: Exception) {
      Log.d(TAG, "loadReconnectEntry failed: $e")
      null
    }
  }

  private fun saveReconnectEntry(entry: ReconnectEntry?) {
    try {
      ChatController.appPrefs.liveSessionReconnectEntry.set(
        if (entry == null) null else reconnectJson.encodeToString(ReconnectEntry.serializer(), entry)
      )
    } catch (e: Exception) {
      Log.d(TAG, "saveReconnectEntry failed: $e")
    }
    reconnectEntry.value = entry
  }

  // Dismiss the retained entry (user action in the chat list).
  fun clearReconnectEntry() {
    saveReconnectEntry(null)
    reconnectError.value = null
  }

  // Re-read the retained entry from durable storage (e.g. first chat-list
  // composition, after the app was killed mid-session).
  fun refreshReconnectEntry() {
    reconnectEntry.value = loadReconnectEntry()
  }

  // One-tap reconnect: consume the retained single-use invitation and
  // start a brand-new live session with that peer — new session ID,
  // tokens, keys, zero carryover. The new session's INVITE exchange
  // stores a fresh entry, replacing this one. On failure the entry
  // stays for retry. The peer accepts the incoming contact request
  // manually; there is no automatic acceptance.
  suspend fun reconnect() {
    if (sessionState.value != null) return
    if (pendingOutgoingReconnect != null) return
    val entry = reconnectEntry.value ?: return
    reconnectError.value = null
    reconnecting.value = true
    pendingOutgoingReconnect = entry.displayName
    statusText.value = "Reconnecting…"
    // Give up after 90s if the peer never accepts / connects.
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = scope.launch {
      delay(90_000L)
      if (pendingOutgoingReconnect != null) {
        pendingOutgoingReconnect = null
        reconnecting.value = false
        reconnectError.value = "Could not reconnect - peer unavailable"
        statusText.value = "Could not reconnect - peer unavailable"
      }
    }
    try {
      val connLink = CreatedConnLink(entry.invitation, null)
      val connection = ChatController.apiConnect(null, incognito = false, connLink = connLink)
      if (connection == null) {
        pendingOutgoingReconnect = null
        reconnecting.value = false
        reconnectTimeoutJob?.cancel()
        reconnectTimeoutJob = null
        reconnectError.value = "Could not reconnect - peer unavailable"
        statusText.value = "Could not reconnect - peer unavailable"
      }
      // On CR.ContactConnected, onContactConnected starts the new session.
    } catch (e: Exception) {
      pendingOutgoingReconnect = null
      reconnecting.value = false
      reconnectTimeoutJob?.cancel()
      reconnectTimeoutJob = null
      reconnectError.value = "Could not reconnect - peer unavailable"
      statusText.value = "Could not reconnect - peer unavailable"
    }
  }

  fun isProtocolMessage(text: String): Boolean =
    text.startsWith(HEARTBEAT_PREFIX) || text.startsWith(INVITE_PREFIX) ||
    // Fallback: if any pipeline stage strips the \u001f control char,
    // the bare prefixes still identify protocol messages. These prefixes
    // are reserved by the live-session protocol; ordinary user text
    // starting with them is treated as protocol, by design.
    text.startsWith("LIVE_HB:") || text.startsWith("LIVE_INVITE:")

  // True if this chat item carries a live-session protocol message
  // (heartbeat or invite). UI-insertion paths filter such items out:
  // a history load can scoop one up before the async delete lands,
  // and nothing removes it afterwards.
  fun isProtocolChatItem(item: ChatItem): Boolean {
    val text = (item.content.msgContent as? MsgContent.MCText)?.text ?: return false
    return isProtocolMessage(text)
  }

  private fun randomSessionId(): String =
    Random.nextBytes(16).joinToString("") { "%02x".format(it) }

  private fun currentUserId(): Long? = ChatController.chatModel.currentUser.value?.userId

  // Start a live session with an existing 1:1 contact. Called from the UI
  // or from onContactConnected after a Reconnect-button tap.
  suspend fun startSession(contactId: Long, contactName: String) {
    if (sessionState.value != null) return
    currentUserId() ?: return
    // A fresh manual start abandons any in-flight Reconnect attempt.
    pendingOutgoingReconnect = null
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = null
    reconnecting.value = false
    reconnectError.value = null

    val sessionId = randomSessionId()
    val myToken = Random.nextLong().toULong()
    val initiatorId = randomSessionId()

    // One-time invitation for the NEXT session (used by the Reconnect button).
    val (invPair, _) = ChatController.apiAddContact(null, incognito = false)
    val myLink = invPair?.first?.connFullLink ?: return

    // Send INVITE to the peer over the current contact.
    val inviteText = "$INVITE_PREFIX$sessionId:$initiatorId:$myToken:$myLink"
    ChatController.apiSendMessages(
      rh = null,
      type = ChatType.Direct,
      id = contactId,
      scope = null,
      composedMessages = listOf(ComposedMessage(null, null, MsgContent.MCText(inviteText), emptyMap()))
    )

    val now = Clock.System.now().toEpochMilliseconds()
    sessionState.value = LiveSessionState(
      sessionId = sessionId,
      contactId = contactId,
      contactName = contactName,
      myToken = myToken,
      peerToken = null,
      myNextInvitation = myLink,
      peerNextInvitation = null,
      startedAtMillis = now,
      lastPeerHeartbeatMillis = now
    )
    statusText.value = "Live session started — everything wipes on exit"
    startTimers()
  }

  // Handle an incoming protocol message. Returns true if it was a live
  // protocol message (caller filters it from the UI). Deletes the message
  // from the store so heartbeats/invites never persist.
  suspend fun handleProtocolMessage(text: String, contactId: Long, chatItemId: Long): Boolean {
    // Accept both the \u001f-marked form and the bare form (in case any
    // pipeline stage strips the control char). Normalize before dispatch
    // so a bare-prefix message is processed + deleted, not just hidden.
    val normalized = text.removePrefix("\u001f")
    when {
      normalized.startsWith("LIVE_HB:") -> {
        handleHeartbeat(normalized, contactId)
        deleteProtocolMessage(contactId, chatItemId)
        return true
      }
      normalized.startsWith("LIVE_INVITE:") -> {
        handleInvite(normalized, contactId)
        deleteProtocolMessage(contactId, chatItemId)
        return true
      }
    }
    return false
  }

  private fun handleHeartbeat(text: String, contactId: Long) {
    val parts = text.removePrefix("LIVE_HB:").split(":")
    if (parts.size != 2) return
    val sessionId = parts[0]
    val token = parts[1].toULongOrNull() ?: return
    val s = sessionState.value ?: return
    // Only accept heartbeats for the current session on the right contact.
    if (s.sessionId != sessionId || s.contactId != contactId) return
    val now = Clock.System.now().toEpochMilliseconds()
    sessionState.value = s.copy(lastPeerHeartbeatMillis = now, peerToken = token)
  }

  private suspend fun handleInvite(text: String, contactId: Long) {
    // Format: <prefix><sessionId>:<initiatorId>:<token>:<link> (link may contain colons)
    val parts = text.removePrefix("LIVE_INVITE:").split(":", limit = 4)
    if (parts.size != 4) return
    val sessionId = parts[0]
    val peerToken = parts[2].toULongOrNull() ?: return
    val peerLink = parts[3]
    val current = sessionState.value

    if (current != null && current.peerToken == null && current.sessionId == sessionId) {
      // Peer's response to our INVITE: complete the session setup.
      sessionState.value = current.copy(peerToken = peerToken, peerNextInvitation = peerLink)
      // The peer's invitation is the Reconnect entry: persist it now so it
      // survives process death and session end.
      saveReconnectEntry(ReconnectEntry(current.contactName, peerLink))
      statusText.value = "Live session active — everything wipes on exit"
      return
    }
    if (current != null) {
      // Already in a session: ignore (prototype does not merge simultaneous starts).
      return
    }
    // Incoming new session request: start as the waiter.
    startSessionAsWaiter(contactId, sessionId, peerToken, peerLink)
  }

  private suspend fun startSessionAsWaiter(contactId: Long, sessionId: String, peerToken: ULong, peerLink: String) {
    if (sessionState.value != null) return
    currentUserId() ?: return

    val myToken = Random.nextLong().toULong()
    val initiatorId = randomSessionId()

    val (invPair, _) = ChatController.apiAddContact(null, incognito = false)
    val myLink = invPair?.first?.connFullLink ?: return

    // Respond with our INVITE (token + next-session invitation).
    val inviteText = "$INVITE_PREFIX$sessionId:$initiatorId:$myToken:$myLink"
    ChatController.apiSendMessages(
      rh = null,
      type = ChatType.Direct,
      id = contactId,
      scope = null,
      composedMessages = listOf(ComposedMessage(null, null, MsgContent.MCText(inviteText), emptyMap()))
    )

    val contactName = (ChatController.chatModel.getContactChat(contactId)?.chatInfo as? ChatInfo.Direct)?.contact?.localDisplayName ?: "?"
    val now = Clock.System.now().toEpochMilliseconds()
    sessionState.value = LiveSessionState(
      sessionId = sessionId,
      contactId = contactId,
      contactName = contactName,
      myToken = myToken,
      peerToken = peerToken,
      myNextInvitation = myLink,
      peerNextInvitation = peerLink,
      startedAtMillis = now,
      lastPeerHeartbeatMillis = now
    )
    // Persist the peer's invitation as the Reconnect entry so it survives
    // process death and session end.
    saveReconnectEntry(ReconnectEntry(contactName, peerLink))
    // Abandon any outgoing Reconnect attempt of our own (both sides tapped):
    // the peer's INVITE wins, so we proceed as waiter on this contact.
    pendingOutgoingReconnect = null
    reconnecting.value = false
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = null
    reconnectError.value = null
    statusText.value = "Live session active — everything wipes on exit"
    startTimers()
  }

  // End the session. The contact is fully deleted (messages, keys, queues).
  // The retained Reconnect entry (display name + single-use invitation)
  // SURVIVES the wipe so the user can reconnect with one tap. There is
  // no automatic reconnect: the Reconnect button is the only reconnect path.
  suspend fun endSession(userInitiated: Boolean) {
    val s = sessionState.value ?: return
    stopTimers()
    sessionState.value = null
    clearReconnectState()

    // Wipe: full delete destroys the contact, all messages, keys, and queues.
    // Nothing carries over: no messages, no keys, no relay state, no history.
    try {
      ChatController.apiDeleteChat(null, ChatType.Direct, s.contactId, ChatDeleteMode.Full(notify = true))
    } catch (e: Exception) {
      // Best effort: state is already cleared.
    }

    // Remove the chat from the UI model and clear the open chat view:
    // the core delete alone leaves stale history on screen.
    removeSessionChatFromUI(s.contactId)

    statusText.value = if (userInitiated) {
      "Live session ended — all messages wiped"
    } else {
      "Live session lost — all messages wiped"
    }
  }

  // Called from SimpleXAPI when a contact connects. If the user tapped
  // Reconnect and this is the expected peer, start the brand-new live
  // session on the new contact. Otherwise do nothing: either the peer
  // will send an INVITE (we are the waiter), or this contact is
  // unrelated to live sessions.
  suspend fun onContactConnected(contact: Contact) {
    val expected = pendingOutgoingReconnect ?: return
    if (contact.localDisplayName != expected) return
    pendingOutgoingReconnect = null
    reconnecting.value = false
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = null
    reconnectError.value = null
    // Fresh session: new ID, new tokens, new invitations. Nothing carries over.
    startSession(contact.apiId, contact.localDisplayName)
  }

  fun clearReconnectState() {
    pendingOutgoingReconnect = null
    reconnecting.value = false
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = null
  }

  // True if this contact is the current live-session contact.
  fun isLiveSessionContact(contactId: Long): Boolean =
    sessionState.value?.contactId == contactId

  // Called when the app is backgrounded (Android MainActivity.onStop).
  // Schedules the session wipe 10 s out instead of wiping immediately,
  // so quick returns (image picker, permission dialog, brief app switch)
  // survive: onAppForegrounded() cancels the pending wipe. If the app
  // is still backgrounded when the delay elapses, the session is wiped.
  // The wipe only applies to the session that was active when the app
  // backgrounded (session-ID check) — if a new session already started,
  // the stale pending wipe is a no-op.
  // Fire-and-forget: if the process dies before the delete lands, the
  // peer's 30 s watchdog (no heartbeats) wipes the peer side anyway.
  fun onAppBackgrounded() {
    val sessionIdAtBackground = sessionState.value?.sessionId ?: return
    backgroundWipeJob?.cancel()
    backgroundWipeJob = scope.launch {
      delay(BACKGROUND_WIPE_DELAY_MS)
      if (sessionState.value?.sessionId != sessionIdAtBackground) return@launch
      try { endSession(userInitiated = true) } catch (e: Exception) { /* best effort */ }
    }
  }

  // Called when the app returns to the foreground (Android MainActivity.onStart).
  // Cancels a pending background wipe so the session stays alive.
  fun onAppForegrounded() {
    backgroundWipeJob?.cancel()
    backgroundWipeJob = null
  }

  // Called when the peer deleted our live-session contact (we received
  // ContactDeletedByContact). Wipe our side too, WITHOUT notifying the
  // peer back — the peer is already gone, so a notify would ping-pong.
  suspend fun onContactDeletedByPeer(contactId: Long) {
    val s = sessionState.value ?: return
    if (s.contactId != contactId) return
    stopTimers()
    sessionState.value = null
    clearReconnectState()
    try {
      ChatController.apiDeleteChat(null, ChatType.Direct, contactId, ChatDeleteMode.Full(notify = false))
    } catch (e: Exception) {
      // Best effort: state is already cleared.
    }
    removeSessionChatFromUI(contactId)
    statusText.value = "Peer left — all messages wiped"
  }

  // Called when the live-session contact was deleted locally (e.g. manual
  // UI delete). The core delete already happened — just tear down the
  // session state and UI, no re-delete, no reconnect.
  suspend fun onLocalChatDeleted(contactId: Long) {
    val s = sessionState.value ?: return
    if (s.contactId != contactId) return
    stopTimers()
    sessionState.value = null
    clearReconnectState()
    removeSessionChatFromUI(contactId)
    statusText.value = "Live session ended — all messages wiped"
  }

  // Remove the session chat from the UI model and clear the open chat
  // view (navigating back to the list). The core delete does not do this.
  private suspend fun removeSessionChatFromUI(contactId: Long) {
    withContext(Dispatchers.Main) {
      val chat = ChatController.chatModel.getContactChat(contactId)
      if (chat != null) {
        ChatController.chatModel.chatsContext.removeChat(chat.remoteHostId, chat.id)
      }
      // The open chat view may still show the session chat even if it was
      // already removed from the list (e.g. manual UI delete) — clear it.
      // ChatId for a direct contact is "@<contactId>".
      if (ChatController.chatModel.chatId.value == "@$contactId") {
        ChatController.chatModel.chatsContext.chatItems.clearAndNotify()
        ChatController.chatModel.chatId.value = null
      }
    }
  }

  private fun startTimers() {
    stopTimers()
    heartbeatJob = scope.launch {
      while (isActive) {
        delay(HEARTBEAT_INTERVAL_MS + Random.nextLong(-HEARTBEAT_JITTER_MS, HEARTBEAT_JITTER_MS + 1))
        try { sendHeartbeat() } catch (e: Exception) { /* keep trying */ }
      }
    }
    watchdogJob = scope.launch {
      while (isActive) {
        delay(WATCHDOG_INTERVAL_MS)
        try { checkTimeout() } catch (e: Exception) { /* keep trying */ }
      }
    }
  }

  private fun stopTimers() {
    heartbeatJob?.cancel()
    watchdogJob?.cancel()
    heartbeatJob = null
    watchdogJob = null
  }

  private suspend fun sendHeartbeat() {
    val s = sessionState.value ?: return
    val text = "$HEARTBEAT_PREFIX${s.sessionId}:${s.myToken}"
    ChatController.apiSendMessages(
      rh = null,
      type = ChatType.Direct,
      id = s.contactId,
      scope = null,
      composedMessages = listOf(ComposedMessage(null, null, MsgContent.MCText(text), emptyMap()))
    )
    // Our own heartbeat echoes back via NewChatItems and is filtered+deleted there.
  }

  private suspend fun checkTimeout() {
    val s = sessionState.value ?: return
    val now = Clock.System.now().toEpochMilliseconds()
    if (now - s.lastPeerHeartbeatMillis > HEARTBEAT_TIMEOUT_MS) {
      endSession(userInitiated = false)
    }
  }

  private suspend fun deleteProtocolMessage(contactId: Long, chatItemId: Long) {
    // The delete is verified: a failed delete leaves a protocol message
    // in the store, where a later history load can surface it in the UI.
    // Retry once after a short delay; the session-end wipe is the backstop.
    for (attempt in 0..1) {
      try {
        val deleted = ChatController.apiDeleteChatItems(null, ChatType.Direct, contactId, null, listOf(chatItemId), CIDeleteMode.cidmInternal)
        if (deleted != null) return
        Log.d(TAG, "deleteProtocolMessage: core returned null (attempt $attempt)")
      } catch (e: Exception) {
        Log.d(TAG, "deleteProtocolMessage failed (attempt $attempt): $e")
      }
      if (attempt == 0) delay(500L)
    }
  }
}
