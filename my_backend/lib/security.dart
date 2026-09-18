bool isInputSafe(String input) {
  // Layer 1: Input filter (basic, extendable) — đồng bộ với app `ContentSafety`.
  final blackList = <String>[
    'hack',
    'bypass',
    'ignore previous instructions',
    'reveal system prompt',
    'prompt injection',
    'tự tử',
    'tự sát',
    'chết đi',
    'giết người',
    'làm bom',
    'khủng bố',
    'mua súng',
    'cưỡng hiếp',
    'kế hoạch tấn công',
  ];

  if (input.length > 1000) return false;

  final lower = input.toLowerCase();
  for (final word in blackList) {
    if (lower.contains(word)) return false;
  }
  return true;
}

String sanitizeInput(String input) {
  // Remove characters that may break downstream parsing / prompt formatting.
  return input.replaceAll(RegExp(r'[<>"/\\\]]'), '');
}

