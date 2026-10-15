# Privacy policy for Ciphertext

Ciphertext is an ephemeral 1:1 messenger. It runs no servers, has no accounts, and keeps no history that outlives the conversation.

## What Ciphertext does not collect

There is no account, no user ID, no phone number, and no email. There is no analytics and no tracking. Ciphertext does not collect your contacts, your messages, or your identity.

## Sessions are ephemeral

A session exists only while both parties are connected. When the session ends, for any reason, the messages, the keys, and the relay state are destroyed. Both clients then establish a brand new session with fresh keys. Nothing from the old session carries over: no history, no keys, no metadata.

Your profile is stored on your own device and shared only with your contacts. No one else sees it.

## What the network sees

Messages travel over SimpleX network relay servers operated by third parties (see [Network & servers](docs/LIVE_SESSION_PROTOCOL.md) in the app settings). Relay servers see encrypted traffic only. They do not see message content, contact names, or profile data.

The relay server you use can see your IP address while you are connected, as can any internet service you use. To hide your IP from the relay, turn on Tor routing in Settings, Network and servers (requires Orbot). See [docs/EPHEMERAL_NETWORK_PRIVACY.md](docs/EPHEMERAL_NETWORK_PRIVACY.md) for the full picture, including what timing analysis can and cannot reveal.

## Notifications

Notification previews show no message content. They only say you have a message.

## Local storage

The app stores its data on your device, encrypted at rest with a passphrase you set. If you lose the passphrase, the local data cannot be recovered.

## About this fork

Ciphertext is a fork of SimpleX Chat, licensed under AGPLv3. It uses the SimpleX network and the SimpleX relay protocol. The SimpleX name and logo are trademarks of SimpleX Chat Ltd and are not used by this fork.
