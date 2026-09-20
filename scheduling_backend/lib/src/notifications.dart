// lib/src/notifications.dart
/// Notification dispatch for new consultation bookings.
///
/// Sends two kinds of notification to the admin:
///   1. A push via Firebase Cloud Messaging (FCM) — legacy HTTP API.
///   2. An email via SendGrid (SMTP-alternative HTTP API) written in
///      Vietnamese with a highlighted template.
///
/// Both channels are retried up to 3 times with exponential backoff and any
/// final failure is logged (and surfaced in the response for observability).
///
/// Secrets come from environment variables (see `.env.example`):
///   FCM_SERVER_KEY, SENDGRID_API_KEY, EMAIL_FROM, ADMIN_EMAIL.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Callable performing a single push attempt.
typedef PushSender = Future<bool> Function(FcmPayload payload);

/// Callable performing a single email attempt.
typedef EmailSender = Future<bool> Function(EmailPayload payload);

/// Payload sent to Firebase Cloud Messaging.
class FcmPayload {
  FcmPayload({
    required this.title,
    required this.body,
    required this.data,
    this.topic = 'schedule_updates',
  });

  final String title;
  final String body;
  final Map<String, dynamic> data;

  /// Destination: a topic broadcast by default.
  final String topic;

  Map<String, dynamic> toJson() => {
        'to': '/topics/$topic',
        'notification': {'title': title, 'body': body},
        'data': data,
      };
}

/// Payload sent to SendGrid.
class EmailPayload {
  EmailPayload({
    required this.to,
    required this.subject,
    required this.html,
  });

  final String to;
  final String subject;
  final String html;

  Map<String, dynamic> toJson(String from, String fromName) => {
        'personalizations': [
          {
            'to': [
              {'email': to}
            ],
            'subject': subject
          }
        ],
        'from': {'email': from, 'name': fromName},
        'content': [
          {'type': 'text/html', 'value': html}
        ],
      };
}

/// Human-readable subject & body used for push/email, in Vietnamese.
class BookingNotifications {
  const BookingNotifications({
    required this.pushTitle,
    required this.pushBody,
    required this.emailSubject,
    required this.emailHtml,
  });

  final String pushTitle;
  final String pushBody;
  final String emailSubject;
  final String emailHtml;
}

/// Extract "HH:MM" from a full ISO string (or pass through an existing HH:MM).
String _timeOf(String isoOrHm) {
  if (RegExp(r'^([01]?\d|2[0-3]):[0-5]\d$').hasMatch(isoOrHm)) return isoOrHm;
  final dt = DateTime.tryParse(isoOrHm);
  if (dt == null) return isoOrHm;
  return '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

/// Extract "YYYY-MM-DD" from a full ISO string.
String _dateOf(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}
/// Build Vietnamese notifications for a new booking.
BookingNotifications buildBookingNotifications({
  required String userName,
  required String startTimeIso,
}) {
  final time = _timeOf(startTimeIso);
  final date = _dateOf(startTimeIso);

  final emailSubject =
      '[Thông báo] Có người đăng ký khung giờ $startTimeIso';

  return BookingNotifications(
    pushTitle: 'Đặt lịch tư vấn mới',
    pushBody: 'Người dùng $userName đã đặt lịch $time ngày $date',
    emailSubject: emailSubject,
    emailHtml: _adminEmailTemplate(
      userName: userName,
      date: date,
      time: time,
    ),
  );
}

/// Reusable Vietnamese HTML email template with an enlarged, highlighted
/// message and a link to the admin booking list.
String _adminEmailTemplate({
  required String userName,
  required String date,
  required String time,
}) {
  final adminUrl = Platform.environment['ADMIN_BOOKINGS_URL'] ??
      'http://localhost:3000/admin/consultations';
  return '''
<div style="font-family:Arial,Helvetica,sans-serif;max-width:620px;margin:0 auto;">
  <h1 style="color:#2E5A4F;font-size:24px;">📅 Có khung giờ tư vấn mới được đặt</h1>
  <p style="font-size:16px;color:#333333;">
    Chào quản trị viên, xin vui lòng sắp xếp thời gian để hỗ trợ người dùng sau:
  </p>
  <div style="border-left:6px solid #2E5A4F;background:#F4F8F6;padding:18px 20px;border-radius:10px;">
    <p style="font-size:20px;font-weight:700;color:#333333;margin:0 0 8px;">
      Người dùng <span style="color:#B3261E;">$userName</span>
    </p>
    <p style="font-size:18px;color:#333333;margin:0;">
      Khung giờ <strong>${time} ngày $date</strong>
    </p>
  </div>
  <p style="font-size:15px;color:#555555;">
    Bấm vào nút bên dưới để xem danh sách người đăng ký:
  </p>
  <a href="$adminUrl"
     style="display:inline-block;background:#2E5A4F;color:#ffffff;text-decoration:none;
            font-size:16px;font-weight:700;padding:12px 22px;border-radius:8px;">
    Xem danh sách đăng ký
  </a>
  <p style="font-size:13px;color:#999999;margin-top:28px;">
    Email này được gửi tự động từ Nyna Connect. Vui lòng không trả lời trực tiếp.
  </p>
</div>
''';
}
/// Executes [attempt] up to [maxAttempts] times with exponential backoff.
/// [sleep] is injectable so tests can avoid real delays.
Future<bool> retryWithBackoff({
  required Future<bool> Function() attempt,
  int maxAttempts = 3,
  Duration retryDelay = const Duration(milliseconds: 200),
  Future<void> Function(Duration delay)? sleep,
  void Function(String message)? log,
  required String channel,
}) async {
  final doSleep = sleep ?? (Duration d) => Future<void>.delayed(d);
  final logger = log ?? (String m) => stderr.writeln('[notify/$channel] $m');

  for (var attemptNo = 1; attemptNo <= maxAttempts; attemptNo++) {
    try {
      final ok = await attempt();
      if (ok) return true;
      logger('Attempt $attemptNo completed but reported failure.');
    } on Exception catch (e) {
      logger('Attempt $attemptNo failed: $e');
    }
    if (attemptNo < maxAttempts) {
      final backoff = retryDelay * (1 << (attemptNo - 1)); // 200, 400, 800ms
      await doSleep(backoff);
    }
  }
  logger('All $maxAttempts attempts failed.');
  return false;
}

/// Concrete FCM + SendGrid senders using the real HTTP APIs.
const String _fcmUrl = 'https://fcm.googleapis.com/fcm/send';
const String _sendGridUrl = 'https://api.sendgrid.com/v3/mail/send';

Future<bool> _sendFcm(FcmPayload payload) async {
  final key = Platform.environment['FCM_SERVER_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('[notify/fcm] FCM_SERVER_KEY is not set; skipping push.');
    return false;
  }
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(_fcmUrl));
    request.headers.set(HttpHeaders.authorizationHeader, 'key=$key');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload.toJson()));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == 200;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _sendSendGrid(EmailPayload payload) async {
  final key = Platform.environment['SENDGRID_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln(
        '[notify/email] SENDGRID_API_KEY is not set; skipping email.');
    return false;
  }
  final from = Platform.environment['EMAIL_FROM'] ?? 'no-reply@nynaconnect.app';
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(_sendGridUrl));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(payload.toJson(from, 'Nyna Connect')));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == 202;
  } finally {
    client.close(force: true);
  }
}

/// Default real senders (read secrets from the environment at call time).
final PushSender defaultPushSender = _sendFcm;
final EmailSender defaultEmailSender = _sendSendGrid;

/// Mock reminder scheduler. A production implementation would persist this
/// job in a queue; the mock keeps the process-local timer for end-to-end demos.
void scheduleBookingReminder({
  required String userId,
  required String userName,
  required String startTimeIso,
  required String bookingId,
  PushSender? push,
}) {
  final scheduledAt = DateTime.tryParse(startTimeIso);
  if (scheduledAt == null) return;
  final delay = scheduledAt.toUtc().difference(DateTime.now().toUtc());
  if (delay <= Duration.zero) return;
  Timer(delay, () async {
    final sender = push ?? defaultPushSender;
    await retryWithBackoff(
      channel: 'reminder',
      attempt: () => sender(FcmPayload(
        title: 'Nhắc lịch tư vấn',
        body: 'Chào $userName, đã đến giờ tư vấn của bạn.',
        data: {'userId': userId, 'bookingId': bookingId, 'kind': 'reminder'},
        topic: 'user_$userId',
      )),
    );
  });
}
/// Result report for a notification dispatch attempt.
class NotificationReport {
  const NotificationReport({
    required this.pushDelivered,
    required this.emailSent,
    this.pushAttempts = 0,
    this.emailAttempts = 0,
  });

  final bool pushDelivered;
  final bool emailSent;
  final int pushAttempts;
  final int emailAttempts;

  Map<String, dynamic> toJson() => {
        'pushDelivered': pushDelivered,
        'emailSent': emailSent,
        'pushAttempts': pushAttempts,
        'emailAttempts': emailAttempts,
      };
}

/// Sends both channels with retry. Injected senders + sleep keep it testable.
Future<NotificationReport> notifyNewBooking({
  required String userName,
  required String startTimeIso,
  required String slotId,
  required String bookingId,
  PushSender? push,
  EmailSender? email,
  Future<void> Function(Duration delay)? sleep,
  void Function(String message)? log,
}) async {
  final notifications = buildBookingNotifications(
    userName: userName,
    startTimeIso: startTimeIso,
  );

  final to = Platform.environment['ADMIN_EMAIL'];
  if (to == null || to.isEmpty) {
    stderr.writeln('[notify] ADMIN_EMAIL is not set; skipping admin email.');
  }

  var pushAttempts = 0;
  final pushOk = await retryWithBackoff(
    channel: 'fcm',
    sleep: sleep,
    log: log,
    attempt: () async {
      pushAttempts++;
      final sender = push ?? defaultPushSender;
      return sender(FcmPayload(
        title: notifications.pushTitle,
        body: notifications.pushBody,
        data: {'slotId': slotId, 'bookingId': bookingId},
      ));
    },
  );

  var emailAttempts = 0;
  var emailOk = false;
  if (to != null && to.isNotEmpty) {
    emailOk = await retryWithBackoff(
      channel: 'sendgrid',
      sleep: sleep,
      log: log,
      attempt: () async {
        emailAttempts++;
        final sender = email ?? defaultEmailSender;
        return sender(EmailPayload(
          to: to,
          subject: notifications.emailSubject,
          html: notifications.emailHtml,
        ));
      },
    );
  }

  return NotificationReport(
    pushDelivered: pushOk,
    emailSent: emailOk,
    pushAttempts: pushAttempts,
    emailAttempts: emailAttempts,
  );
}