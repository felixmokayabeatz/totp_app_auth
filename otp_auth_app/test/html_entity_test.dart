import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:beatzlock_auth/screens/legal_document_screen.dart';



void main() {
  String render(String html) => LegalHtmlTestHooks.plainText(html);

  test('resolves the entity that shipped literally in 1.8.0', () {
    expect(render('<p>&middot; Backup and recovery codes.</p>'),
        '· Backup and recovery codes.');
  });

  test('resolves the punctuation a rich-text editor emits', () {
    expect(render('<p>&bull; a &ndash; b &mdash; c &hellip;</p>'),
        '• a – b — c …');
    expect(render('<p>&ldquo;quoted&rdquo; and &lsquo;single&rsquo;</p>'),
        '“quoted” and ‘single’');
    expect(
        render('<p>&copy; 2026 &trade; &reg; 20&deg;</p>'), '© 2026 ™ ® 20°');
  });

  test('resolves numeric and hex references', () {
    expect(render('<p>&#183;&#8212;&#x2026;</p>'), '·—…');
  });

  test('resolves accented letters', () {
    expect(render('<p>caf&eacute; na&iuml;ve &szlig;</p>'), 'café naïve ß');
  });

  test('decodes each reference once, so &amp;lt; stays literal', () {
    expect(render('<p>&amp;lt; &amp;amp; &amp;middot;</p>'),
        '&lt; &amp; &middot;');
  });

  test('leaves an unknown reference visible rather than dropping it', () {
    expect(render('<p>&notarealentity; tail</p>'), '&notarealentity; tail');
  });

  test('ignores a code point that is not a usable character', () {
    expect(render('<p>&#xD800; &#1114112;</p>'), '&#xD800; &#1114112;');
  });

  test('collapses decoded non-breaking spaces like ordinary runs', () {
    expect(render('<p>a&nbsp;&nbsp;&nbsp;b</p>'), 'a b');
  });

  test('inline rendering resolves entities too', () {
    final text = LegalHtmlTestHooks.inlineText(
      '<b>&middot;</b> caf&eacute;&nbsp;au lait',
      const TextStyle(),
    );
    expect(text, '· café au lait');
  });

  group('last updated line', () {
    test('shows the local time, not just the date', () {

      final value = DateTime.parse('2026-08-28T21:47:02.634415+00:00');
      final local = value.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      final mm = local.minute.toString().padLeft(2, '0');

      expect(
        LegalHtmlTestHooks.updatedAt(value),
        'Last updated August ${local.day}, ${local.year} at $hh:$mm',
      );
    });

    test('converts out of UTC rather than printing the raw wall clock', () {
      final utc = DateTime.utc(2026, 8, 28, 21, 47);
      final line = LegalHtmlTestHooks.updatedAt(utc);
      final local = utc.toLocal();
      final hh = local.hour.toString().padLeft(2, '0');
      expect(line, contains('at $hh:'));
      if (local.hour != utc.hour) {
        expect(line, isNot(contains('at 21:')));
      }
    });

    test('says nothing when the server sent no timestamp', () {
      expect(LegalHtmlTestHooks.updatedAt(null), '');
    });
  });
}
