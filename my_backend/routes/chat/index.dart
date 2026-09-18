import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../../lib/chat_personas.dart';
import '../../lib/security.dart';

Future<Response> onRequest(RequestContext context) async {
  final request = context.request;
  if (request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'Method not allowed'},
    );
  }

  final body = await request.body();
  Map<String, dynamic> jsonBody;
  try {
    jsonBody = json.decode(body) as Map<String, dynamic>;
  } catch (_) {
    return Response.json(statusCode: 400, body: {'error': 'Invalid JSON'});
  }

  final personaId = (jsonBody['personaId'] ?? '').toString();
  final userText = (jsonBody['message'] ?? '').toString();
  final sentimentHint = (jsonBody['sentimentHint'] ?? 'neutral').toString();

  if (!isInputSafe(userText)) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'unsafe_input', 'reply': 'Nội dung không phù hợp.'},
    );
  }

  final apiKey = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  if (apiKey.isEmpty) {
    return Response.json(
      statusCode: 500,
      body: {'error': 'missing_gemini_key'},
    );
  }

  final persona = ChatPersonas.byId(personaId);
  final clean = sanitizeInput(userText);

  final sentimentExtra = sentimentHint == 'negative'
      ? '\n\n[Ngữ cảnh: tin nhắn có tín hiệu tâm trạng tiêu cực. Hãy trả lời ngắn, ấm, gợi ý nhẹ: thở chậm, đi dạo ngắn, nhạc không lời — không chẩn đoán lâm sàng, không thay thế chuyên gia.]'
      : sentimentHint == 'positive'
          ? '\n\n[Ngữ cảnh: tin nhắn mang năng lượng tích cực. Khớp giọng điệu vui vẻ, cổ vũ nhẹ.]'
          : '';

  // Layer 2: system instruction + cảm xúc gợi ý
  final model = GenerativeModel(
    model: 'gemini-2.0-flash',
    apiKey: apiKey,
    systemInstruction: Content.system('${persona.systemInstruction}$sentimentExtra'),
  );

  // Layer 3: safety settings
  final safetySettings = <SafetySetting>[
    SafetySetting(HarmCategory.harassment, HarmBlockThreshold.high),
    SafetySetting(HarmCategory.hateSpeech, HarmBlockThreshold.high),
    SafetySetting(HarmCategory.sexuallyExplicit, HarmBlockThreshold.high),
    SafetySetting(HarmCategory.dangerousContent, HarmBlockThreshold.high),
  ];

  try {
    final response = await model.generateContent(
      [Content.text(clean)],
      safetySettings: safetySettings,
    );
    return Response.json(
      body: {
        'reply': response.text ?? 'Mình đang suy nghĩ…',
        'personaId': persona.id,
        'personaName': persona.name,
      },
    );
  } catch (e) {
    return Response.json(
      statusCode: 500,
      body: {'error': 'gemini_error', 'message': e.toString()},
    );
  }
}

