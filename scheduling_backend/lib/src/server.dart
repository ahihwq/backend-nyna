// lib/src/server.dart
/// dart:io HTTP server glue for the scheduling API.
///
/// Converts the neutral [HandlerRequest] / [HandlerResponse] types used by the
/// pure router into real `dart:io` `HttpRequest` / `HttpResponse` objects, and
/// serves Server-Sent Events (SSE) on `/api/events` for realtime admin updates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'router.dart' show AppController, HandlerRequest, HandlerResponse;

/// Binds, accepts and dispatches HTTP requests for an [AppController].
class SchedulingServer {
  SchedulingServer(this.controller, {this.address = '127.0.0.1', this.port = 3000});

  final AppController controller;
  final String address;
  final int port;

  HttpServer? _server;
  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;

  /// Binds the listener and starts accepting. Returns the actual port used
  /// (relevant when [port] is 0).
  Future<int> start() async {
    final InternetAddress addr;
    if (address == '0.0.0.0' || address == '*') {
      addr = InternetAddress.anyIPv4;
    } else {
      final resolved = await InternetAddress.lookup(address);
      addr = resolved.first;
    }

    final server = await HttpServer.bind(addr, port);
    _server = server;
    // Fire the accept loop without blocking start().
    Future(() => _acceptLoop(server));
    return server.port;
  }

  /// Gracefully shuts the listener down (used by tests / signals).
  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        server.close();
      } on Exception catch (_) {}
    }
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> _acceptLoop(HttpServer server) async {
    try {
      await for (final request in server) {
        // Handle each request in its own future so slow clients (e.g. SSE)
        // never block the accept loop.
        Future<void>(() => _handle(request));
      }
    } on Exception catch (e) {
      stderr.writeln('[scheduling-server] accept loop ended: $e');
    } finally {
      if (!_done.isCompleted) _done.complete();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/api/events') {
        return _handleSse(request);
      }

      final bodyBytes = <int>[];
      await for (final chunk in request) {
        bodyBytes.addAll(chunk);
      }
      String? body;
      if (bodyBytes.isNotEmpty) {
        body = utf8.decode(bodyBytes);
      }

      final handlerRequest = HandlerRequest(
        method: request.method,
        path: path,
        query: _parseQuery(request.uri.query),
        headers: _collectHeaders(request.headers),
        body: body,
      );

      final response = await controller.handle(handlerRequest);
      return _writeResponse(request, response);
    } on Exception catch (e) {
      stderr.writeln('[scheduling-server] handler error: $e');
      return _writeJson(request, 500, {'error': 'Đã có lỗi dalam hệ thống.'});
    }
  }

  // ---- SSE -----------------------------------------------------------------

  Future<void> _handleSse(HttpRequest request) async {
    final response = request.response;
    response.statusCode = 200;
    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-cache');
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Connection', 'keep-alive');
    response.write(': connected\n\n');
    final subscription = controller.store.onBookingCreated.listen((event) async {
      final payload =
          jsonEncode({'type': 'booking.created', 'booking': event.booking.toJson()});
      response.write('data: $payload\n\n');
      await flush(response);
    });
    try {
      await flush(response);
      await response.done;
    } on Exception catch (_) {
      // Client disconnected (or stream closed); nothing to do.
    } finally {
      await subscription.cancel();
      try {
        await response.close();
      } on Exception catch (_) {}
    }
  }

  // ---- Response writers ----------------------------------------------------

  Future<void> _writeResponse(HttpRequest request, HandlerResponse hr) async {
    final response = request.response;
    response.statusCode = hr.statusCode;
    response.headers.contentType = _contentType(hr.contentType);
    for (final entry in hr.headers.entries) {
      response.headers.set(entry.key, entry.value);
    }
    if (hr.body != null && hr.body!.isNotEmpty) {
      response.write(hr.body!);
    }
    await flush(response);
    try {
      await response.close();
    } on Exception catch (_) {}
  }

  Future<void> _writeJson(
      HttpRequest request, int statusCode, Map<String, dynamic> body) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await flush(response);
    try {
      await response.close();
    } on Exception catch (_) {}
  }

  Future<void> flush(HttpResponse response) async {
    try {
      await response.flush();
    } on Exception catch (_) {}
  }

  // ---- Helpers -------------------------------------------------------------

  Map<String, String> _parseQuery(String query) {
    final map = <String, String>{};
    if (query.isEmpty) return map;
    for (final pair in query.split('&')) {
      final idx = pair.indexOf('=');
      if (idx < 0) {
        map[Uri.decodeQueryComponent(pair)] = '';
      } else {
        final key = Uri.decodeQueryComponent(pair.substring(0, idx));
        final value = Uri.decodeQueryComponent(pair.substring(idx + 1));
        map[key] = value;
      }
    }
    return map;
  }

  Map<String, String> _collectHeaders(HttpHeaders headers) {
    final map = <String, String>{};
    headers.forEach((String name, List<String> values) {
      final value = values.isEmpty ? '' : values.first;
      map[name.toLowerCase()] = value;
    });
    return map;
  }

  ContentType _contentType(String? type) {
    if (type == null) return ContentType('text', 'plain', charset: 'utf-8');
    if (type.startsWith('application/json')) return ContentType.json;
    if (type.startsWith('text/event-stream')) {
      return ContentType('text', 'event-stream', charset: 'utf-8');
    }
    return ContentType('text', 'plain', charset: 'utf-8');
  }
}