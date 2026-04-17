import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../middleware.dart';

class _MockRequestContext extends Mock implements RequestContext {}

void main() {
  group('middleware', () {
    test('returns 401 when x-api-key is missing on protected routes', () async {
      final context = _MockRequestContext();
      when(() => context.request).thenReturn(
        Request.get(Uri.parse('http://localhost/users')),
      );

      final response = await middleware((_) async => Response())(context);

      expect(response.statusCode, equals(HttpStatus.unauthorized));
    });

    test('allows request when x-api-key is valid', () async {
      final context = _MockRequestContext();
      when(() => context.request).thenReturn(
        Request.get(
          Uri.parse('http://localhost/users'),
          headers: {'x-api-key': 'dev-api-key'},
        ),
      );

      final response = await middleware(
        (_) async => Response(body: 'ok'),
      )(context);

      expect(response.statusCode, equals(HttpStatus.ok));
      expect(await response.body(), equals('ok'));
    });

    test('bypasses auth for GET /', () async {
      final context = _MockRequestContext();
      when(() => context.request).thenReturn(
        Request.get(Uri.parse('http://localhost/')),
      );

      final response = await middleware(
        (_) async => Response(body: 'welcome'),
      )(context);

      expect(response.statusCode, equals(HttpStatus.ok));
      expect(await response.body(), equals('welcome'));
    });
  });
}
