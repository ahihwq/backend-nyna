import 'dart:convert';

import 'package:scheduling_backend/src/store.dart';
import 'package:scheduling_backend/src/router.dart';
import 'package:test/test.dart';

void main() {
  group('Router (endpoint contract)', () {
    late AppointmentStore store;
    late AppController controller;

    setUp(() async {
      store = AppointmentStore();
      controller = AppController(store);
      await store.seedDemoSlots('2026-08-27', capacity: 2);
    });

    tearDown(() => store.dispose());

    HandlerRequest jsonPost(String path, String body,
            {Map<String, String>? headers}) =>
        HandlerRequest(
          method: 'POST',
          path: path,
          headers: {'content-type': 'application/json', ...?headers},
          body: body,
        );

    test('GET /api/slots?date returns admin-defined slots with remaining seats', () async {
      final response = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/slots',
        query: {'date': '2026-08-27'},
      ));
      expect(response.statusCode, 200);
      final json = jsonDecode(response.body!) as Map<String, dynamic>;
      final slots = json['slots'] as List<dynamic>;
      expect(slots, isNotEmpty);
      expect(slots.length, 4); // 09:00, 10:00, 14:00, 15:00
      final first = slots.first as Map<String, dynamic>;
      expect(first.keys,
          containsAll(['id', 'startTime', 'endTime', 'capacity', 'remaining']));
      expect(first['remaining'], 2);
    });

    test('GET /api/health returns the scheduling service health contract', () async {
      final response = await controller.handle(const HandlerRequest(
        method: 'GET',
        path: '/api/health',
      ));
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body!), {
        'ok': true,
        'service': 'scheduling',
      });
    });

    test('OPTIONS returns CORS headers for Flutter Web', () async {
      final response = await controller.handle(const HandlerRequest(
        method: 'OPTIONS',
        path: '/api/slots',
      ));
      expect(response.statusCode, 204);
      expect(response.headers['Access-Control-Allow-Origin'], '*');
      expect(response.headers['Access-Control-Allow-Methods'], contains('POST'));
      expect(response.headers['Access-Control-Allow-Headers'], contains('Authorization'));
    });

    test('bulk draft slots stay private until published', () async {
      final created = await controller.handle(jsonPost(
        '/api/admin/slots/bulk',
        '{"slots":[{"startTime":"2026-08-28T11:00:00.000",'
            '"endTime":"2026-08-28T11:45:00.000"}],"capacity":5}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(created.statusCode, 201);
      final id = (jsonDecode(created.body!)['ids'] as List).single as String;

      final publicBefore = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/slots',
        query: {'date': '2026-08-28'},
      ));
      expect(jsonDecode(publicBefore.body!)['slots'], isEmpty);

      final admin = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/admin/slots',
        query: {'date': '2026-08-28'},
        headers: const {'authorization': 'Bearer dev-token'},
      ));
      expect((jsonDecode(admin.body!)['slots'] as List).single['id'], id);

      final published = await controller.handle(jsonPost(
        '/api/admin/slots/publish',
        '{"slotIds":["$id"]}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(published.statusCode, 200);

      final publicAfter = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/slots',
        query: {'date': '2026-08-28'},
      ));
      expect((jsonDecode(publicAfter.body!)['slots'] as List).single['id'], id);
    });

    test('bulk creation does not duplicate the same date and time', () async {
      const body = '{"slots":[{"startTime":"2026-08-28T11:00:00.000",'
          '"endTime":"2026-08-28T11:45:00.000"}],"capacity":5}';
      final first = await controller.handle(jsonPost(
        '/api/admin/slots/bulk', body,
        headers: {'authorization': 'Bearer dev-token'},
      ));
      final second = await controller.handle(jsonPost(
        '/api/admin/slots/bulk', body,
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(first.statusCode, 201);
      expect(second.statusCode, 201);
      expect(jsonDecode(first.body!)['ids'], jsonDecode(second.body!)['ids']);
      expect(store.allSlots(), hasLength(5));
    });

    test('POST /api/bookings → 201 with {bookingId, slotId, userId, createdAt}', () async {
      final response = await controller.handle(jsonPost(
        '/api/bookings',
        '{"slotId":"s1","userId":"u1","userName":"Nguyễn A","userEmail":"a@x.com"}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(response.statusCode, 201);
      final json = jsonDecode(response.body!) as Map<String, dynamic>;
      expect(json.keys, containsAll([
        'bookingId',
        'slotId',
        'userId',
        'createdAt',
      ]));
      expect(json['slotId'], 's1');
    });

    test('POST filling capacity → 409 with the Vietnamese full-slot message', () async {
      Future<HandlerResponse> book(String u, String email) => controller.handle(
            jsonPost(
              '/api/bookings',
              '{"slotId":"s1","userId":"$u","userName":"$u","userEmail":"$email"}',
              headers: {'authorization': 'Bearer dev-token'},
            ),
          );
      expect((await book('u1', 'u1@x.com')).statusCode, 201);
      expect((await book('u2', 'u2@x.com')).statusCode, 201);
      final full = await book('u3', 'u3@x.com');
      expect(full.statusCode, 409);
      final json = jsonDecode(full.body!) as Map<String, dynamic>;
      expect(json['error'], contains('đầy'));
    });

    test('POST /api/bookings as guest (no token) → 401', () async {
      final response = await controller.handle(jsonPost(
        '/api/bookings',
        '{"slotId":"s1","userId":"u1","userName":"A","userEmail":"a@x.com"}',
      ));
      expect(response.statusCode, 401);
      final json = jsonDecode(response.body!) as Map<String, dynamic>;
      expect(json['error'], contains('đăng nhập'));
    });

    test('POST /api/bookings with invalid JSON → 400', () async {
      final response = await controller.handle(jsonPost(
        '/api/bookings',
        'not-json',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(response.statusCode, 400);
    });

    test('GET /api/slots/{id}/bookings returns the count + registrants list', () async {
      await controller.handle(jsonPost(
        '/api/bookings',
        '{"slotId":"s2","userId":"u1","userName":"A","userEmail":"a@x.com"}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      final response = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/slots/s2/bookings',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(response.statusCode, 200);
      final json = jsonDecode(response.body!) as Map<String, dynamic>;
      expect(json['slotId'], 's2');
      expect(json['count'], 1);
      final bookings = json['bookings'] as List<dynamic>;
      expect((bookings.first as Map<String, dynamic>).keys, containsAll([
        'bookingId',
        'userId',
        'userName',
        'createdAt',
      ]));
    });

    test('GET /api/users/{id}/bookings returns the user history', () async {
      await controller.handle(jsonPost(
        '/api/bookings',
        '{"slotId":"s1","userId":"u9","userName":"A","userEmail":"a@x.com"}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      await controller.handle(jsonPost(
        '/api/bookings',
        '{"slotId":"s2","userId":"u9","userName":"A","userEmail":"a@x.com"}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      final response = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/users/u9/bookings',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(response.statusCode, 200);
      final json = jsonDecode(response.body!) as Map<String, dynamic>;
      expect(json['count'], 2);
    });

    test('POST /api/admin/slots creates an admin-defined slot', () async {
      final response = await controller.handle(jsonPost(
        '/api/admin/slots',
        '{"startTime":"2026-08-28T11:00:00","endTime":"2026-08-28T11:45:00",'
            '"capacity":3,"adminNote":"Tư vấn"}',
        headers: {'authorization': 'Bearer dev-token'},
      ));
      expect(response.statusCode, 201);
      expect(store.allSlots(), hasLength(5));
    });
  });
}