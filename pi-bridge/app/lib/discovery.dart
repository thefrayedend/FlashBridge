// Finding the board on the Wi-Fi: it announces "FlashForge Bridge on <name>" as an _http._tcp service
// (avahi on the board), and answers for <name>.local. Android's own name lookup does not know .local
// names, so the app asks over mDNS itself and then uses the board's IP address.
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import 'native.dart';

class FoundBoard {
  final String name;
  final String ip;
  final int port;
  FoundBoard(this.name, this.ip, this.port);
  String get url => port == 80 ? 'http://$ip' : 'http://$ip:$port';
}

/// Searches running at once share the Wi-Fi multicast lock: it is released after the last one.
int _lockUsers = 0;
Future<void> _lock() async {
  if (_lockUsers++ == 0) await Native.multicastLock(true);
}

Future<void> _unlock() async {
  if (--_lockUsers == 0) await Native.multicastLock(false);
}

MDnsClient _client() => MDnsClient(
      // Android cannot share the mDNS port with reusePort
      rawDatagramSocketFactory: (dynamic host, int port, {bool reuseAddress = true, bool reusePort = true, int ttl = 1}) =>
          RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl),
    );

/// Every Flash Bridge board on this Wi-Fi.
Future<List<FoundBoard>> findBoards({Duration timeout = const Duration(seconds: 4)}) async {
  final found = <String, FoundBoard>{};
  final client = _client();
  await _lock();
  try {
    await client.start();
    await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('_http._tcp.local'), timeout: timeout)) {
      if (!ptr.domainName.contains('FlashForge Bridge')) continue;
      final label = ptr.domainName.split('._http._tcp').first.replaceFirst('FlashForge Bridge on ', '');
      await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName), timeout: timeout)) {
        await for (final IPAddressResourceRecord a in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: timeout)) {
          found[a.address.address] = FoundBoard(label, a.address.address, srv.port);
          break;
        }
        break;
      }
    }
  } catch (_) {
    // no Wi-Fi or multicast blocked: nothing found
  } finally {
    client.stop();
    await _unlock();
  }
  return found.values.toList();
}

/// The IP address of a name like "creator5.local" (null when nobody answers).
Future<String?> resolveLocal(String host, {Duration timeout = const Duration(seconds: 3)}) async {
  final name = host.endsWith('.local') ? host : '$host.local';
  final client = _client();
  await _lock();
  try {
    await client.start();
    await for (final IPAddressResourceRecord a in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(name), timeout: timeout)) {
      return a.address.address;
    }
  } catch (_) {
    // fall through
  } finally {
    client.stop();
    await _unlock();
  }
  return null;
}
