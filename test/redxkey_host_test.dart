import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

const dir = String.fromEnvironment(
  'REDXKEY_DIR',
  defaultValue: r'C:\Users\pc\Documents\workspace\redxkey-plugin',
);
const svc = '57d25503-8ae4-47b1-9631-d10dd513a095';
const weightChr = 'c8d1d213-e353-4c68-a9f6-91eb50b95f8c';
const startChr = '2a92b06a-461e-4ea3-b294-5d1a7e351825';

PluginManifest manifest() => PluginManifest.fromJson(
  jsonDecode(File('$dir/manifest.json').readAsStringSync()),
);

class RedxKeyTransport extends PluginBleFixtureTransport {
  RedxKeyTransport(super.physicalId, {this.hasService = true, this.failOn});
  final bool hasService;
  final String? failOn;

  @override
  Future<List<String>> discoverServices() async => hasService ? [svc] : [];

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    if (characteristicUUID.toLowerCase() == failOn) {
      throw Exception('simulated write failure');
    }
  }

  List<String> get sent => [
    for (final w in writes)
      '${w.characteristicUUID.toLowerCase() == weightChr ? 'weight' : 'start'}'
          ':${w.data.join(',')}:${w.withResponse ? 'ack' : 'noack'}',
  ];
}

void main() {
  late PluginManager manager;
  final transports = <RedxKeyTransport>[];

  Future<void> load(Map<String, dynamic> settings) async {
    transports.clear();
    manager = PluginManager(kvStore: FakeKeyValueStoreService());
    await manager.loadPlugin(
      id: manifest().id,
      manifest: manifest(),
      settings: settings,
      jsCode: File('$dir/plugin.js').readAsStringSync(),
    );
  }

  setUp(() => load({}));
  tearDown(() => manager.dispose());

  Future<Sensor> candidate({
    String name = 'RedXKey_01A2',
    String id = 'AA:BB:CC:DD:EE:01',
    bool hasService = true,
    String? failOn,
  }) async {
    final evidence = BleAdvertisementEvidence(name: name, nameComplete: true);
    return await manager.bleService.createCandidate(
          driver: manager.bleService.registry.decide(evidence).drivers.single,
          physicalId: id,
          evidence: evidence,
          admit: () => true,
          createTransport: () {
            final t = RedxKeyTransport(
              id,
              hasService: hasService,
              failOn: failOn,
            );
            transports.add(t);
            return t;
          },
        )
        as Sensor;
  }

  test('matches any advertisement name holding RedXKey, without case', () {
    final r = manager.bleService.registry;
    for (final name in ['RedXKey_01A2', 'redxkey', 'My REDXKEY 7']) {
      expect(
        r
            .decide(BleAdvertisementEvidence(name: name, nameComplete: true))
            .drivers,
        hasLength(1),
        reason: name,
      );
    }
    expect(
      r
          .decide(
            BleAdvertisementEvidence(name: 'LEBREW TEMP', nameComplete: true),
          )
          .drivers,
      isEmpty,
    );
  });

  test('a connected module is idle and offers dispense', () async {
    final sensor = await candidate();
    expect(
      sensor.deviceId,
      'plugin:redxkey.reaplugin:module:aa:bb:cc:dd:ee:01',
    );
    expect(sensor.info.vendor, 'RedxKey');
    expect(sensor.info.commands!.map((c) => c.id), ['dispense']);
    final got = <Map<String, dynamic>>[];
    final sub = sensor.data.listen(got.add);
    await sensor.onConnect();
    await pumpEventQueue();
    expect(got.last, {'state': 'idle', 'lastGrams': 0, 'dispenseCount': 0});
    await sub.cancel();
    await sensor.disconnect();
  });

  test('dispense writes the weight in tenths, then the start byte', () async {
    final sensor = await candidate();
    final got = <Map<String, dynamic>>[];
    final sub = sensor.data.listen(got.add);
    await sensor.onConnect();
    final result = await sensor.execute('dispense', {'grams': 18.5});
    expect(result, {'result': 'ok', 'grams': 18.5});
    expect(transports.single.sent, ['weight:185:ack', 'start:1:ack']);
    await pumpEventQueue();
    expect(
      got.map((s) => s['state']),
      containsAllInOrder(['dispensing', 'idle']),
    );
    expect(got.last, {'state': 'idle', 'lastGrams': 18.5, 'dispenseCount': 1});
    await sub.cancel();
    await sensor.disconnect();
  });

  test('two dispenses on one connection each send weight and start', () async {
    final sensor = await candidate();
    await sensor.onConnect();
    await sensor.execute('dispense', {'grams': 7});
    await sensor.execute('dispense', {'grams': 0.3});
    expect(transports.single.sent, [
      'weight:70:ack',
      'start:1:ack',
      'weight:3:ack',
      'start:1:ack',
    ]);
    await sensor.disconnect();
  });

  test('the write mode setting sends unacknowledged writes', () async {
    await manager.dispose();
    await load({'writeMode': 'withoutResponse'});
    final sensor = await candidate();
    await sensor.onConnect();
    await sensor.execute('dispense', {'grams': 1});
    expect(transports.single.sent, ['weight:10:noack', 'start:1:noack']);
    await sensor.disconnect();
  });

  test(
    'grams outside 0.1 to 25.5 are refused before anything is written',
    () async {
      final sensor = await candidate();
      await sensor.onConnect();
      for (final grams in [0, 0.04, 25.6, -1]) {
        await expectLater(
          sensor.execute('dispense', {'grams': grams}),
          throwsA(anything),
          reason: '$grams',
        );
      }
      expect(transports.single.sent, isEmpty);
      await sensor.disconnect();
    },
  );

  test('a failed weight write fails without sending start', () async {
    final sensor = await candidate(failOn: weightChr);
    await sensor.onConnect();
    final result = await sensor.execute('dispense', {'grams': 9});
    expect(result['result'], 'failed');
    expect(transports.single.sent, ['weight:90:ack']);
    await sensor.disconnect();
  });

  test(
    'a failed start write is uncertain, since the module may have run',
    () async {
      final sensor = await candidate(failOn: startChr);
      final got = <Map<String, dynamic>>[];
      final sub = sensor.data.listen(got.add);
      await sensor.onConnect();
      final result = await sensor.execute('dispense', {'grams': 9});
      expect(result['result'], 'uncertain');
      await pumpEventQueue();
      expect(got.last['state'], 'uncertain');
      await sub.cancel();
      await sensor.disconnect();
    },
  );

  test('fails to connect without the RedxKey service', () async {
    final sensor = await candidate(hasService: false);
    await expectLater(sensor.onConnect(), throwsA(anything));
    await sensor.disconnect();
  });
}
