import 'package:flutter_test/flutter_test.dart';
import 'package:gband_monitor/protocol/veepoo_protocol.dart';

void main() {
  test('BandState initializes with zero respiratory rate and updates correctly', () {
    const state = BandState();
    expect(state.respiratoryRate, 0);
    expect(state.hr, 0);
    expect(state.spo2, 0);

    final updated = state.copyWith(respiratoryRate: 18, spo2: 98, hr: 72);
    expect(updated.respiratoryRate, 18);
    expect(updated.spo2, 98);
    expect(updated.hr, 72);
  });
}
