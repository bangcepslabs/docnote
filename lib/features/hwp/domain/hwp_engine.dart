/// HWP/HWPX 구현체를 교체하기 위한 경계. 검증되지 않은 API를 호출하지 않는다.
abstract interface class HwpEngine {
  Future<HwpDocument> open(String path);
  Future<List<int>> renderPage(HwpDocument document, int page);
  Future<String> extractText(HwpDocument document);
  Future<List<int>> exportPdf(HwpDocument document);
  Future<void> dispose(HwpDocument document);
}

class HwpDocument {
  const HwpDocument({required this.path, required this.pageCount});
  final String path;
  final int pageCount;
}
