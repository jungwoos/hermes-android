import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/streaming_buffer.dart';

void main() {
  group('StreamingBuffer', () {
    test('accumulates appended tokens in order', () {
      final buffer = StreamingBuffer();
      buffer.append('Hel');
      buffer.append('lo');
      expect(buffer.text, 'Hello');
      expect(buffer.done, isFalse);
    });

    test('notifies listeners once per non-empty append', () {
      final buffer = StreamingBuffer();
      var notifications = 0;
      buffer.addListener(() => notifications++);

      buffer.append('a');
      buffer.append('');
      buffer.append('b');

      expect(notifications, 2);
      expect(buffer.text, 'ab');
    });

    test('complete marks done without changing accumulated text', () {
      final buffer = StreamingBuffer();
      buffer.append('done soon');
      buffer.complete();
      expect(buffer.done, isTrue);
      expect(buffer.text, 'done soon');
    });

    test('reset clears text and done for reuse', () {
      final buffer = StreamingBuffer();
      buffer.append('leftover');
      buffer.complete();

      buffer.reset();

      expect(buffer.text, '');
      expect(buffer.done, isFalse);
    });
  });
}
