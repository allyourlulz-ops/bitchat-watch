// Bridging header for the bitchat Mac tester (macOS 10.14+).
// Exposes vendored Monocypher 4.0.2 (X25519, Ed25519, ChaCha20-Poly1305) to Swift.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "monocypher.h"
#include "monocypher-ed25519.h"
