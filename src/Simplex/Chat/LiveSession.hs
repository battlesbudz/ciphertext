{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Live (ephemeral) 1:1 sessions for the private fork (Phase 2).
--
-- A live session exists only while both parties are connected. When either
-- party disconnects (clean exit, network blip, or heartbeat timeout) the
-- session dies instantly: messages are wiped, keys destroyed, and both
-- parties automatically start a brand NEW session with fresh keys.
-- There is no resume: a dead session can never be reconnected to.
--
-- This module is intentionally self-contained (no import of
-- Simplex.Chat.Controller) so Controller can import it without cycles.
module Simplex.Chat.LiveSession where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Data.Word (Word64)
import qualified Data.Aeson.TH as JQ
import GHC.Generics (Generic)
import Simplex.Messaging.Parsers (sumTypeJSON, dropPrefix)
import UnliftIO.STM

-- | Unique identifier for a live session (UUID string).
type LiveSessionId = Text

-- | Reason a live session ended.
data LiveSessionEndReason
  = LSEndPeerDisconnect -- ^ Peer disconnected
  | LSEndHeartbeatTimeout -- ^ Heartbeat timed out (network blip)
  | LSEndUserEnded -- ^ Local user ended the session
  deriving (Show, Eq, Generic)

$(JQ.deriveToJSON (sumTypeJSON $ dropPrefix "LSEnd") ''LiveSessionEndReason)

-- | Active live session state (internal).
data LiveSession = LiveSession
  { lsSessionId :: LiveSessionId,
    lsContactId :: Int64,
    lsContactName :: Text,
    lsStartedAt :: UTCTime,
    -- | Proof-of-liveness token for deterministic reconnect initiation.
    -- The party with the smaller token initiates the reconnect; the other waits.
    -- Tokens are exchanged via heartbeat messages.
    lsReconnectToken :: Word64,
    lsPeerReconnectToken :: TVar (Maybe Word64),
    lsLastPingSent :: TVar UTCTime,
    lsLastPeerPing :: TVar UTCTime
  }

-- | Public session info sent to UI clients.
data LiveSessionInfo = LiveSessionInfo
  { lsiSessionId :: LiveSessionId,
    lsiContactId :: Int64,
    lsiContactName :: Text,
    lsiStartedAt :: UTCTime
  }
  deriving (Show, Generic)

$(JQ.deriveToJSON (sumTypeJSON $ dropPrefix "lsi") ''LiveSessionInfo)

-- | Sessions keyed by user ID (one active live session per user).
type LiveSessionMap = Map Int64 LiveSession

-- | Magic prefix for heartbeat messages sent over the wire.
-- Mobile clients MUST filter messages with this prefix (never display them).
liveHeartbeatPrefix :: Text
liveHeartbeatPrefix = "\x1fLIVE_HB:"

-- | Build a heartbeat message for a session (includes reconnect token).
mkHeartbeatMsg :: LiveSessionId -> Word64 -> Text
mkHeartbeatMsg sessionId token = liveHeartbeatPrefix <> sessionId <> ":" <> T.pack (show token)

-- | Parse a heartbeat message, returning (session ID, reconnect token).
parseHeartbeatMsg :: Text -> Maybe (LiveSessionId, Word64)
parseHeartbeatMsg t = do
  rest <- T.stripPrefix liveHeartbeatPrefix t
  case T.breakOn ":" rest of
    (sid, tok) | not (T.null sid) && not (T.null tok) ->
      case reads (T.unpack $ T.drop 1 tok) of
        [(n, "")] -> Just (sid, n)
        _ -> Nothing
    _ -> Nothing

-- | Check if a message is a live-session heartbeat.
isHeartbeatMsg :: Text -> Bool
isHeartbeatMsg = T.isPrefixOf liveHeartbeatPrefix

-- | Convert internal session state to public info.
toLiveSessionInfo :: LiveSession -> LiveSessionInfo
toLiveSessionInfo LiveSession {lsSessionId, lsContactId, lsContactName, lsStartedAt} =
  LiveSessionInfo lsSessionId lsContactId lsContactName lsStartedAt
