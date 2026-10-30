import 'dart:convert';

import 'package:flutter_rhwp/flutter_rhwp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('virtual unsigned paragraph id does not hide a page', () {
    final source = jsonEncode({
      'pageWidth': 800,
      'pageHeight': 1100,
      'root': {
        'kind': 'page',
        'children': [
          {
            'kind': 'paragraph',
            'ops': [
              {
                'type': 'textRun',
                'bbox': {'x': 0, 'y': 10, 'width': 100, 'height': 20},
                'text': 'body',
                'source': {
                  'stableSourceKey': 'section:1/para:1795/char:0',
                },
              },
              {
                'type': 'textRun',
                'bbox': {'x': 0, 'y': 40, 'width': 100, 'height': 20},
                'text': 'projected note',
                'source': {
                  'stableSourceKey':
                      'section:0/para:18446744073709551615/char:0',
                },
              },
            ],
          },
        ],
      },
    });

    final tree = RhwpLayerTree.fromJsonString(201, source);
    expect(tree.textRuns, hasLength(2));
    expect(tree.textRuns.first.paragraph, 1795);
    expect(tree.textRuns.last.text, 'projected note');
    expect(tree.textRuns.last.paragraph, isNull);
  });
}
