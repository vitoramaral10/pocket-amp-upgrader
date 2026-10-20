// SPDX-License-Identifier: GPL-3.0-only
//
// macOS: CoreMIDI through the flutter_midi_command plugin, whose Darwin side
// splits outgoing SysEx into MIDIPacketList chunks and reassembles incoming
// SysEx before handing it to Dart.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command.dart';

import '../ota_protocol.dart';
import 'midi_backend.dart';

class CoreMidiBackend implements MidiBackend {
  final MidiCommand _midi = MidiCommand();
  final Map<String, MidiDevice> _devices = <String, MidiDevice>{};

  @override
  Future<List<MidiPortRef>> listPorts() async {
    final List<MidiDevice> devices = await _midi.devices ?? <MidiDevice>[];
    _devices.clear();
    final List<MidiPortRef> out = <MidiPortRef>[];
    for (final MidiDevice d in devices) {
      if (d.type != MidiDeviceType.serial) {
        continue;
      }
      _devices[d.id] = d;
      out.add(MidiPortRef(id: d.id, name: d.name));
    }
    return out;
  }

  @override
  Future<MidiConnection> open(MidiPortRef port) async {
    final MidiDevice? device = _devices[port.id];
    if (device == null) {
      throw MidiPortGone('(${port.name} not found)');
    }
    try {
      await _midi.connectToDevice(
        device,
        awaitConnectionTimeout: const Duration(seconds: 5),
      );
    } catch (e) {
      throw MidiIoException('Could not open ${port.name}: $e');
    }
    return _CoreMidiConnection(_midi, device);
  }
}

class _CoreMidiConnection implements MidiConnection {
  _CoreMidiConnection(this._midi, this._device) {
    _sub = _midi.onMidiPacketReceived?.listen((MidiPacket p) {
      if (p.device.id != _device.id) {
        return;
      }
      for (final Uint8List m in _splitter.add(p.data)) {
        _messages.add(m);
      }
    });
  }

  final MidiCommand _midi;
  final MidiDevice _device;
  StreamSubscription<MidiPacket>? _sub;
  bool _closed = false;
  final StreamController<Uint8List> _messages = StreamController<Uint8List>();
  final SysexSplitter _splitter = SysexSplitter();

  @override
  Stream<Uint8List> get messages => _messages.stream;

  @override
  Future<void> send(Uint8List sysex) async {
    if (_closed) {
      throw const MidiPortGone();
    }
    _midi.sendData(sysex, deviceId: _device.id);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sub?.cancel();
    try {
      _midi.disconnectDevice(_device);
    } catch (_) {
      // The pedal may already be gone after a reboot.
    }
    await _messages.close();
  }
}
