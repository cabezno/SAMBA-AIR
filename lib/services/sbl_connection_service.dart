import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// =============================================================================
// SblConnectionService — SBL transport with H.264/H.265 HW encoding via UDP
//
// Uses a native Android MethodChannel that wraps:
//   Camera2 → MediaCodec H.264/H.265 HW encoder → SBL Custom Binary Packaging → UDP
//
// Replaces SRT/RTMP with zero-copy binary packaging matching SAMBA specs.
// =============================================================================

enum SblState { idle, connecting, streaming, error }

class SblConnectionService extends ChangeNotifier {
  static const _channel = MethodChannel('com.vortex.vortexcam/native');

  SblState _state       = SblState.idle;
  String   _engineIp    = '';
  int      _enginePort  = 8890;
  String   _errorMsg    = '';
  double   _bitrateMbps = 0.0;
  int      _latencyMs   = 0;
  bool     _isOnAir     = false;

  // Config
  int    _width            = 1280;
  int    _height           = 720;
  int    _targetBitrateBps = 4000000;  // 4 Mbps default (H.264 efficient)
  int    _keyframeIntervalS = 2;

  SblState get state          => _state;
  bool     get isStreaming     => _state == SblState.streaming;
  String   get engineIp        => _engineIp;
  int      get enginePort      => _enginePort;
  String   get errorMsg        => _errorMsg;
  double   get bitrateMbps     => _bitrateMbps;
  int      get latencyMs       => _latencyMs;
  bool     get isOnAir         => _isOnAir;
  int      get width           => _width;
  int      get height          => _height;

  // Configure video parameters before connecting
  void configure({
    int width = 1280,
    int height = 720,
    int targetBitrateBps = 4000000,
    int keyframeIntervalS = 2,
  }) {
    _width = width;
    _height = height;
    _targetBitrateBps = targetBitrateBps;
    _keyframeIntervalS = keyframeIntervalS;
    notifyListeners();
  }

  // Connect to a specific engine IP:port directly (skip mDNS).
  Future<void> connectTo(String ip, {int port = 8890}) async {
    _engineIp   = ip;
    _enginePort = port;
    _errorMsg   = '';
    _state      = SblState.connecting;
    notifyListeners();
    try {
      await _startStreaming();
    } catch (e) {
      _state    = SblState.error;
      _errorMsg = e.toString();
      notifyListeners();
    }
  }

  Future<void> _startStreaming() async {
    await _channel.invokeMethod('startSbl', {
      'engineIp':        _engineIp,
      'enginePort':      _enginePort,
      'width':           _width,
      'height':          _height,
      'bitrateBps':      _targetBitrateBps,
      'keyframeMs':      _keyframeIntervalS * 1000,
      'codec':           'h264',
    });

    _state = SblState.streaming;
    notifyListeners();
    debugPrint('[SambaAir SBL] Streaming started → $_engineIp:$_enginePort '
               '${_width}x$_height @${_targetBitrateBps ~/ 1000}kbps SBL/UDP');

    // Start polling stats from native side
    _startStatsPolling();
  }

  void _startStatsPolling() {
    Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_state != SblState.streaming) { timer.cancel(); return; }
      try {
        final stats = await _channel.invokeMethod<Map>('getStats');
        if (stats != null) {
          _bitrateMbps = (stats['bitrateMbps'] as num?)?.toDouble() ?? 0.0;
          _latencyMs   = (stats['rttMs']       as num?)?.toInt()    ?? 0;
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  Future<void> stop() async {
    if (_state == SblState.idle) return;
    await _channel.invokeMethod('stopSbl');
    _state    = SblState.idle;
    _bitrateMbps = 0;
    _latencyMs   = 0;
    notifyListeners();
    debugPrint('[SambaAir SBL] Streaming stopped');
  }

  void setOnAir(bool active) {
    _isOnAir = active;
    notifyListeners();
  }

  @override
  void dispose() { stop(); super.dispose(); }
}
