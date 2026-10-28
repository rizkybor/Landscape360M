import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/share/share_location.dart';

// Same cases as src/lib/shareLocation.test.ts (web), plus incoming link parsing

void main() {
  test('makes a link that opens the map at the point, and reads it back', () {
    final url = sharedLocationUrl(-6.789912, 106.983201);
    expect(url, 'https://landscape360.jcdigital.co.id/?at=-6.78991,106.98320');
    final p = parseSharedPoint('?${Uri.parse(url).query}');
    expect(p?.lat, -6.78991);
    expect(p?.lng, 106.9832);
  });

  test('ignores missing or invalid points', () {
    expect(parseSharedPoint(''), isNull);
    expect(parseSharedPoint('?at=abc'), isNull);
    expect(parseSharedPoint('?at=95,10'), isNull);
    expect(parseSharedPoint('?at=10,200'), isNull);
    expect(parseSharedPoint('?at=10'), isNull);
  });

  test('writes a chat message with DMS, decimal, elevation and both links', () {
    final text = buildShareLocationText(
      LocationFix(
        lat: -6.78991,
        lng: 106.9832,
        elevation: 2958.4,
        accuracy: 6.2,
        time: DateTime(2026, 10, 26, 8, 5).millisecondsSinceEpoch,
      ),
      'Budi',
    );
    expect(text, contains("📍 Lokasi Budi / Budi's location"));
    expect(text, contains('6°47\'23.68" S 106°58\'59.52" E'));
    expect(text, contains('-6.78991, 106.98320'));
    expect(text, contains('2958 mdpl · ±6 m · 26/10 08:05'));
    expect(text, contains('https://maps.google.com/?q=-6.78991,106.98320'));
    expect(text, contains('Landscape 360: https://landscape360.jcdigital.co.id/?at=-6.78991,106.98320'));
    expect(whatsappShareUrl(text), startsWith('https://wa.me/?text=%F0%9F%93%8D'));
  });

  test('marked location links: only a 32-character token is accepted', () {
    const token = '0123456789abcdef0123456789abcdef';
    expect(parsePlaceToken('?${Uri.parse(placeLinkUrl(token)).query}'), token);
    expect(parsePlaceToken('?place=short'), isNull);
    expect(parsePlaceToken('?place=0123456789ABCDEF0123456789abcdef'), isNull);
    expect(parsePlaceToken(''), isNull);
  });

  test('writes the message for a shared marked location', () {
    final text = buildPlaceShareText(
      name: 'Pos 3 Gunung Gede',
      categoryLabel: 'Shelter / Pos',
      lat: -6.78991,
      lng: 106.9832,
      elevationM: 2412.6,
      url: 'https://landscape360.jcdigital.co.id/?place=abc',
    );
    expect(
      text,
      '📍 Pos 3 Gunung Gede (Shelter / Pos)\n6°47\'23.68" S 106°58\'59.52" E\n2413 mdpl\n'
      'Open on Landscape 360 (no sign-in needed): https://landscape360.jcdigital.co.id/?place=abc',
    );
  });

  group('incoming links (universal links / app links)', () {
    const token = '0123456789abcdef0123456789abcdef';

    test('opens points, places and areas from the Landscape 360 site only', () {
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?at=-6.5,106.9')), isA<PointLink>());
      expect((IncomingLink.parse(Uri.parse(placeLinkUrl(token)))! as PlaceLink).token, token);
      expect((IncomingLink.parse(Uri.parse(areaLinkUrl(token)))! as AreaLink).token, token);
    });

    test('ignores other hosts, schemes, paths and invalid tokens', () {
      expect(IncomingLink.parse(Uri.parse('https://evil.example/?place=$token')), isNull);
      expect(IncomingLink.parse(Uri.parse('http://landscape360.jcdigital.co.id/?place=$token')), isNull);
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/privacy?at=1,2')), isNull);
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/?place=../../x')), isNull);
      expect(IncomingLink.parse(Uri.parse('https://landscape360.jcdigital.co.id/')), isNull);
    });
  });
}
