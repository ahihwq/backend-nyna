import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../../routes/users/index.dart' as route;

class _MockRequestContext extends Mock implements RequestContext {}

void main() {
  group('GET /users', () {
    test('responds with a 200 and list of users in JSON.', () async {
      final context = _MockRequestContext();
      final response = route.onRequest(context);

      expect(response.statusCode, equals(HttpStatus.ok));

      final body = await response.body();
      final users = jsonDecode(body);

      expect(
        users,
        equals([
          {'id': 1, 'name': 'Alice'},
          {'id': 2, 'name': 'Bob'},
          {'id': 3, 'name': 'Charlie'},
        ]),
      );
    });
  });
}
