// routes/notifications/index.dart
// Server-side notification dispatch used by admin actions in production.
//
// POST /notifications
// Body:
//   {
//     "title": "...",                       // Vietnamese title (with diacritics)
//     "body": "...",                         // Vietnamese body
//     "data": { ... },                        // optional payload
//     "topic": "schedule_updates",           // push to a topic (broadcast)
//     "tokens": ["fcm-token-1", ...],        // OR push to specific devices
//     "emails": ["a@example.com", ...],      // SendGrid recipients
//     "emailHighlight": "..."                // optional enlarged/highlighted html
//   }
//
// Reads FCM_SERVER_KEY, SENDGRID_API_KEY and EMAIL_FROM from the environment.
// Returns { success, fcmStatus, emailSent }.
import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:http/http.dart' as http;

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {'success': false, 'message': 'Method not allowed'},
    );
  }

  final body = await context.request.json() as Map<String, dynamic>;
  final kind = (body['kind'] as String?) ?? 'generic';
  final title = (body['title'] as String?) ?? '';
  final message = (body['body'] as String?) ?? '';
  final data = (body['data'] as Map<String, dynamic>?) ?? const {};
  final topic = body['topic'] as String?;
  final tokens = (body['tokens'] as List<dynamic>?)?.cast<String>() ?? [];
  final emails = (body['emails'] as List<dynamic>?)?.cast<String>() ?? [];
  final highlight = body['emailHighlight'] as String?;

  var fcmStatus = 0;
  var emailSent = 0;

  // 1) FCM — legacy HTTP API.
  final fcmKey = Platform.environment['FCM_SERVER_KEY'];
  if (fcmKey != null && fcmKey.isNotEmpty && (topic != null || tokens.isNotEmpty)) {
    Map<String, dynamic> target;
    if (topic != null) {
      target = {'to': '/topics/$topic'};
    } else {
      target = {'registration_ids': tokens};
    }
    try {
      final resp = await http.post(
        Uri.parse('https://fcm.googleapis.com/fcm/send'),
        headers: {
          'Authorization': 'key=$fcmKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          ...target,
          'notification': {'title': title, 'body': message},
          'data': {...data, 'kind': kind},
        }),
      );
      fcmStatus = resp.statusCode;
    } catch (_) {
      fcmStatus = -1;
    }
  }

  // 2) SendGrid email.
  final sendgridKey = Platform.environment['SENDGRID_API_KEY'];
  final from = Platform.environment['EMAIL_FROM'] ?? 'no-reply@nynaconnect.app';
  if (sendgridKey != null && sendgridKey.isNotEmpty) {
    for (final to in emails) {
      try {
        final html = '<div style="font-family:Arial,Helvetica,sans-serif;">'
            '<h1 style="color:#2E5A4F;">$title</h1>'
            '<p style="font-size:16px;color:#333;">$message</p>'
            '${highlight == null ? '' : '<p style="font-size:20px;font-weight:700;'
                'color:#B3261E;background:#FFECEC;padding:14px;border-radius:10px;">$highlight</p>'}'
            '</div>';
        final resp = await http.post(
          Uri.parse('https://api.sendgrid.com/v3/mail/send'),
          headers: {
            'Authorization': 'Bearer $sendgridKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'personalizations': [
              {'to': [{'email': to}], 'subject': title},
            ],
            'from': {'email': from, 'name': 'Nyna Connect'},
            'content': [
              {'type': 'text/html', 'value': html},
            ],
          }),
        );
        if (resp.statusCode == 202) emailSent++;
      } catch (_) {}
    }
  }

  return Response.json(
    body: {
      'success': true,
      'fcmStatus': fcmStatus,
      'emailSent': emailSent,
    },
  );
}