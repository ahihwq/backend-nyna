import 'package:dart_frog/dart_frog.dart';

Response onRequest(RequestContext context) {
  final users = <Map<String, dynamic>>[
    {'id': 1, 'name': 'Alice'},
    {'id': 2, 'name': 'Bob'},
    {'id': 3, 'name': 'Charlie'},
  ];

  return Response.json(body: users);
}
