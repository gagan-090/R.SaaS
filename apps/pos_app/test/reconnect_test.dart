import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rsaas_pos/state/app_state.dart';

void main() {
  test('live updates reconnect after the connection drops, with growing waits; errors still show', () {
    fakeAsync((t) {
      final conns = <StreamController<int>>[];
      final got = <Object>[];
      final sub = reconnecting(() {
        final c = StreamController<int>();
        conns.add(c);
        return c.stream;
      }).listen(got.add, onError: (Object e) => got.add('error'));
      t.flushMicrotasks();
      expect(conns, hasLength(1));
      conns[0].add(1);
      conns[0].addError('down');
      conns[0].close();
      t.flushMicrotasks();
      expect(got, [1, 'error']);
      t.elapse(const Duration(milliseconds: 999));
      expect(conns, hasLength(1));
      t.elapse(const Duration(milliseconds: 1));
      expect(conns, hasLength(2), reason: 'reconnected after 1 s');
      conns[1].close();
      t.flushMicrotasks();
      t.elapse(const Duration(seconds: 1));
      expect(conns, hasLength(2), reason: 'second wait is 2 s');
      t.elapse(const Duration(seconds: 1));
      expect(conns, hasLength(3));
      conns[2].add(2);
      t.flushMicrotasks();
      expect(got.last, 2);
      sub.cancel();
      conns[2].close();
      t.elapse(const Duration(minutes: 1));
      expect(conns, hasLength(3), reason: 'no reconnects after the app stops listening');
    });
  });
}
