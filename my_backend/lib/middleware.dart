import 'package:dart_frog/dart_frog.dart';

Handler middleware(Handler handler) {
  return (context) async {
    final request = context.request;

    // Let root route and CORS preflight pass without auth.
    if (request.method == HttpMethod.options || request.uri.path == '/') {
      return handler(context);
    }

    final apiKey = request.headers['x-api-key'];
    final expectedApiKey = const String.fromEnvironment(
      'API_KEY',
      defaultValue: 'dev-api-key',
    );

    if (apiKey != expectedApiKey) {
      return Response.json(
        statusCode: 401,
        body: {'error': 'Unauthorized: invalid API key'},
      );
    }

    return handler(context);
  };
}
