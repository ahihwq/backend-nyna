// lib/src/router.dart
/// Pure HTTP routing + authentication for the scheduling API.
///
/// Kept free of dart:io network types so it can be unit-tested without a live
/// socket. The dart:io server in [server.dart] translates between these
/// neutral types and real `HttpRequest`/`HttpResponse` objects.
library;

import 'dart:convert';

import 'store.dart' show AppointmentStore, Booking, BookingSlotFull,
    BookingInvalid, BookingCreated, BookingResult, BookingSlotNotFound,
    BookingDuplicate, Slot;

/// A normalized incoming HTTP request.
class HandlerRequest {
  const HandlerRequest({
    required this.method,
    required this.path,
    this.query = const {},
    this.headers = const {},
    this.body,
  });

  final String method;
  final String path;

  /// Query parameters (already URL-decoded values).
  final Map<String, String> query;

  /// Headers with lower-cased keys.
  final Map<String, String> headers;

  /// Raw request body (JSON for our endpoints).
  final String? body;

  String? header(String name) => headers[name.toLowerCase()];
}

/// A normalized HTTP response.
class HandlerResponse {
  const HandlerResponse({
    required this.statusCode,
    this.headers = const {},
    this.body,
    this.contentType,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String? body;
  final String? contentType;

  factory HandlerResponse.json(int statusCode, Map<String, dynamic> body,
          [Map<String, String> extraHeaders = const {}]) =>
      HandlerResponse(
        statusCode: statusCode,
        contentType: 'application/json; charset=utf-8',
        body: jsonEncode(body),
        headers: extraHeaders,
      );

  static const HandlerResponse notFound = HandlerResponse(
    statusCode: 404,
    contentType: 'application/json; charset=utf-8',
    body: '{"error":"Không được tìm kiếm"}',
  );

  static const HandlerResponse methodNotAllowed = HandlerResponse(
    statusCode: 405,
    contentType: 'application/json; charset=utf-8',
    body: '{"error":"Method not allowed"}',
  );
}

/// Authorization outcome for an incoming request.
enum AuthKind {
  /// Token present (non-guest). Booking/admin endpoints are allowed.
  authorized,
  /// No/invalid token. The client is treated as a guest and cannot book.
  unauthorized,
  /// Read-only access, always allowed.
  publicRoute,
}

/// CORS headers added to every response from the scheduling API.
const Map<String, String> corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Max-Age': '86400',
};

/// Preflight (OPTIONS) response used by browsers.
HandlerResponse corsPreflight() => HandlerResponse(
      statusCode: 204,
      headers: corsHeaders,
    );

/// Called after a booking is confirmed (fire-and-forget notification hook).
typedef BookingNotifyHook = Future<void> Function(AppointmentStore store,
    Booking booking);

/// The application controller: wires the store + notifications to HTTP.
class AppController {
  AppController(this.store, {this.notifyOnBooking});

  final AppointmentStore store;

  /// Invoked after every confirmed booking (or null to disable). The store is
  /// passed so notifications read secrets/environment at call time.
  final BookingNotifyHook? notifyOnBooking;

  Future<void> _maybeNotify(Booking booking) {
    final hook = notifyOnBooking;
    if (hook == null) return Future.value();
    return Future<void>(() {
      try {
        return hook(store, booking);
      } on Exception catch (_) {
        // Notification failure must never break a successful booking.
      }
    });
  }

  /// Route + dispatch an incoming request. Returns a response ready to send.
  Future<HandlerResponse> handle(HandlerRequest request) async {
    if (request.method == 'OPTIONS') return corsPreflight();

    final segs = request.path.split('/').where((s) => s.isNotEmpty).toList();

    if (segs.length == 2 &&
        segs[0] == 'api' &&
        segs[1] == 'health' &&
        request.method == 'GET') {
      return HandlerResponse.json(200, {'ok': true, 'service': 'scheduling'});
    }

    if (segs.length == 2 && segs[0] == 'api' && segs[1] == 'slots') {
      return request.method == 'GET'
          ? _handleGetSlots(request)
          : HandlerResponse.methodNotAllowed;
    }

    if (segs.length == 2 && segs[0] == 'api' && segs[1] == 'bookings') {
      if (request.method != 'POST') return HandlerResponse.methodNotAllowed;
      final auth = _authorize(request);
      if (auth != AuthKind.authorized) return _unauthorized();
      return _handleCreateBooking(request);
    }

    if (segs.length == 4 &&
        segs[0] == 'api' &&
        segs[1] == 'slots' &&
        segs[3] == 'bookings') {
      if (request.method != 'GET') return HandlerResponse.methodNotAllowed;
      final auth = _authorize(request);
      if (auth != AuthKind.authorized) return _unauthorized();
      return _handleSlotBookings(Uri.decodeQueryComponent(segs[2]));
    }

    if (segs.length == 4 &&
        segs[0] == 'api' &&
        segs[1] == 'users' &&
        segs[3] == 'bookings') {
      if (request.method != 'GET') return HandlerResponse.methodNotAllowed;
      final auth = _authorize(request);
      if (auth != AuthKind.authorized) return _unauthorized();
      return _handleUserBookings(Uri.decodeQueryComponent(segs[2]));
    }

    if (segs.length == 3 &&
        segs[0] == 'api' &&
        segs[1] == 'admin' &&
        segs[2] == 'slots') {
      if (request.method != 'POST') return HandlerResponse.methodNotAllowed;
      final auth = _authorize(request);
      if (auth != AuthKind.authorized) return _unauthorized();
      return _handleCreateSlot(request);
    }

    return HandlerResponse.notFound;
  }
// ---- Authorization ------------------------------------------------------

  AuthKind _authorize(HandlerRequest request) {
    final headerValue = request.header('authorization') ?? '';
    if (!RegExp(r'^Bearer .+').hasMatch(headerValue)) {
      return AuthKind.unauthorized;
    }
    return AuthKind.authorized;
  }

  HandlerResponse _unauthorized() => HandlerResponse.json(
        401,
        {'error': 'Bạn cần đăng nhập để đặt lịch. Đăng nhập ngay.'},
        corsHeaders,
      );

  // ---- Handlers ----------------------------------------------------------

  HandlerResponse _handleGetSlots(HandlerRequest request) {
    final dateParam = request.query['date'] ?? '';
    List<Slot> slots;
    if (dateParam.isNotEmpty) {
      final parsed = DateTime.tryParse(dateParam);
      if (parsed == null) {
        return HandlerResponse.json(
          400,
          {'error': 'Thông tham date không hợp lệ. Định hình YYYY-MM-DD.'},
          corsHeaders,
        );
      }
      slots = store.slotsForDate(parsed);
    } else {
      slots = store.allSlots()
        ..sort((a, b) => a.startTime.compareTo(b.startTime));
    }
    return HandlerResponse.json(
      200,
      {
        'slots': slots.map((s) {
          final json = s.toJson(store.bookingsForSlot(s.id));
          json.remove('taken'); // contract: id,startTime,endTime,capacity,adminNote,remaining
          return json;
        }).toList(),
      },
      corsHeaders,
    );
  }

  Future<HandlerResponse> _handleCreateBooking(HandlerRequest request) async {
    if (request.body == null || request.body!.trim().isEmpty) {
      return HandlerResponse.json(
        400,
        {'error': 'Yêu cầu không có thông tin (body trống).'},
        corsHeaders,
      );
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(request.body!) as Map<String, dynamic>;
    } on FormatException {
      return HandlerResponse.json(
        400,
        {'error': 'JSON tidak hợp lệ.'},
        corsHeaders,
      );
    }

    final slotId = body['slotId'] as String?;
    final userId = body['userId'] as String?;
    final userName = body['userName'] as String?;
    final userEmail = body['userEmail'] as String?;

    if (slotId == null || slotId.trim().isEmpty) return _invalidField('slotId');
    if (userId == null || userId.trim().isEmpty) return _invalidField('userId');
    if (userName == null || userName.trim().isEmpty) {
      return _invalidField('userName');
    }
    if (userEmail == null || userEmail.trim().isEmpty) {
      return _invalidField('userEmail');
    }

    final result = await store.createBooking(
      slotId: slotId,
      userId: userId,
      userName: userName,
      userEmail: userEmail,
    );

    if (result is BookingCreated) {
      // Notifications are fire-and-forget: the booking is already confirmed.
      _maybeNotify(result.booking);
    }
    return _bookingResultToResponse(result);
  }
HandlerResponse _invalidField(String field) => HandlerResponse.json(
        400,
        {'error': 'Trường "$field" là yêu cầu và không có thể быть trống.'},
        corsHeaders,
      );

  HandlerResponse _bookingResultToResponse(BookingResult result) {
    if (result is BookingCreated) {
      final booking = result.booking;
      return HandlerResponse.json(
        201,
        {
          'bookingId': booking.bookingId,
          'slotId': booking.slotId,
          'userId': booking.userId,
          'createdAt': booking.createdAt.toIso8601String(),
        },
        corsHeaders,
      );
    }
    if (result is BookingSlotFull) {
      return HandlerResponse.json(
        409,
        {'error': 'Khung giờ đã đầy, vui lòng chọn khung khác.'},
        corsHeaders,
      );
    }
    if (result is BookingDuplicate) {
      return HandlerResponse.json(
        409,
        {
          'error': 'Bạn đã đặt lịch khung giờ này. Vui lòng chọn khung khác.'
        },
        corsHeaders,
      );
    }
    if (result is BookingSlotNotFound) {
      return HandlerResponse.json(
        404,
        {'error': 'Khung giờ không tồn tại. Xin vui lòng làm mới danh sách.'},
        corsHeaders,
      );
    }
    if (result is BookingInvalid) {
      return HandlerResponse.json(
        400,
        {'error': result.message},
        corsHeaders,
      );
    }
    return HandlerResponse.json(
      500,
      {'error': 'Đã có lỗi trong hệ thống. Vui lòng thử lại.'},
      corsHeaders,
    );
  }

  HandlerResponse _handleSlotBookings(String slotId) {
    final slot = store.slotById(slotId);
    if (slot == null) {
      return HandlerResponse.json(
        404,
        {'error': 'Khung giờ không tồn tại.'},
        corsHeaders,
      );
    }
    final bookings = store.bookingsForSlot(slotId);
    return HandlerResponse.json(
      200,
      {
        'slotId': slotId,
        'bookings': bookings.map((b) => b.toJson()).toList(),
        'count': bookings.length,
      },
      corsHeaders,
    );
  }

  HandlerResponse _handleUserBookings(String userId) {
    final bookings = store.bookingsForUser(userId);
    return HandlerResponse.json(
      200,
      {
        'userId': userId,
        'bookings': bookings.map((b) => b.toJson()).toList(),
        'count': bookings.length,
      },
      corsHeaders,
    );
  }

  Future<HandlerResponse> _handleCreateSlot(HandlerRequest request) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode((request.body ?? '').isEmpty ? '{}' : request.body!) as
          Map<String, dynamic>;
    } on FormatException {
      return HandlerResponse.json(
        400,
        {'error': 'JSON không hợp lệ.'},
        corsHeaders,
      );
    }
    final String? start = body['startTime'] as String?;
    final String? end = body['endTime'] as String?;
    final capacity = body['capacity'] as int?;
    if (start == null || end == null || capacity == null) {
      return HandlerResponse.json(
        400,
        {
          'error':
              'startTime, endTime và capacity là yêu cầu (ISO-8601).'
        },
        corsHeaders,
      );
    }
    final startDt = DateTime.tryParse(start);
    final endDt = DateTime.tryParse(end);
    if (startDt == null || endDt == null) {
      return HandlerResponse.json(
        400,
        {'error': 'startTime/endTime không hợp lệ.'},
        corsHeaders,
      );
    }
    final id = await store.addSlot(
      startTime: startDt,
      endTime: endDt,
      capacity: capacity,
      adminNote: body['adminNote'] as String?,
    );
    return HandlerResponse.json(201, {'id': id, 'created': true}, corsHeaders);
  }
}