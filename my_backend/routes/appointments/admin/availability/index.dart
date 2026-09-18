import 'package:dart_frog/dart_frog.dart';

import '../../../../lib/appointment_store.dart';

/// GET /appointments/admin/availability
/// Returns current admin weekly template + date overrides.
///
/// POST /appointments/admin/availability
/// Body:
///   { "action": "set", "weekDay": 1, "slots": ["09:00", "10:00", "14:00"] }
///   { "action": "setDate", "date": "2026-08-15", "slots": ["09:00"] }
///   { "action": "reset" }
///   { "action": "confirm" }
Response onRequest(RequestContext context) {
  if (!context.request.method.name.isEmpty &&
      context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        'success': true,
        'confirmed': availabilityConfirmed,
        'weeklyTemplate': weeklyTemplate
            .map((day, slots) => MapEntry(day.toString(), slots)),
        'dateOverrides': dateOverrides,
      },
    );
  }

  if (context.request.method == HttpMethod.post) {
    return _handleAdminAction(context);
  }

  return Response.json(
    statusCode: 405,
    body: {'success': false, 'message': 'Method not allowed'},
  );
}

Future<Response> _handleAdminAction(RequestContext context) async {
  final body = await context.request.json() as Map<String, dynamic>;

  final action = body['action'] as String?;

  switch (action) {
    case 'set':
      return _setWeeklyDay(body);

    case 'setDate':
      return _setDateOverride(body);

    case 'reset':
      weeklyTemplate.clear();
      dateOverrides.clear();
      availabilityConfirmed = false;
      return Response.json(
        body: {
          'success': true,
          'message': 'All availability has been reset',
          'weeklyTemplate': weeklyTemplate,
          'dateOverrides': dateOverrides,
        },
      );

    case 'confirm':
      availabilityConfirmed = true;
      return Response.json(
        body: {
          'success': true,
          'message': 'Availability confirmed',
          'confirmed': availabilityConfirmed,
          'weeklyTemplate': weeklyTemplate
              .map((day, slots) => MapEntry(day.toString(), slots)),
          'dateOverrides': dateOverrides,
        },
      );

    default:
      return Response.json(
        statusCode: 400,
        body: {
          'success': false,
          'message': 'action must be one of: set, setDate, reset, confirm',
        },
      );
  }
}

/// Set the weekly template for a weekday (1 = Monday .. 7 = Sunday).
Response _setWeeklyDay(Map<String, dynamic> body) {
  final weekDay = body['weekDay'] as int?;
  final slots = body['slots'] as List<dynamic>?;

  if (weekDay == null || weekDay < 1 || weekDay > 7) {
    return Response.json(
      statusCode: 400,
      body: {
        'success': false,
        'message': 'weekDay must be between 1 (Mon) and 7 (Sun)',
      },
    );
  }
  if (slots == null) {
    return Response.json(
      statusCode: 400,
      body: {'success': false, 'message': 'slots is required'},
    );
  }

  weeklyTemplate[weekDay] = slots.cast<String>();
  return Response.json(
    body: {
      'success': true,
      'message': 'Weekly availability set for weekday $weekDay',
      'weekDay': weekDay,
      'slots': weeklyTemplate[weekDay],
    },
  );
}

/// Set availability for a specific date (overrides weekly template).
Response _setDateOverride(Map<String, dynamic> body) {
  final date = body['date'] as String?;
  final slots = body['slots'] as List<dynamic>?;

  if (date == null || slots == null) {
    return Response.json(
      statusCode: 400,
      body: {'success': false, 'message': 'date and slots are required'},
    );
  }

  dateOverrides[date] = slots.cast<String>();
  return Response.json(
    body: {
      'success': true,
      'message': 'Availability set for $date',
      'date': date,
      'slots': dateOverrides[date],
    },
  );
}