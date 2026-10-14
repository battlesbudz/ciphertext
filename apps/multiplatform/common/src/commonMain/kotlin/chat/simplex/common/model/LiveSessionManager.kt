package chat.simplex.common.model

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
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
//   the contact is fully deleted (messages, keys, queues), all state is wiped,
//   and both sides automatically start a brand-new session (token race:
//   the smaller token initiates using the stored next-session invitation).
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
  const val WATCHDOG_INTERVAL_MS = 5_000L

  // UI-observable session state. Null = no active live session.
  val sessionState: MutableState<LiveSessionState?> = mutableStateOf(null)
  // UI-observable: true while automatically reconnecting to a new session.
  val reconnecting: MutableState<Boolean> = mutableStateOf(false)
  // UI-observable: human-readable status for the banner.
  val statusText: MutableState<String?> = mutableStateOf(null)

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private var heartbeatJob: Job? = null
  private var watchdogJob: Job? = null
  private var reconnectTimeoutJob: Job? = null

  // Set when a session died and we are establishing a brand-new one.
  // Visible for the auto-accept / auto-start hooks in SimpleXAPI.
  var pendingReconnect: PendingReconnect? = null
    private set

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

  data class PendingReconnect(
    val myToken: ULong,
    val peerToken: ULong,
    val peerNextInvitation: String,
    val iAmInitiator: Boolean
  )

  fun isProtocolMessage(text: String): Boolean =
    text.startsWith(HEARTBEAT_PREFIX) || text.startsWith(INVITE_PREFIX)

  private fun randomSessionId(): String =
    Random.nextBytes(16).joinToString("") { "%02x".format(it) }

  private fun currentUserId(): Long? = ChatController.chatModel.currentUser.value?.userId

  // Start a live session with an existing 1:1 contact. Called from the UI.
  suspend fun startSession(contactId: Long, contactName: String) {
    if (sessionState.value != null) return
    currentUserId() ?: return

    val sessionId = randomSessionId()
    val myToken = Random.nextLong().toULong()
    val initiatorId = randomSessionId()

    // One-time invitation for the NEXT session (used on auto-reconnect).
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
    when {
      text.startsWith(HEARTBEAT_PREFIX) -> {
        handleHeartbeat(text, contactId)
        deleteProtocolMessage(contactId, chatItemId)
        return true
      }
      text.startsWith(INVITE_PREFIX) -> {
        handleInvite(text, contactId)
        deleteProtocolMessage(contactId, chatItemId)
        return true
      }
    }
    return false
  }

  private fun handleHeartbeat(text: String, contactId: Long) {
    val parts = text.removePrefix(HEARTBEAT_PREFIX).split(":")
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
    val parts = text.removePrefix(INVITE_PREFIX).split(":", limit = 4)
    if (parts.size != 4) return
    val sessionId = parts[0]
    val peerToken = parts[2].toULongOrNull() ?: return
    val peerLink = parts[3]
    val current = sessionState.value

    if (current != null && current.peerToken == null && current.sessionId == sessionId) {
      // Peer's response to our INVITE: complete the session setup.
      sessionState.value = current.copy(peerToken = peerToken, peerNextInvitation = peerLink)
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
    pendingReconnect = null
    reconnecting.value = false
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = null
    statusText.value = "Live session active — everything wipes on exit"
    startTimers()
  }

  // End the session. If userInitiated, do not auto-reconnect.
  // Otherwise (timeout), wipe everything and automatically start a new session.
  suspend fun endSession(userInitiated: Boolean) {
    val s = sessionState.value ?: return
    stopTimers()
    sessionState.value = null

    // Wipe: full delete destroys the contact, all messages, keys, and queues.
    // Nothing carries over: no messages, no keys, no relay state, no history.
    try {
      ChatController.apiDeleteChat(null, ChatType.Direct, s.contactId, ChatDeleteMode.Full(notify = true))
    } catch (e: Exception) {
      // Best effort: state is already cleared.
    }

    if (userInitiated) {
      pendingReconnect = null
      reconnecting.value = false
      statusText.value = "Live session ended — all messages wiped"
    } else {
      val peerToken = s.peerToken
      val peerLink = s.peerNextInvitation
      if (peerToken != null && peerLink != null) {
        val iAmInitiator = s.myToken < peerToken
        pendingReconnect = PendingReconnect(s.myToken, peerToken, peerLink, iAmInitiator)
        reconnecting.value = true
        statusText.value = "Session lost — starting a brand-new session…"
        // Give up on the reconnect after 90s if the peer never comes back.
        reconnectTimeoutJob?.cancel()
        reconnectTimeoutJob = scope.launch {
          delay(90_000L)
          if (pendingReconnect != null) {
            pendingReconnect = null
            reconnecting.value = false
            statusText.value = "Could not reconnect — peer unavailable"
          }
        }
        if (iAmInitiator) {
          initiateReconnect()
        } else {
          // Waiter: auto-accept hook handles incoming contact requests.
          // Also catch a request that arrived before we timed out (race).
          acceptPendingContactRequest()
        }
      } else {
        // Session died before the invitation exchange completed: cannot reconnect.
        pendingReconnect = null
        reconnecting.value = false
        statusText.value = "Live session lost — all messages wiped"
      }
    }
  }

  private suspend fun initiateReconnect() {
    val pending = pendingReconnect ?: return
    if (!pending.iAmInitiator) return
    try {
      val connLink = CreatedConnLink(pending.peerNextInvitation, null)
      val connection = ChatController.apiConnect(null, incognito = false, connLink = connLink)
      if (connection == null) {
        // Reconnect failed: stop.
        pendingReconnect = null
        reconnecting.value = false
        statusText.value = "Could not reconnect — peer unavailable"
      }
      // On CR.ContactConnected, the hook below starts the new session.
    } catch (e: Exception) {
      pendingReconnect = null
      reconnecting.value = false
      statusText.value = "Could not reconnect — peer unavailable"
    }
  }

  // Called from SimpleXAPI when a contact request arrives. Auto-accepts if we
  // are the waiter in a pending reconnect.
  suspend fun onContactRequest(contactReqId: Long): Boolean {
    val pending = pendingReconnect ?: return false
    if (pending.iAmInitiator) return false
    return try {
      ChatController.apiAcceptContactRequest(null, incognito = false, contactReqId = contactReqId) != null
    } catch (e: Exception) { false }
  }

  // Accept the most recent pending contact request, if any (race: the
  // initiator's reconnect request may have arrived before we timed out).
  private suspend fun acceptPendingContactRequest() {
    try {
      val reqChat = ChatController.chatModel.chatsContext.chats.value
        .filter { it.chatInfo is ChatInfo.ContactRequest }
        .maxByOrNull { (it.chatInfo as ChatInfo.ContactRequest).contactRequest.createdAt }
      val reqId = (reqChat?.chatInfo as? ChatInfo.ContactRequest)?.contactRequest?.apiId
      if (reqId != null) {
        ChatController.apiAcceptContactRequest(null, incognito = false, contactReqId = reqId)
      }
    } catch (e: Exception) { /* best effort */ }
  }

  // Called from SimpleXAPI when a contact connects. If we are the initiator in
  // a pending reconnect, start the brand-new live session on the new contact.
  suspend fun onContactConnected(contact: Contact) {
    val pending = pendingReconnect ?: return
    if (!pending.iAmInitiator) return
    pendingReconnect = null
    // Fresh session: new ID, new tokens, new invitations. Nothing carries over.
    startSession(contact.apiId, contact.localDisplayName)
  }

  // Called from SimpleXAPI when our auto-accepted contact (waiter) connects.
  // The initiator will send a new INVITE; nothing to do here except clear UI.
  fun onWaiterContactConnected() {
    // The new session starts when the initiator's INVITE arrives.
  }

  fun clearReconnectState() {
    pendingReconnect = null
    reconnecting.value = false
    reconnectTimeoutJob?.cancel()
    reconnectTimeoutJob = null
  }

  private fun startTimers() {
    stopTimers()
    heartbeatJob = scope.launch {
      while (isActive) {
        delay(HEARTBEAT_INTERVAL_MS)
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
    try {
      ChatController.apiDeleteChatItems(null, ChatType.Direct, contactId, null, listOf(chatItemId), CIDeleteMode.cidmInternal)
    } catch (e: Exception) {
      // Best effort: the session-end wipe removes everything anyway.
    }
  }
}
