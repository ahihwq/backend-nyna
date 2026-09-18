import 'dart:async';

import 'package:scheduling_backend/src/notifications.dart';
import 'package:test/test.dart';

void main() {
  group('Notifications', () {
    test('buildBookingNotifications produces Vietnamese subject and highlighted HTML', () {
      final n = buildBookingNotifications(
        userName: 'Nguyễn Văn A',
        startTimeIso: '2026-08-27T09:30:00',
      );
      expect(n.pushTitle, 'Đặt lịch tư vấn mới');
      expect(n.pushBody, contains('Nguyễn Văn A'));
      expect(n.pushBody, contains('09:30'));
      expect(n.emailSubject,
          '[Thông báo] Có người đăng ký khung giờ 2026-08-27T09:30:00');
      expect(n.emailHtml, contains('Nguyễn Văn A'));
      expect(n.emailHtml, contains('09:30 ngày 2026-08-27'));
      expect(n.emailHtml, contains('admin/consultations'));
      expect(n.emailHtml, contains('<strong>'));
    });

    test('retryWithBackoff retries a failing sender up to 3 times', () async {
      var attempts = 0;
      final ok = await retryWithBackoff(
        channel: 'test',
        sleep: (Duration d) => Future.value(),
        attempt: () async {
          attempts++;
          return false;
        },
      );
      expect(ok, isFalse);
      expect(attempts, 3);
    });

    test('retryWithBackoff stops retrying once a sender succeeds', () async {
      var attempts = 0;
      final ok = await retryWithBackoff(
        channel: 'test',
        sleep: (Duration d) => Future.value(),
        attempt: () async {
          attempts++;
          return attempts == 2;
        },
      );
      expect(ok, isTrue);
      expect(attempts, 2);
    });

    test('exponential backoff delay doubles each retry', () async {
      final delays = <Duration>[];
      final ok = await retryWithBackoff(
        channel: 'test',
        retryDelay: const Duration(milliseconds: 10),
        sleep: (Duration d) async => delays.add(d),
        attempt: () async => false,
      );
      expect(ok, isFalse);
      expect(delays, hasLength(2)); // 3 attempts → 2 sleeps
      expect(delays[0].inMilliseconds, 10);
      expect(delays[1].inMilliseconds, 20); // double
    });

    test('notifyNewBooking delivers push with the exact Vietnamese payload', () async {
      FcmPayload? received;
      final result = await notifyNewBooking(
        userName: 'Nguyễn A',
        startTimeIso: '2026-08-27T09:30:00',
        slotId: 's1',
        bookingId: 'b1',
        sleep: (Duration d) => Future.value(),
        push: (FcmPayload p) async {
          received = p;
          return true;
        },
        email: (EmailPayload p) async {
          return true;
        },
      );
      expect(result.pushDelivered, isTrue);
      expect(received, isNotNull);
      expect(received!.title, 'Đặt lịch tư vấn mới');
      expect(received!.body, contains('Nguyễn A'));
      expect(received!.data['slotId'], 's1');
      expect(received!.data['bookingId'], 'b1');
    });
  });
}