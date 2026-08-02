// Pure accumulator for streamed assistant tokens, isolated from any screen
// state so a listener can rebuild just the active bubble instead of the
// whole message list on every token.
import 'package:flutter/foundation.dart';

/// Accumulates streamed text and notifies listeners on each append.
///
/// Chat screens create one per in-flight assistant reply and bind a single
/// widget to it (e.g. via [AnimatedBuilder]) so streaming never triggers a
/// screen-level `setState`.
class StreamingBuffer extends ChangeNotifier {
  String _text = '';
  bool _done = false;

  String get text => _text;
  bool get done => _done;

  /// Appends [token] to the accumulated text and notifies listeners.
  void append(String token) {
    if (token.isEmpty) return;
    _text += token;
    notifyListeners();
  }

  /// Marks the stream as finished without altering the accumulated text.
  void complete() {
    _done = true;
    notifyListeners();
  }

  /// Clears the accumulated text and completion state for reuse.
  void reset() {
    _text = '';
    _done = false;
    notifyListeners();
  }
}
