import 'package:google_generative_ai/google_generative_ai.dart';

void main() async {
  // Dán cái mã bạn vừa Copy ở Bước 1 vào đây
  const apiKey = 'AIzaSyCCgQM9X2brJ-yDNVK20MPD_2U1ikveQF4';

  // Chú ý: Dùng 'gemini-1.5-flash' để an toàn và ổn định nhất
  final model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);

  final prompt = 'Chào Gemini, bạn có thể giúp tôi xây dựng ứng dụng Social Support không?';
  final content = [Content.text(prompt)];
  final response = await model.generateContent(content);

  print('Gemini trả lời: ${response.text}');
}