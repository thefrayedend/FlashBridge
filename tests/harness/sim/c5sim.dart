// Creator 5 Pro HTTP API simulator (port 8898) + MJPEG camera (port 8080) for testing.
// dart run tool/c5sim.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sim_assets.dart';

const serial = 'SNC5TEST01', check = '12345678';
final st = <String, dynamic>{
  'errorCode': '',
  'status': 'ready', 'printFileName': '', 'printProgress': 0.0, 'printLayer': 0, 'targetPrintLayer': 0,
  'printDuration': 0, 'estimatedTime': 0, 'nozzleTemps': [25.0, 25.0, 25.0, 25.0], 'nozzleTargetTemps': [0, 0, 0, 0],
  'platTemp': 25.0, 'platTargetTemp': 0, 'chamberTemp': 26.0, 'chamberTargetTemp': 0,
  'lightStatus': 'close', 'internalFanStatus': 'close', 'externalFanStatus': 'close',
  'printSpeedAdjust': 100, 'zAxisCompensation': 0.0, 'coolingFanSpeed': 0, 'chamberFanSpeed': 0,
};
final slots = [
  {'slotId': 1, 'hasFilament': true, 'materialName': 'PLA', 'materialColor': '#FFFFFF'},
  {'slotId': 2, 'hasFilament': true, 'materialName': 'PLA', 'materialColor': '#F82D29'},
  {'slotId': 3, 'hasFilament': true, 'materialName': 'PETG', 'materialColor': '#4CAAF8'},
  {'slotId': 4, 'hasFilament': true, 'materialName': 'PLA', 'materialColor': '#1B1B1B'},
];
final files = ['benchy_C5.gcode', 'calibration_cube.3mf'];
String ip = '127.0.0.1';

Map<String, dynamic> detail() => {
      ...st,
      'pid': 41, 'name': 'Sim Creator 5 Pro', 'model': 'Creator 5 Pro', 'firmwareVersion': '1.9.8', 'nozzleCnt': 4,
      'ipAddr': ip, 'nozzleModel': '0.4mm', 'camera': 1, 'cameraStreamUrl': 'http://$ip:8080/?action=stream',
      'estimatedRightLen': 4200.0, 'estimatedRightWeight': 12.5,
      'matlStationInfo': {'currentLoadSlot': 0, 'currentSlot': 1, 'slotCnt': 4, 'slotInfos': slots, 'stateAction': 0, 'stateStep': 0},
    };

void start(String name) {
  st.addAll({'status': 'printing', 'printFileName': name, 'printProgress': 0.0, 'printDuration': 0, 'nozzleTargetTemps': [220, 0, 0, 0], 'platTargetTemp': 60});
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) ip = args[0];
  Timer.periodic(const Duration(seconds: 1), (_) {
    final nt = st['nozzleTemps'] as List, ntt = st['nozzleTargetTemps'] as List;
    for (var i = 0; i < 4; i++) {
      final t = (nt[i] as num).toDouble();
      nt[i] = ((t + (max((ntt[i] as num).toDouble(), 25) - t) * 0.15) * 10).round() / 10;
    }
    for (final k in [['platTemp', 'platTargetTemp'], ['chamberTemp', 'chamberTargetTemp']]) {
      final t = (st[k[0]] as num).toDouble();
      st[k[0]] = ((t + (max((st[k[1]] as num).toDouble(), 25) - t) * 0.1) * 10).round() / 10;
    }
    if (st['status'] == 'printing') {
      st['printProgress'] = min(1.0, (st['printProgress'] as num) + 0.005);
      st['printDuration'] = (st['printDuration'] as int) + 1;
      st['targetPrintLayer'] = 100;
      st['printLayer'] = ((st['printProgress'] as num) * 100).floor();
      st['estimatedTime'] = ((1 - (st['printProgress'] as num)) * 200).round();
      if ((st['printProgress'] as num) >= 1) st['status'] = 'completed';
    }
  });
  final api = await HttpServer.bind(InternetAddress.anyIPv4, 8898);
  api.listen((req) async {
    final res = req.response;
    void reply(Map m) {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(m));
      res.close();
    }

    if (req.uri.path == '/uploadGcode') {
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      // TEST HOOK: keep the raw body and headers for byte-level comparison
      File('/tmp/fbtest/last_upload.bin').writeAsBytesSync(bytes);
      final hdr = StringBuffer('${req.method} ${req.uri} ${req.protocolVersion}\n');
      req.headers.forEach((k, v) => hdr.writeln('$k: ${v.join(', ')}'));
      File('/tmp/fbtest/last_upload_headers.txt').writeAsStringSync(hdr.toString());
      final m = RegExp('filename="([^"]+)"').firstMatch(latin1.decode(bytes.take(400).toList()));
      final name = m?.group(1) ?? 'x.gcode';
      print('UPLOAD $name printNow=${req.headers.value('printNow')} tools=${req.headers.value('gcodeToolCnt')}');
      if (!files.contains(name)) files.insert(0, name);
      if (req.headers.value('printNow') == 'true') start(name);
      return reply({'code': 0, 'message': 'Success'});
    }
    final body = jsonDecode(await utf8.decodeStream(req)) as Map;
    if (body['serialNumber'] != serial || body['checkCode'] != check) return reply({'code': 1, 'message': 'Invalid credentials'});
    switch (req.uri.path) {
      case '/detail':
        return reply({'code': 0, 'message': 'Success', 'detail': detail()});
      case '/product':
        return reply({'code': 0, 'message': 'Success', 'product': {'lightCtrlState': 1, 'nozzleTempCtrlState': 1, 'platformTempCtrlState': 1}});
      case '/gcodeList':
        return reply({'code': 0, 'message': 'Success', 'gcodeList': files});
      case '/gcodeThumb':
        return reply({'code': 0, 'message': 'Success', 'imageData': simThumb});
      case '/printGcode':
        print('PRINT $body');
        start(body['fileName']);
        return reply({'code': 0, 'message': 'Success'});
      case '/control':
        final cmd = body['payload']['cmd'], a = body['payload']['args'] as Map;
        print('CONTROL $cmd $a');
        switch (cmd) {
          case 'lightControl_cmd':
            st['lightStatus'] = a['status'];
          case 'circulateCtl_cmd':
            st['internalFanStatus'] = a['internal'];
            st['externalFanStatus'] = a['external'];
          case 'jobCtl_cmd':
            if (a['action'] == 'pause') st['status'] = 'paused';
            if (a['action'] == 'continue') st['status'] = 'printing';
            if (a['action'] == 'cancel') st['status'] = 'cancel';
          case 'stateCtrl_cmd':
            st.addAll({'status': 'ready', 'printFileName': '', 'printProgress': 0.0});
          case 'temperatureCtl_cmd':
            final nz = a['nozzles'] as List?;
            if (nz != null) {
              for (var i = 0; i < 4; i++) {
                if (nz[i] != -200) (st['nozzleTargetTemps'] as List)[i] = max(0, nz[i] as num);
              }
            }
            if (a['platform'] != -200) st['platTargetTemp'] = max(0, a['platform'] as num);
            if (a['chamber'] != -200) st['chamberTargetTemp'] = max(0, a['chamber'] as num);
          case 'printerCtl_cmd':
            st['printSpeedAdjust'] = a['speed'];
            st['zAxisCompensation'] = a['zAxisCompensation'];
          case 'simError_cmd': // test hook: make the simulator report an error code
            st['errorCode'] = a['code'] ?? '';
          case 'msConfig_cmd':
            final s = slots[(a['slot'] as int) - 1];
            s['materialName'] = a['mt'];
            s['materialColor'] = a['rgb'];
        }
        return reply({'code': 0, 'message': 'Success'});
    }
    reply({'code': 1, 'message': 'unknown'});
  });
  final cam = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  final jpgs = simFrames.map(base64.decode).toList();
  cam.listen((req) async {
    final res = req.response;
    res.headers.set('Content-Type', 'multipart/x-mixed-replace; boundary=frame');
    res.bufferOutput = false;
    var i = 0;
    try {
      while (true) {
        final j = jpgs[i++ % jpgs.length];
        res.add(utf8.encode('--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${j.length}\r\n\r\n'));
        res.add(j);
        res.add(utf8.encode('\r\n'));
        await res.flush();
        await Future.delayed(Duration(milliseconds: int.tryParse(Platform.environment['SIM_CAM_MS'] ?? '') ?? 250));
      }
    } catch (_) {}
  });
  print('Creator 5 simulator running (API :8898, camera :8080) serial=$serial code=$check');
}
