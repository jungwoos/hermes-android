// Bot Mode: messages that ride the `user` role without a human typing them.
//
// When one agent ("bot") messages another, the delivery reaches the recipient
// on the user role — message-role alternation forbids a synthetic system row
// mid-loop, and the agent has to react to it. The same is true of background
// process notifications. Rendering either as a user bubble claims the human
// said it, so the transcript detects them here and shows an attributed notice
// instead.
//
// The wire formats are the Hermes desktop conventions; keep them in sync with
// AGENT_MESSAGE_RE / PROCESS_NOTIFICATION_RE in the desktop client.

enum AgentNoticeKind {
  /// `Message from 🤖 <sender> (@handle): <body>`, or the legacy
  /// `[Message from agent '<sender>'] <body>`.
  agentMessage,

  /// "[IMPORTANT: Background process …]".
  processNotification,
}

class AgentNotice {
  const AgentNotice({
    required this.kind,
    required this.headline,
    required this.body,
    this.sender,
    this.handle,
  });

  final AgentNoticeKind kind;

  /// One-line summary shown collapsed, e.g. "Message from Lucy".
  final String headline;

  /// The delivered text, revealed on demand. Empty when there is none.
  final String body;

  /// Display name of the sending bot, for [AgentNoticeKind.agentMessage].
  final String? sender;

  /// The sender's profile handle when the delivery carried one.
  final String? handle;
}

final RegExp _agentMessage = RegExp(
  r"^(?:Message from (?:\u{1F916}\s*)?([^:\n(]{1,64}?)"
  r"(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})\))?:\s*"
  r"|\[Message from agent '([^']{1,64})'\]\s*)([\s\S]*)$",
  unicode: true,
);

final RegExp _processNotification = RegExp(
  r'^\[IMPORTANT: Background process [\s\S]*\]$',
);

/// Returns the notice carried by [text], or null when it is an ordinary user
/// message. Only call this for messages on the user role.
AgentNotice? parseAgentNotice(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  final agent = _agentMessage.firstMatch(trimmed);
  if (agent != null) {
    // Group 1 is the modern form's sender, group 3 the legacy form's.
    final sender = (agent.group(1) ?? agent.group(3) ?? '').trim();
    if (sender.isNotEmpty) {
      return AgentNotice(
        kind: AgentNoticeKind.agentMessage,
        headline: 'Message from $sender',
        body: (agent.group(4) ?? '').trim(),
        sender: sender,
        handle: agent.group(2),
      );
    }
  }

  if (_processNotification.hasMatch(trimmed)) {
    final inner = trimmed
        .replaceFirst(RegExp(r'^\[IMPORTANT:\s*'), '')
        .replaceFirst(RegExp(r'\]$'), '');
    final newline = inner.indexOf('\n');
    return AgentNotice(
      kind: AgentNoticeKind.processNotification,
      headline: (newline == -1 ? inner : inner.substring(0, newline)).trim(),
      body: newline == -1 ? '' : inner.substring(newline + 1).trim(),
    );
  }

  return null;
}
