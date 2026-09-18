// bin/server.dart
/// Entrypoint for the consultation scheduling API.
///
///   dart bin/server.dart
///
/// Env vars (see ../.env.example):
///   HOST, PORT, ADMIN_EMAIL, FCM_SERVER_KEY, SENDGRID_API_KEY, EMAIL_FROM,
///   SEED_DEMO (set to "true" to seed demo slots for today).
library;

import 'dart:async';
import 'dart:io';

import 'package:scheduling_backend/src/server.dart';
import 'package:scheduling_backend/src/store.dart';
import 'package:scheduling_backend/src/router.dart';
import 'package:scheduling_backend/src/notifications.dart';

String _env(String name, [String fallback = '']) =>
    Platform.environment[name] ?? fallback;

Future<void> main(List<String> args) async {
  final host = _env('HOST', '127.0.0.1');
  final port = int.tryParse(_env('PORT', '3000')) ?? 3000;

  final store = AppointmentStore();
  if (_env('SEED_DEMO', 'false').toLowerCase() == 'true') {
    final today = '${DateTime.now().year.toString().padLeft(4, '0')}-'
        '${DateTime.now().month.toString().padLeft(2, '0')}-'
        '${DateTime.now().day.toString().padLeft(2, '0')}';
    await store.seedDemoSlots(today);
    stderr.writeln('[scheduling] Seeded demo slots for $today');
  }

  final controller = AppController(
    store,
    notifyOnBooking: (AppointmentStore s, Booking booking) {
      final slot = s.slotById(booking.slotId);
      final startIso = slot?.startTime.toIso8601String() ?? '';
      return notifyNewBooking(
        userName: booking.userName,
        startTimeIso: startIso,
        slotId: booking.slotId,
        bookingId: booking.bookingId,
      );
    },
  );

  final server = SchedulingServer(controller, address: host, port: port);
  final actualPort = await server.start();
  stderr.writeln('Scheduling API listening on http://$host:$actualPort');
  stderr.writeln('  GET  /api/slots?date=YYYY-MM-DD');
  stderr.writeln('  POST /api/bookings        (Authorization: Bearer <token>)');
  stderr.writeln('  GET  /api/slots/{id}/bookings');
  stderr.writeln('  GET  /api/users/{id}/bookings');
  stderr.writeln('  GET  /api/events          (SSE realtime)');
  stderr.writeln('  POST /api/admin/slots     (create an admin slot)');

  await server.done;
}