import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/agent_notice.dart';

void main() {
  test('parses a bot-to-bot delivery', () {
    final notice = parseAgentNotice('Message from 🤖 Lucy: ship the report');

    expect(notice, isNotNull);
    expect(notice!.kind, AgentNoticeKind.agentMessage);
    expect(notice.sender, 'Lucy');
    expect(notice.headline, 'Message from Lucy');
    expect(notice.body, 'ship the report');
    expect(notice.handle, isNull);
  });

  test('keeps the sender handle when the delivery carries one', () {
    final notice = parseAgentNotice('Message from Lucy (@lucy-ops): status?');

    expect(notice!.sender, 'Lucy');
    expect(notice.handle, 'lucy-ops');
    expect(notice.body, 'status?');
  });

  test('accepts the delivery without the robot glyph', () {
    expect(parseAgentNotice('Message from Max: hi')!.sender, 'Max');
  });

  test('accepts the legacy bracketed form', () {
    final notice = parseAgentNotice("[Message from agent 'Max'] hi there");

    expect(notice!.sender, 'Max');
    expect(notice.body, 'hi there');
  });

  test('keeps multi-line delivery bodies intact', () {
    final notice = parseAgentNotice('Message from Lucy: line one\nline two');

    expect(notice!.body, 'line one\nline two');
  });

  test('parses a background process notification into headline and detail', () {
    final notice = parseAgentNotice(
      '[IMPORTANT: Background process 42 finished\nexit code 0\nall good]',
    );

    expect(notice!.kind, AgentNoticeKind.processNotification);
    expect(notice.headline, 'Background process 42 finished');
    expect(notice.body, 'exit code 0\nall good');
    expect(notice.sender, isNull);
  });

  test('returns null for ordinary user messages', () {
    expect(parseAgentNotice('what can you do?'), isNull);
    expect(parseAgentNotice(''), isNull);
    expect(parseAgentNotice('   '), isNull);
    // A human quoting the convention still needs a colon-delimited sender.
    expect(parseAgentNotice('Message from the logs looked fine'), isNull);
  });

  test(
    'leaves the cron prompt alone — it is not the background-process shape',
    () {
      // Cron runs open with their own [IMPORTANT: …] preamble, which the
      // desktop convention deliberately does not treat as a notice.
      expect(
        parseAgentNotice(
          '[IMPORTANT: You are running as a scheduled cron job. DELIVER '
          'the result to the user.]',
        ),
        isNull,
      );
    },
  );
}
