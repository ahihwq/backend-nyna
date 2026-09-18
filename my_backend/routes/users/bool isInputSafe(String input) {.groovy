bool isInputSafe(String input) {
  // 1. Chặn các từ khóa nhạy cảm (Cần cập nhật thường xuyên)
  final blackList = ['hack', 'bypass', 'ignore previous instructions', 'reveal system prompt'];
  
  // 2. Kiểm tra độ dài (Tránh tấn công làm tràn bộ nhớ/tốn token)
  if (input.length > 1000) return false;

  // 3. Kiểm tra từ khóa
  for (var word in blackList) {
    if (input.toLowerCase().contains(word)) return false;
  }
  return true;
}
String sanitizeInput(String input) {
  // Loại bỏ các ký tự có thể gây lỗi hệ thống hoặc scripts
  return input.replaceAll(RegExp(r'[<>"/\]'), '');
}