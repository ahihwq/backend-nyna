import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:scheduling_backend/src/server.dart';
import 'package:scheduling_backend/src/store.dart';
import 'package:scheduling_backend/src/router.dart';
import 'package:test/test.dart';

void main() {
  group('SchedulingServer (live HTTP)', () {
    late AppointmentStore store;
    late SchedulingServer server;
    late HttpClient client;
    late int port;

    setUp(() async {
      store = AppointmentStore();
      await store.seedDemoSlots('2026-08-27', capacity: 1);
      final controller = AppController(store);
      server = SchedulingServer(controller, address: '127.0.0.1', port: 0);
      port = await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      store.dispose();
    });

    Future<(int, Map<String, dynamic>)> postJson(String path, String body,
        {String? auth}) async {
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
      if (auth != null) {
        req.headers.set(HttpHeaders.authorizationHeader, auth);
      }
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final json = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      return (res.statusCode, json);
    }

    Future<(int, Map<String, dynamic>)> getJson(String path, {String? auth}) async {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      if (auth != null) {
        req.headers.set(HttpHeaders.authorizationHeader, auth);
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final json = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      return (res.statusCode, json);
    }

    test('guest cannot book (401) but can view slots (200)', () async {
      final slots = await getJson('/api/slots?date=2026-08-27');
      expect(slots.$1, 200);
      expect((slots.$2['slots'] as List).length, 4);

      final guest = await postJson(
        '/api/bookings',
        '{"slotId":"s1","userId":"g1","userName":"G","userEmail":"g@x.com"}',
      );
      expect(guest.$1, 401);
      expect(store.totalBookings, 0);
    });

    test('authenticated booking succeeds (201) and shows in admin counts', () async {
      final created = await postJson(
        '/api/bookings',
        '{"slotId":"s1","userId":"u1","userName":"Nguyễn A","userEmail":"a@x.com"}',
        auth: 'Bearer dev-token',
      );
      expect(created.$1, 201);
      expect(created.$2['slotId'], 's1');

      final admin = await getJson(
        '/api/slots/s1/bookings',
        auth: 'Bearer dev-token',
      );
      expect(admin.$1, 200);
      expect(admin.$2['count'], 1);
    });

    test('capacity 1: 2nd authenticated attempt is a 409 (no over-booking)', () async {
      final first = await postJson(
        '/api/bookings',
        '{"slotId":"s1","userId":"u1","userName":"A","userEmail":"a@x.com"}',
        auth: 'Bearer dev-token',
      );
      expect(first.$1, 201);
      final second = await postJson(
        '/api/bookings',
        '{"slotId":"s1","userId":"u2","userName":"B","userEmail":"b@x.com"}',
        auth: 'Bearer dev-token',
      );
      expect(second.$1, 409);
      expect(store.totalBookings, 1);
    });

    test('SSE /api/events pushes a booking.created event in realtime', () async {
      // Open an SSE stream (GET, long-lived).
      final sseReq =
          await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/events'));
      final sseRes = await sseReq.close();
      expect(sseRes.statusCode, 200);

      final completer = Completer<Map<String, dynamic>>();
      final buffer = StringBuffer();
      late StreamSubscription<String> sub;
      sub = sseRes.transform(utf8.decoder).listen((chunk) {
        buffer.write(chunk);
        final text = buffer.toString();
        final dataLine = text.split('\n').cast<String?>().firstWhere(
              (line) => line?.startsWith('data: ') == true,
              orElse: () => null,
            );
        if (dataLine != null) {
          final firstData = dataLine.substring('data: '.length);
          try {
            completer.complete(jsonDecode(firstData) as Map<String, dynamic>);
          } catch (_) {
            // keep waiting for a complete line
          }
        }
      });

      // Trigger a booking after subscribing.
      final created = await postJson(
        '/api/bookings',
        '{"slotId":"s2","userId":"u1","userName":"A","userEmail":"a@x.com"}',
        auth: 'Bearer dev-token',
      );
      expect(created.$1, 201);

      final event = await completer.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(event['type'], 'booking.created');
      final booking = event['booking'] as Map<String, dynamic>;
      expect(booking['slotId'], 's2');
    });
  });
}