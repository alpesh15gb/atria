import 'dart:async';

import 'package:atria/core/sync/live_sync.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saves sync promptly, remote polling catches up, background pauses and resume catches up immediately', () {
    fakeAsync((clock) {
      final pending = StreamController<int>.broadcast(sync: true);
      var runs = 0;
      final live = LiveSync(
        pending: pending.stream,
        sync: () async {
          runs++;
        },
      );
      live.resume();
      clock.elapse(Duration.zero);
      expect(runs, 1);
      pending.add(1);
      pending.add(2);
      clock.elapse(const Duration(milliseconds: 299));
      expect(runs, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(runs, 2);
      clock.elapse(const Duration(seconds: 5));
      expect(runs, 3);
      live.pause();
      pending.add(3);
      clock.elapse(const Duration(seconds: 30));
      expect(runs, 3);
      live.resume();
      clock.elapse(Duration.zero);
      expect(runs, 4);
      live.dispose();
      pending.close();
      clock.elapse(const Duration(seconds: 30));
      expect(runs, 4);
    });
  });

  test(
    'saves arriving during sync schedule one follow-up and never overlap',
    () {
      fakeAsync((clock) {
        final pending = StreamController<int>.broadcast(sync: true);
        final blocked = Completer<void>();
        var runs = 0;
        final live = LiveSync(
          pending: pending.stream,
          sync: () async {
            runs++;
            if (runs == 1) await blocked.future;
          },
        );
        live.resume();
        clock.elapse(Duration.zero);
        for (var i = 0; i < 10; i++) {
          pending.add(i + 1);
        }
        clock.elapse(const Duration(seconds: 6));
        expect(runs, 1);
        blocked.complete();
        clock.flushMicrotasks();
        clock.elapse(const Duration(milliseconds: 300));
        expect(runs, 2);
        live.dispose();
        pending.close();
      });
    },
  );
}
