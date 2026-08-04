// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_one_do_publish/gg_one_do_publish.dart';
import 'package:test/test.dart';

void main() {
  group('GgOneDoPublish()', () {
    group('foo()', () {
      test('should return foo', () async {
        const ggOneDoPublish = GgOneDoPublish();
        expect(ggOneDoPublish.foo(), 'foo');
      });
    });
  });
}
