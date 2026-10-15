# Ciphertext

Ephemeral 1:1 live-session messenger. No user IDs, no accounts, no history that outlives the conversation.

Ciphertext is a fork of SimpleX Chat, licensed under AGPLv3. It is compatible with the SimpleX network: messages travel over SimpleX relay servers, but Ciphertext adds a strict ephemeral session model on top. When a session ends, for any reason, everything is wiped and both sides start a brand new session. Nothing carries over.

## How it works

- **1:1 live sessions only.** A session exists only while both parties are connected. Group chat is removed.
- **Disconnect kills the session.** Clean exit, network blip, or heartbeat timeout: the session dies, messages, keys, and relay state are destroyed. Dead sessions are never resumed.
- **Fresh reconnect.** Both clients automatically establish a brand new session with fresh keys. There is no resume, and nothing is preserved.
- **10 second grace window.** Leaving the app (backgrounding) gives you 10 seconds to come back, for the image picker, a permission dialog, or a brief app switch. Still gone after 10 seconds and the session is wiped on both sides. Rotation never wipes.
- **Invisible protocol traffic.** Heartbeats and session invites never appear in the chat. Heartbeats are sent with random jitter so they do not form an exact timing beacon.
- **Tor routing (optional).** Route traffic through Orbot with one tap in Settings, Network and servers. Off by default.
- **No user IDs of any kind.** No phone numbers, no emails, no handles. You connect by sharing a one-time invitation link or a long-term address.
- **Private by design.** Your profile lives on your device and is shared only with your contacts. The relay servers see encrypted traffic only.

See [docs/LIVE_SESSION_PROTOCOL.md](docs/LIVE_SESSION_PROTOCOL.md) for the session protocol and [docs/EPHEMERAL_NETWORK_PRIVACY.md](docs/EPHEMERAL_NETWORK_PRIVACY.md) for how IP and timing are handled.

## Install

Install from [GitHub Releases](https://github.com/battlesbudz/ciphertext/releases). Download the APK for your device and install it. Android 8 or later, arm64.

If you have the old `chat.simplex.app` build installed, uninstall it once first: Ciphertext uses a new package name (`chat.ciphertext.app`), so it installs as a separate app and cannot update the old one in place. After that, future releases update in place.

## Privacy

Ciphertext runs no servers. Sessions are ephemeral and wiped on disconnect. See [PRIVACY.md](PRIVACY.md).

## Building

The Android APK is built by GitHub Actions (`.github/workflows/android-apk.yml`). The native libraries (`libsimplex.so`, `libsupport.so`) are extracted from the upstream SimpleX Chat release APK during the build; they are not committed to this repo.

## License

Ciphertext is licensed under [AGPLv3](LICENSE). Ciphertext is a fork of SimpleX Chat, which is also AGPLv3. The SimpleX name and logo are trademarks of SimpleX Chat Ltd and are not used by this fork.
