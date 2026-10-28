import 'package:flutter_test/flutter_test.dart';
import 'package:docnote/core/storage/annotation_store.dart';
import 'package:docnote/features/pdf/data/pdf_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PDF export rejects invalid viewport before opening the source', () async {
    final service = PdfExportService(AnnotationStore());
    for (final width in [0.0, -1.0, double.nan, double.infinity]) {
      await expectLater(
        service.export(
          sourcePath: 'must-not-be-opened.pdf',
          documentId: 'qa',
          title: 'QA',
          annotationReferenceWidth: width,
        ),
        throwsArgumentError,
      );
    }
  });
}
