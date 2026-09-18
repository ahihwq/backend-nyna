import 'package:dart_frog/dart_frog.dart';

import '../../../lib/appointment_store.dart';

/// In-memory store for additional public availability set via POST.
/// Key: 'YYYY-MM-DD' -> List of available time slots.
final Map<String, List<String>> _availabilityStore = {};

/// GET /appointments/availability
/// Returns only the time slots the admin has predefined (weekly template +
/// date overrides) for the next 7 days.
///
/// POST /appointments/availability
/// Body: { "date": "2026-08-15", "slots": ["09:00", "10:00", "14:00"] }
Response onRequest(RequestContext context) {
  if (context.request.method == HttpMethod.get) {
    return _getAvailability();
  }

  if (context.request.method == HttpMethod.post) {
    return _setAvailability(context);
  }

  return Response.json(
    statusCode: 405,
    body: {'success': false, 'message': 'Method not allowed'},
  );
}

Response _getAvailability() {
  // Build the next 7 days from now using the admin predefined schedule.
  final now = DateTime.now();
  final days = <String, List<String>>{};
  for (int i = 0; i < 7; i++) {
    final day = DateTime(now.year, now.month, now.day + i);
    final key = _dateKey(day);

    var slots = _availabilityStore[key] ??
        dateOverrides[key] ??
        List<String>.from(weeklyTemplate[day.weekday] ?? const []);

    // Drop slots that have already passed today.
    if (i == 0) {
      slots = slots.where((t) => _timeMinutes(t) > (now.hour * 60 + now.minute))
          .toList();
    }

    if (slots.isNotEmpty) {
      slots.sort();
      days[key] = slots;
    }
  }

  return Response.json(
    body: {
      'success': true,
      'availability': days,
    },
  );
}

int _timeMinutes(String time) {
  final parts = time.split(':');
  final h = int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0;
  final m = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
  return h * 60 + m;
}

String _dateKey(DateTime d) {
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

Future<Response> _setAvailability(RequestContext context) async {
  final body = await context.request.json() as Map<String, dynamic>;

  final date = body['date'] as String?;
  final slots = body['slots'] as List<dynamic>?;

  if (date == null || slots == null) {
    return Response.json(
      statusCode: 400,
      body: {'success': false, 'message': 'date and slots are required'},
    );
  }

  _availabilityStore[date] = slots.cast<String>();

  return Response.json(
    body: {
      'success': true,
      'message': 'Availability updated for $date',
      'date': date,
      'slots': _availabilityStore[date],
    },
  );
}