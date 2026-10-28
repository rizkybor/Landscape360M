import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/weather/villages.dart';

void main() {
  const tsv =
      'code\tdesa\tkecamatan\tkabkota\tlat\tlon\n'
      '31.74.07.1010\tCipete Utara\tKebayoran Baru\tKota Adm. Jakarta Selatan\t-6.26173\t106.80436\n'
      '31.74.07.1002\tGunung\tKebayoran Baru\tKota Adm. Jakarta Selatan\t-6.23581\t106.79321\n'
      '31.71.03.1001\tKemayoran\tKemayoran\tKota Adm. Jakarta Pusat\t-6.16000\t106.85000\n'
      'broken line\n'
      '1.2\tBad code\tx\ty\t1\t2\n';

  test('reads the bundled format and skips bad lines', () {
    final v = parseVillagesTsv(tsv);
    expect(v.map((e) => e.code), ['31.74.07.1010', '31.74.07.1002', '31.71.03.1001']);
    expect((v.first.name, v.first.kecamatan), ('Cipete Utara', 'Kebayoran Baru'));
  });

  test('nearest villages, closest first; nothing far outside the data', () {
    final index = VillageIndex(parseVillagesTsv(tsv));
    final near = index.nearest(-6.262, 106.803);
    expect(near.map((v) => v.name), ['Cipete Utara', 'Gunung', 'Kemayoran']);
    expect(index.nearest(-6.262, 106.803, count: 1).single.name, 'Cipete Utara');
    expect(index.nearest(1.35, 103.82), isEmpty); // Singapore: more than 30 km from any village here
  });

  test('the bundled data covers Indonesia and finds the right kelurahan', () {
    final file = File('assets/data/villages.tsv.gz');
    final villages = parseVillagesTsv(utf8.decode(gzip.decode(file.readAsBytesSync())));
    expect(villages.length, greaterThan(80000));
    final index = VillageIndex(villages);
    // A point in Cipete Utara, Kebayoran Baru, Jakarta Selatan
    final v = index.nearest(-6.2617, 106.8043, count: 1).single;
    expect((v.code, v.kabKota), ('31.74.07.1010', 'Kota Adm. Jakarta Selatan'));
    // Kandang Badak, Gunung Gede: a village on the mountain, not in Jakarta
    expect(index.nearest(-6.7899, 106.9832, count: 1).single.code, isNot(startsWith('31.')));
  });
}
