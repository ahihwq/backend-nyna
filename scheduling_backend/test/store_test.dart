import 'package:scheduling_backend/src/store.dart';
import 'package:scheduling_backend/src/router.dart';
import 'package:test/test.dart';

void main() {
  group('AppointmentStore booking logic', () {
    late AppointmentStore store;

    setUp(() async {
      store = AppointmentStore();
      await store.seedDemoSlots('2026-08-27', capacity: 2);
    });

    tearDown(() => store.dispose());

    test('booking succeeds and returns BookingCreated with populated fields', () async {
      final result = await store.createBooking(
        slotId: 's1',
        userId: 'u1',
        userName: 'Nguyễn Văn A',
        userEmail: 'a@example.com',
      );
      expect(result, isA<BookingCreated>());
      final created = result as BookingCreated;
      expect(created.booking.bookingId, startsWith('b'));
      expect(created.booking.slotId, 's1');
      expect(created.booking.userId, 'u1');
      expect(created.booking.userName, 'Nguyễn Văn A');
      expect(store.totalBookings, 1);
    });

    test('capacity is enforced: over capacity-2 slot the 3rd booking fails', () async {
      await store.createBooking(
          slotId: 's1', userId: 'u1', userName: 'A', userEmail: 'a@x.com');
      await store.createBooking(
          slotId: 's1', userId: 'u2', userName: 'B', userEmail: 'b@x.com');
      final third = await store.createBooking(
        slotId: 's1',
        userId: 'u3',
        userName: 'C',
        userEmail: 'c@x.com',
      );
      expect(third, isA<BookingSlotFull>());
      expect(store.totalBookings, 2);
    });

    test('the same user cannot book the same slot twice', () async {
      final first = await store.createBooking(
          slotId: 's2', userId: 'u1', userName: 'A', userEmail: 'a@x.com');
      expect(first, isA<BookingCreated>());
      final second = await store.createBooking(
          slotId: 's2', userId: 'u1', userName: 'A', userEmail: 'a@x.com');
      expect(second, isA<BookingDuplicate>());
      expect(store.totalBookings, 1);
    });

    test('blank user info is rejected as invalid', () async {
      final result = await store.createBooking(
          slotId: 's1', userId: 'u1', userName: '   ', userEmail: 'a@x.com');
      expect(result, isA<BookingInvalid>());
      expect(store.totalBookings, 0);
    });

    test('booking a nonexistent slot returns BookingSlotNotFound', () async {
      final result = await store.createBooking(
          slotId: 'nope', userId: 'u1', userName: 'A', userEmail: 'a@x.com');
      expect(result, isA<BookingSlotNotFound>());
    });

    test('concurrent bookings never exceed capacity (atomic booking)', () async {
      final attempts = List.generate(
        10,
        (i) => store.createBooking(
          slotId: 's3',
          userId: 'user$i',
          userName: 'U$i',
          userEmail: 'u$i@x.com',
        ),
      );
      final results = await Future.wait(attempts);
      final successes = results.whereType<BookingCreated>().length;
      final fulls = results.whereType<BookingSlotFull>().length;

      expect(successes, 2); // exactly the capacity
      expect(fulls, 8); // the rest rejected
      expect(store.totalBookings, 2); // no over-booking

      final winners = results
          .whereType<BookingCreated>()
          .map((e) => e.booking.userId)
          .toSet();
      expect(winners.length, 2);
    });
  });

  group('AppController auth (guest handling)', () {
    test('booking without a Bearer token is rejected with 401', () async {
      final store = AppointmentStore();
      addTearDown(() => store.dispose());
      await store.seedDemoSlots('2026-08-27', capacity: 5);
      final controller = AppController(store);
      final response = await controller.handle(HandlerRequest(
        method: 'POST',
        path: '/api/bookings',
        headers: {'content-type': 'application/json'},
        body:
            '{"slotId":"s1","userId":"u1","userName":"A","userEmail":"a@x.com"}',
      ));
      expect(response.statusCode, 401);
      expect(store.totalBookings, 0);
    });

    test('booking with a Bearer token is accepted (201)', () async {
      final store = AppointmentStore();
      addTearDown(() => store.dispose());
      await store.seedDemoSlots('2026-08-27', capacity: 5);
      final controller = AppController(store);
      final response = await controller.handle(HandlerRequest(
        method: 'POST',
        path: '/api/bookings',
        headers: {
          'authorization': 'Bearer abc123',
          'content-type': 'application/json',
        },
        body:
            '{"slotId":"s1","userId":"u1","userName":"A","userEmail":"a@x.com"}',
      ));
      expect(response.statusCode, 201);
      expect(store.totalBookings, 1);
    });

    test('public GET /api/slots works for guests (no token needed)', () async {
      final store = AppointmentStore();
      addTearDown(() => store.dispose());
      await store.seedDemoSlots('2026-08-27', capacity: 5);
      final controller = AppController(store);
      final response = await controller.handle(HandlerRequest(
        method: 'GET',
        path: '/api/slots',
        query: {'date': '2026-08-27'},
      ));
      expect(response.statusCode, 200);
      expect(response.body, contains('"remaining"'));
    });
  });
}