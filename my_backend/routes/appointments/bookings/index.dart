import 'package:dart_frog/dart_frog.dart';

import '../../../lib/appointment_store.dart';

/// GET /appointments/bookings
/// Returns all bookings (admin view).
///
/// POST /appointments/bookings
/// Body: { "studentName": "Nguyen Van A", "date": "2026-08-15", "time": "09:00" }
Response onRequest(RequestContext context) {
  if (context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        'success': true,
        'bookings': bookings.reversed.toList(),
      },
    );
  }

  if (context.request.method == HttpMethod.post) {
    return _createBooking(context);
  }

  if (context.request.method == HttpMethod.options) {
    return _corsResponse();
  }

  return _corsResponse(405);
}

Response _corsResponse([int statusCode = 200]) {
  return Response(
    statusCode: statusCode,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
    body: statusCode == 200 ? '' : null,
  );
}

Future<Response> _createBooking(RequestContext context) async {
  final body = await context.request.json() as Map<String, dynamic>;

  final studentName = body['studentName'] as String?;
  final date = body['date'] as String?;
  final time = body['time'] as String?;

  if (studentName == null || date == null || time == null) {
    return Response.json(
      statusCode: 400,
      body: {
        'success': false,
        'message': 'studentName, date and time are required',
      },
    );
  }

  final booking = <String, dynamic>{
    'id': 'bk_${DateTime.now().millisecondsSinceEpoch}',
    'studentName': studentName,
    'date': date,
    'time': time,
    'createdAt': DateTime.now().toIso8601String(),
    'status': 'confirmed',
  };

  bookings.add(booking);

  return Response.json(
    statusCode: 201,
    body: {
      'success': true,
      'message': 'Booking created successfully',
      'booking': booking,
    },
  );
}