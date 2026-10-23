import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:record/record.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  try {
    initOpus(await opus_flutter.load());
  } catch (_) {}

  runApp(const XiaoZhiPureApp());
}

class XiaoZhiPureApp extends StatelessWidget {
  const XiaoZhiPureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XiaoZhi AI Pet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: Colors.cyanAccent),
      ),
      home: const PetHomeScreen(),
    );
  }
}

// 23 Ekspresi Lengkap ala Robot EMO + State Dead (Shoot & Die)
enum XiaoZhiEmotion {
  neutral,
  happy,
  laughing,
  funny,
  sad,
  angry,
  crying,
  loving,
  embarrassed,
  surprised,
  shocked,
  thinking,
  winking,
  cool,
  relaxed,
  delicious,
  kissy,
  confident,
  sleepy,
  silly,
  confused,
  dizzy,
  dead,
}

// Gestur Tangan & Jari Ekspresif
enum HandGesture {
  none,
  wave,
  peace,
  thumbsUp,
  thinkingChin,
  angryFists,
  handsUp,
  coverCheeks,
  deadDrop,
}

enum SessionState { standbyWakeWord, listeningToUser, speakingTts }

class FloatingParticle {
  Offset position;
  double opacity;
  double size;
  String symbol;
  Color color;

  FloatingParticle({
    required this.position,
    this.opacity = 1.0,
    this.size = 24.0,
    required this.symbol,
    required this.color,
  });
}

class PetHomeScreen extends StatefulWidget {
  const PetHomeScreen({super.key});

  @override
  State<PetHomeScreen> createState() => _PetHomeScreenState();
}

class _PetHomeScreenState extends State<PetHomeScreen>
    with TickerProviderStateMixin {
  static const MethodChannel _deviceChannel =
      MethodChannel('id.xiaozhi.aipet/device');

  // Nama Pet Otomatis dari Server XiaoZhi + Warna & SFX
  String petName = "KIMMI";
  int themeColorIndex = 1;
  bool enableRobotSfx = true;

  // Identitas & Koneksi Protokol XiaoZhi
  String deviceMac = "";
  String clientId = "";
  String wsUrl = "wss://api.tenclass.net/xiaozhi/v1/";
  String wsToken = "test-token";
  String visionExplainUrl = "";
  String visionExplainToken = "";
  String sessionId = "";
  bool isXiaoZhiConnected = false;
  WebSocket? _ws;

  // Status Sesi & Audio Opus Native
  SessionState sessionState = SessionState.standbyWakeWord;
  bool isVoiceAudioActive = false;
  Timer? _voiceDecayTimer;

  final stt.SpeechToText _wakeStt = stt.SpeechToText();
  final AudioRecorder _micRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micStreamSub;
  SimpleOpusEncoder? _opusEncoder;
  SimpleOpusDecoder? _opusDecoder;
  final List<int> _pcmMicBuffer = [];
  int _serverSampleRate = 24000;

  // Kamera MCP Vision (Selfie & Belakang)
  List<CameraDescription> _cameras = [];
  CameraController? _cameraController;
  int _selectedCameraIdx = 0;
  bool showCameraPreview = false;
  bool _isCameraBusy = false;

  // Data GPS Asli & Cuaca Lokal
  double? gpsLat;
  double? gpsLon;
  String locationName = "Mencari GPS...";
  String weatherSummary = "Memuat cuaca...";
  double currentTempC = 28.0;
  String weatherCondition = "Cerah";
  String timeString = "";
  String dateString = "";
  bool isLandscape = false;

  final List<Color> themeColors = [
    Colors.cyanAccent,
    Colors.pinkAccent,
    Colors.greenAccent,
    Colors.amberAccent,
    Colors.purpleAccent,
  ];

  XiaoZhiEmotion currentEmotion = XiaoZhiEmotion.neutral;
  HandGesture currentHandGesture = HandGesture.none;
  String statusSubtitle = "Menginisialisasi koneksi XiaoZhi...";

  // State Permainan Shoot & Die + Layar Retak
  bool isScreenCracked = false;
  double shootFlashOpacity = 0.0;
  Offset crackOrigin = const Offset(180, 300);
  final List<List<Offset>> crackBranches = [];
  Timer? _reviveTimer;
  Timer? _handResetTimer;

  Offset gazeOffset = Offset.zero;
  int rubCounter = 0;
  final List<FloatingParticle> particles = [];

  late AnimationController _blinkController;
  late AnimationController _floatController;
  late AnimationController _talkController;
  late AnimationController _handController;
  Timer? _clockTimer;
  Timer? _idleTimer;
  Timer? _particleTimer;
  Timer? _wakeRestartTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  DateTime _lastShakeTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    );
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _talkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
    )..repeat(reverse: true);
    _handController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..repeat(reverse: true);

    _updateClock();
    _bootstrapSystem();

    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _idleTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _idleBehavior());
    _particleTimer = Timer.periodic(
        const Duration(milliseconds: 50), (_) => _updateParticles());

    _wakeRestartTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (sessionState == SessionState.standbyWakeWord &&
          !_wakeStt.isListening) {
        _startWakeWordListener();
      }
    });

    _initShakeDetector();
  }

  Future<void> _bootstrapSystem() async {
    await [
      Permission.microphone,
      Permission.camera,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();

    await _loadIdentityAndSettings();
    await _initOpusAndPcmEngine();
    await _initCamerasAfterPermission(preferFront: true);
    _fetchHardwareGpsAndWeather();
    await _syncXiaoZhiOtaAndConnect();
    _startWakeWordListener();
  }

  Future<void> _loadIdentityAndSettings() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedMac = prefs.getString('deviceMac');
    String? savedClient = prefs.getString('clientId');

    if (savedMac == null || savedMac.isEmpty) {
      final rand = Random();
      savedMac =
          "02:00:5e:${rand.nextInt(256).toRadixString(16).padLeft(2, '0')}:${rand.nextInt(256).toRadixString(16).padLeft(2, '0')}:${rand.nextInt(256).toRadixString(16).padLeft(2, '0')}";
      await prefs.setString('deviceMac', savedMac);
    }
    if (savedClient == null || savedClient.isEmpty) {
      final rand = Random();
      savedClient =
          "c4f2a1b0-${rand.nextInt(9000) + 1000}-4e1a-9b2c-${rand.nextInt(900000) + 100000}a1b2c3";
      await prefs.setString('clientId', savedClient);
    }

    setState(() {
      deviceMac = savedMac!;
      clientId = savedClient!;
      petName = prefs.getString(' syncedPetName') ?? "KIMMI";
      themeColorIndex = prefs.getInt('themeColorIndex') ?? 1;
      enableRobotSfx = prefs.getBool('enableRobotSfx') ?? true;
    });
  }

  Future<void> _updateSyncedPetName(String newName) async {
    final cleaned = newName.trim().toUpperCase();
    if (cleaned.isEmpty || cleaned.length > 18) return;
    if (cleaned == petName) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(' syncedPetName', cleaned);
    if (mounted) {
      setState(() => petName = cleaned);
    }
  }

  void _tryExtractPetNameFromServerText(String text, {required bool isFromUser}) {
    final lower = text.toLowerCase().trim();
    if (isFromUser) {
      final m = RegExp(r'^(?:hai|halo|hello|hey|hi)\s+([a-zA-Z]{2,12})\b')
          .firstMatch(lower);
      if (m != null) {
        final candidate = m.group(1)!;
        if (!['kamu', 'anda', 'saya', 'aku', 'disana'].contains(candidate)) {
          _updateSyncedPetName(candidate);
        }
      }
    } else {
      final m = RegExp(
              r'(?:nama\s+saya|namaku|aku\s+adalah|panggil\s+aku|i\s+am|my\s+name\s+is)\s+([a-zA-Z]{2,12})\b')
          .firstMatch(lower);
      if (m != null) {
        final candidate = m.group(1)!;
        if (!['robot', 'asisten', 'teman', 'anak', 'siap'].contains(candidate)) {
          _updateSyncedPetName(candidate);
        }
      }
    }
  }

  Future<void> _initOpusAndPcmEngine() async {
    try {
      _opusEncoder = SimpleOpusEncoder(
        sampleRate: 16000,
        channels: 1,
        application: Application.voip,
      );
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: _serverSampleRate,
        channels: 1,
      );
      await FlutterPcmSound.setup(
        sampleRate: _serverSampleRate,
        channelCount: 1,
      );
      await FlutterPcmSound.setFeedThreshold(960);
    } catch (_) {}
  }

  // =======================================================================
  // 1. SYNTHESIZER EFEK SUARA ROBOT EMO (PROCEDURAL PCM16 SFX)
  // =======================================================================
  void _playRobotSfx(String sfxType) {
    if (!enableRobotSfx || isVoiceAudioActive) return;
    if (sessionState == SessionState.speakingTts) return;

    try {
      final int sr = _serverSampleRate;
      final List<int> samples = [];

      void addTone(double fStart, double fEnd, int durationMs,
          {double volume = 0.28, bool square = false, bool noise = false}) {
        final int count = (sr * durationMs) ~/ 1000;
        double phase = 0.0;
        final rand = Random();
        for (int i = 0; i < count; i++) {
          final double progress = i / count;
          final double freq = fStart + (fEnd - fStart) * progress;
          final double env = sin(progress * pi); // Smooth envelope
          phase += (2 * pi * freq) / sr;
          double val = sin(phase);
          if (square) val = val >= 0 ? 0.8 : -0.8;
          if (noise) val = (val * 0.4) + ((rand.nextDouble() * 2 - 1) * 0.6);
          samples.add((val * env * volume * 32767).toInt().clamp(-32760, 32760));
        }
      }

      switch (sfxType) {
        case 'shoot_and_die':
          // Laser / Tembakan + Kaca Pecah + Power Down
          addTone(1500, 180, 140, volume: 0.45, noise: true);
          addTone(2400, 900, 90, volume: 0.35, noise: true);
          addTone(680, 140, 520, volume: 0.35, square: true);
          break;
        case 'revive':
          addTone(320, 580, 110);
          addTone(580, 880, 130);
          addTone(880, 1320, 180);
          break;
        case 'happy':
        case 'laughing':
        case 'funny':
          addTone(520, 780, 85);
          addTone(680, 1050, 95);
          addTone(850, 1280, 110);
          break;
        case 'loving':
        case 'kissy':
          addTone(600, 950, 140);
          addTone(950, 1400, 200);
          break;
        case 'angry':
          addTone(220, 150, 160, square: true, volume: 0.32);
          addTone(190, 120, 220, square: true, volume: 0.32);
          break;
        case 'sad':
        case 'crying':
          addTone(620, 420, 220);
          addTone(410, 260, 300);
          break;
        case 'surprised':
        case 'shocked':
          addTone(400, 1450, 160);
          break;
        case 'thinking':
        case 'confused':
          addTone(540, 540, 70);
          addTone(720, 640, 120);
          break;
        case 'dizzy':
          addTone(400, 800, 90);
          addTone(800, 350, 90);
          addTone(350, 750, 90);
          break;
        default:
          addTone(660, 880, 80, volume: 0.2);
          break;
      }

      if (samples.isNotEmpty) {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
      }
    } catch (_) {}
  }

  // =======================================================================
  // 2. MODE BERMAIN: SHOOT & DIE + ANIMASI RETAK LAYAR
  // =======================================================================
  void _triggerShootAndDie({Offset? tapPosition}) {
    _reviveTimer?.cancel();
    _handResetTimer?.cancel();

    final rand = Random();
    final center = tapPosition ?? const Offset(180, 260);
    crackOrigin = center;
    crackBranches.clear();

    // Buat 9 cabang garis kaca retak dari titik tembakan
    for (int i = 0; i < 9; i++) {
      final double baseAngle = (i * (2 * pi / 9)) + (rand.nextDouble() * 0.35);
      final List<Offset> branch = [center];
      Offset curr = center;
      for (int step = 0; step < 5; step++) {
        final double len = 28.0 + rand.nextDouble() * 48.0;
        final double jitter = (rand.nextDouble() - 0.5) * 0.55;
        curr = Offset(
          curr.dx + cos(baseAngle + jitter) * len,
          curr.dy + sin(baseAngle + jitter) * len,
        );
        branch.add(curr);
      }
      crackBranches.add(branch);
    }

    _playRobotSfx('shoot_and_die');
    _spawnParticle("💥", Colors.orangeAccent);

    // Fase 1: Kaget angkat kedua tangan + Flash Putih + Layar Retak
    setState(() {
      isScreenCracked = true;
      shootFlashOpacity = 0.85;
      currentEmotion = XiaoZhiEmotion.shocked;
      currentHandGesture = HandGesture.handsUp;
      statusSubtitle = "💥 DOR!! Aduh... aku tertembak!!";
    });

    Future.delayed(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => shootFlashOpacity = 0.0);
    });

    // Fase 2: Tumbang & Ekspresi Mati (Mata X X + Lidah Keluar + Halo Malaikat)
    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      _spawnParticle("👻", Colors.white70);
      setState(() {
        currentEmotion = XiaoZhiEmotion.dead;
        currentHandGesture = HandGesture.deadDrop;
        statusSubtitle = "💀 X_X ... $petName pura-pura mati... (Ketuk untuk bangunkan)";
      });
    });

    // Fase 3: Bangkit Kembali Otomatis setelah 5.5 detik
    _reviveTimer = Timer(const Duration(milliseconds: 5500), () {
      if (mounted && currentEmotion == XiaoZhiEmotion.dead) {
        _reviveFromDead();
      }
    });
  }

  void _reviveFromDead() {
    _reviveTimer?.cancel();
    _playRobotSfx('revive');
    _spawnParticle("✨", Colors.greenAccent);
    setState(() {
      isScreenCracked = false;
      crackBranches.clear();
      currentEmotion = XiaoZhiEmotion.happy;
      currentHandGesture = HandGesture.peace;
      statusSubtitle =
          "Standby • Hehe aku hidup lagi! Panggil \"Hai $petName\"";
    });
    _scheduleHandReset();
  }

  void _setEmotionWithGestureAndSfx(XiaoZhiEmotion emo, {HandGesture? gesture}) {
    if (currentEmotion == XiaoZhiEmotion.dead && emo != XiaoZhiEmotion.dead) {
      isScreenCracked = false;
      crackBranches.clear();
    }

    final HandGesture autoGesture = gesture ?? _defaultGestureForEmotion(emo);
    final bool changed = currentEmotion != emo;

    setState(() {
      currentEmotion = emo;
      currentHandGesture = autoGesture;
    });

    if (changed) {
      _playRobotSfx(emo.name);
    }
    _scheduleHandReset();
  }

  HandGesture _defaultGestureForEmotion(XiaoZhiEmotion emo) {
    switch (emo) {
      case XiaoZhiEmotion.happy:
      case XiaoZhiEmotion.excited:
        return HandGesture.wave;
      case XiaoZhiEmotion.winking:
      case XiaoZhiEmotion.silly:
      case XiaoZhiEmotion.funny:
      case XiaoZhiEmotion.laughing:
        return HandGesture.peace;
      case XiaoZhiEmotion.cool:
      case XiaoZhiEmotion.confident:
        return HandGesture.thumbsUp;
      case XiaoZhiEmotion.thinking:
      case XiaoZhiEmotion.confused:
        return HandGesture.thinkingChin;
      case XiaoZhiEmotion.angry:
        return HandGesture.angryFists;
      case XiaoZhiEmotion.embarrassed:
      case XiaoZhiEmotion.loving:
      case XiaoZhiEmotion.kissy:
        return HandGesture.coverCheeks;
      case XiaoZhiEmotion.shocked:
      case XiaoZhiEmotion.surprised:
        return HandGesture.handsUp;
      case XiaoZhiEmotion.dead:
        return HandGesture.deadDrop;
      default:
        return HandGesture.none;
    }
  }

  void _scheduleHandReset() {
    _handResetTimer?.cancel();
    if (currentHandGesture == HandGesture.none ||
        currentHandGesture == HandGesture.deadDrop) {
      return;
    }
    _handResetTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && currentEmotion != XiaoZhiEmotion.dead) {
        setState(() => currentHandGesture = HandGesture.none);
      }
    });
  }

  // =======================================================================
  // 3. KAMERA VISION (DEFAULT SELFIE & BISA PINDAH DEPAN/BELAKANG)
  // =======================================================================
  Future<void> _initCamerasAfterPermission({bool preferFront = true}) async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      if (preferFront) {
        final frontIdx = _cameras
            .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
        _selectedCameraIdx = frontIdx != -1 ? frontIdx : 0;
      } else {
        final backIdx = _cameras
            .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
        _selectedCameraIdx = backIdx != -1 ? backIdx : 0;
      }

      await _startSelectedCamera();
    } catch (_) {}
  }

  Future<void> _startSelectedCamera() async {
    if (_cameras.isEmpty) return;
    try {
      final prev = _cameraController;
      _cameraController = null;
      await prev?.dispose();

      final controller = CameraController(
        _cameras[_selectedCameraIdx],
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}

      _cameraController = controller;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<String> _switchCameraLens({String? targetDirection}) async {
    if (_cameras.isEmpty) {
      _cameras = await availableCameras();
    }
    if (_cameras.isEmpty) return "unavailable";

    if (targetDirection == "front" || targetDirection == "selfie") {
      final idx = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      if (idx != -1) _selectedCameraIdx = idx;
    } else if (targetDirection == "back" || targetDirection == "rear") {
      final idx = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (idx != -1) _selectedCameraIdx = idx;
    } else {
      _selectedCameraIdx = (_selectedCameraIdx + 1) % _cameras.length;
    }

    await _startSelectedCamera();
    return _currentLensName;
  }

  String get _currentLensName {
    if (_cameras.isEmpty || _selectedCameraIdx >= _cameras.length) {
      return "front";
    }
    return _cameras[_selectedCameraIdx].lensDirection ==
            CameraLensDirection.front
        ? "front"
        : "back";
  }

  // =======================================================================
  // 4. LOKASI GPS ASLI HP + CUACA REAL-TIME
  // =======================================================================
  Future<void> _fetchHardwareGpsAndWeather() async {
    try {
      final dynamic gpsMap =
          await _deviceChannel.invokeMethod('getGpsLocation');
      if (gpsMap != null && gpsMap is Map) {
        gpsLat = (gpsMap['lat'] as num?)?.toDouble();
        gpsLon = (gpsMap['lon'] as num?)?.toDouble();
      }

      if (gpsLat == null || gpsLon == null) {
        final ipRes = await http
            .get(Uri.parse(
                "https://api.bigdatacloud.net/data/reverse-geocode-client?localityLanguage=id"))
            .timeout(const Duration(seconds: 6));
        if (ipRes.statusCode == 200) {
          final d = jsonDecode(ipRes.body);
          gpsLat = (d['latitude'] as num?)?.toDouble();
          gpsLon = (d['longitude'] as num?)?.toDouble();
        }
      }

      if (gpsLat != null && gpsLon != null) {
        final revUrl =
            "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=$gpsLat&longitude=$gpsLon&localityLanguage=id";
        final revRes = await http
            .get(Uri.parse(revUrl))
            .timeout(const Duration(seconds: 6));
        if (revRes.statusCode == 200) {
          final rev = jsonDecode(utf8.decode(revRes.bodyBytes));
          final locality = rev['locality']?.toString() ?? "";
          final city = rev['city']?.toString() ??
              rev['principalSubdivision']?.toString() ??
              "";
          if (locality.isNotEmpty && city.isNotEmpty && locality != city) {
            locationName = "$locality, $city";
          } else if (locality.isNotEmpty) {
            locationName = locality;
          } else if (city.isNotEmpty) {
            locationName = city;
          }
        }

        final wRes = await http
            .get(Uri.parse(
                "https://api.open-meteo.com/v1/forecast?latitude=$gpsLat&longitude=$gpsLon&current_weather=true"))
            .timeout(const Duration(seconds: 6));
        if (wRes.statusCode == 200) {
          final w = jsonDecode(wRes.body)['current_weather'];
          currentTempC = (w['temperature'] as num?)?.toDouble() ?? 28.0;
          final wCode = (w['weathercode'] as num?)?.toInt() ?? 0;
          weatherCondition = _decodeWeatherCode(wCode);
          if (mounted) {
            setState(() {
              weatherSummary = "$currentTempC°C • $locationName";
            });
          }
        }
      }
    } catch (_) {
      if (mounted) setState(() => weatherSummary = "GPS Aktif • Online");
    }
  }

  String _decodeWeatherCode(int code) {
    if (code == 0) return "Cerah";
    if (code <= 3) return "Berawan";
    if (code <= 48) return "Berkabut";
    if (code <= 67) return "Hujan Ringan";
    if (code <= 82) return "Hujan Deras";
    if (code >= 95) return "Badai Petir";
    return "Cerah Berawan";
  }

  // =======================================================================
  // 5. PROTOKOL OTA & WEBSOCKET XIAOZHI
  // =======================================================================
  Future<void> _syncXiaoZhiOtaAndConnect(
      {bool showDialogIfPaired = false}) async {
    try {
      final response = await http
          .post(
            Uri.parse("https://api.tenclass.net/xiaozhi/ota/"),
            headers: {
              "Device-Id": deviceMac,
              "Client-Id": clientId,
              "Content-Type": "application/json",
              "User-Agent": "bread-compact-wifi/1.0.0",
            },
            body: jsonEncode({
              "version": 2,
              "flash_size": 16777216,
              "minimum_free_heap_size": 8388608,
              "mac_address": deviceMac,
              "uuid": clientId,
              "chip_model_name": "esp32s3",
              "application": {
                "name": "xiaozhi",
                "version": "1.6.2",
                "compile_time": "Oct 23 2026",
                "idf_version": "v5.3.2"
              },
              "board": {
                "type": "bread-compact-wifi",
                "name": "bread-compact-wifi",
                "ssid": "Android-AI-Pet",
                "rssi": -38,
                "channel": 1,
                "ip": "192.168.1.100",
                "mac": deviceMac
              }
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));

        if (data['websocket'] != null) {
          wsUrl = data['websocket']['url']?.toString() ?? wsUrl;
          wsToken = data['websocket']['token']?.toString() ?? wsToken;
        }

        if (data['activation'] != null && data['activation']['code'] != null) {
          final code = data['activation']['code'].toString();
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.surprised);
          setState(() {
            statusSubtitle =
                "Belum di-pairing! Masukkan kode $code di web xiaozhi.me";
          });
          _showPairingDialog(code, data['activation']['message']?.toString());
          return;
        }

        if (showDialogIfPaired && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Perangkat sudah terhubung ke akun XiaoZhi!")),
          );
        }
      }
    } catch (_) {}

    await _connectXiaoZhiWs();
  }

  Future<void> _connectXiaoZhiWs() async {
    try {
      await _ws?.close();
      final socket = await WebSocket.connect(
        wsUrl,
        headers: {
          "Authorization": "Bearer $wsToken",
          "Protocol-Version": "1",
          "Device-Id": deviceMac,
          "Client-Id": clientId,
        },
      ).timeout(const Duration(seconds: 8));

      _ws = socket;
      if (mounted) {
        setState(() {
          isXiaoZhiConnected = true;
          statusSubtitle = "Standby • Panggil \"Hai $petName\" untuk bicara";
        });
      }

      socket.add(jsonEncode({
        "type": "hello",
        "version": 1,
        "features": {"mcp": true},
        "transport": "websocket",
        "audio_params": {
          "format": "opus",
          "sample_rate": 16000,
          "channels": 1,
          "frame_duration": 60
        }
      }));

      socket.listen(
        (event) {
          if (event is String) {
            _handleServerJson(event);
          } else if (event is List<int>) {
            _handleServerOpusBinary(Uint8List.fromList(event));
          }
        },
        onDone: () {
          if (mounted) setState(() => isXiaoZhiConnected = false);
        },
        onError: (_) {
          if (mounted) setState(() => isXiaoZhiConnected = false);
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          isXiaoZhiConnected = false;
          statusSubtitle = "Terputus dari XiaoZhi • Ketuk ikon QR untuk cek";
        });
      }
    }
  }

  void _handleServerJson(String rawJson) {
    try {
      final data = jsonDecode(rawJson);
      final type = data['type'];

      if (type == 'hello') {
        sessionId = data['session_id']?.toString() ?? "";
        final sr = data['audio_params']?['sample_rate'];
        if (sr is int && sr != _serverSampleRate) {
          _serverSampleRate = sr;
          _opusDecoder =
              SimpleOpusDecoder(sampleRate: _serverSampleRate, channels: 1);
          FlutterPcmSound.setup(
              sampleRate: _serverSampleRate, channelCount: 1);
        }
      } else if (type == 'stt') {
        final text = data['text']?.toString() ?? "";
        if (text.isNotEmpty && mounted) {
          _tryExtractPetNameFromServerText(text, isFromUser: true);

          // Jika user mengucapkan kata tembakan saat ngobrol
          if (_isShootCommand(text)) {
            _triggerShootAndDie();
            return;
          }

          setState(() {
            statusSubtitle = "\"$text\"";
          });
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.thinking);
        }
      } else if (type == 'llm') {
        final emo = data['emotion']?.toString() ?? "neutral";
        if (mounted && currentEmotion != XiaoZhiEmotion.dead) {
          _setEmotionWithGestureAndSfx(_mapXiaoZhiEmotion(emo));
        }
      } else if (type == 'tts') {
        final state = data['state'];
        final text = data['text']?.toString() ?? "";

        if (state == 'start') {
          _stopMicOpusStream();
          if (mounted) {
            setState(() => sessionState = SessionState.speakingTts);
          }
        } else if (state == 'sentence_start' && text.isNotEmpty) {
          if (mounted) {
            _tryExtractPetNameFromServerText(text, isFromUser: false);
            if (text.trim().startsWith('%')) {
              setState(() {
                statusSubtitle =
                    "⚙️ Menjalankan: ${text.replaceFirst('%', '').trim()}";
                isVoiceAudioActive = false;
              });
            } else {
              setState(() => statusSubtitle = text);
            }
          }
        } else if (state == 'stop') {
          _voiceDecayTimer?.cancel();
          if (mounted) {
            setState(() => isVoiceAudioActive = false);
          }
          Future.delayed(const Duration(milliseconds: 400), () {
            if (mounted &&
                isXiaoZhiConnected &&
                currentEmotion != XiaoZhiEmotion.dead) {
              _beginActiveOpusListening();
            }
          });
        }
      } else if (type == 'mcp') {
        _handleMcpPayload(data['payload']);
      }
    } catch (_) {}
  }

  void _handleServerOpusBinary(Uint8List opusPacket) {
    if (_opusDecoder == null || opusPacket.isEmpty) return;
    try {
      final Int16List pcm16 = _opusDecoder!.decode(input: opusPacket);
      if (pcm16.isNotEmpty) {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm16.toList()));

        if (!isVoiceAudioActive && mounted) {
          setState(() => isVoiceAudioActive = true);
        }
        _voiceDecayTimer?.cancel();
        _voiceDecayTimer = Timer(const Duration(milliseconds: 280), () {
          if (mounted) setState(() => isVoiceAudioActive = false);
        });
      }
    } catch (_) {}
  }

  // =======================================================================
  // 6. PROTOKOL MCP LENGKAP (VISION, GPS, VOLUME, & PLAY ACTION EMO)
  // =======================================================================
  Future<void> _handleMcpPayload(dynamic payload) async {
    if (payload == null) return;
    final method = payload['method']?.toString() ?? "";
    final id = payload['id'];

    if (method == 'initialize') {
      final capVision = payload['params']?['capabilities']?['vision'];
      if (capVision != null) {
        visionExplainUrl = capVision['url']?.toString() ?? "";
        visionExplainToken = capVision['token']?.toString() ?? "";
      }
      _sendMcpReply(id, {
        "protocolVersion": "2024-11-05",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "XiaoZhi-EMO-Android-Pet", "version": "3.0.0"}
      });
    } else if (method == 'tools/list') {
      _sendMcpReply(id, {
        "tools": [
          {
            "name": "self.get_device_status",
            "description":
                "Provides real-time device status including GPS location, city/district name, local weather, speaker volume, pet name, and active camera direction.",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.location.get_current_location",
            "description":
                "Get the user's exact hardware GPS coordinates, subdistrict/city address, and local weather condition.",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.pet.play_action",
            "description":
                "Trigger expressive robot pet animations, hand gestures, or play games like shoot_and_die (pretend to be shot with cracked screen and play dead), wave, peace, thumbs_up, angry_fists, or revive.",
            "inputSchema": {
              "type": "object",
              "properties": {
                "action": {
                  "type": "string",
                  "enum": [
                    "shoot_and_die",
                    "wave",
                    "peace",
                    "thumbs_up",
                    "angry_fists",
                    "revive"
                  ],
                  "description": "The interactive action or gesture to perform."
                },
                "pet_name": {
                  "type": "string",
                  "description":
                      "Optional: sync the pet's current assistant name from server role settings."
                }
              },
              "required": ["action"]
            }
          },
          {
            "name": "self.camera.take_photo",
            "description":
                "Take a photo with the camera to see the user's face (front selfie camera) or surroundings (back camera) and answer questions about it.",
            "inputSchema": {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "The question or prompt about the photo."
                },
                "camera": {
                  "type": "string",
                  "enum": ["front", "back"],
                  "description":
                      "Optional: 'front' for selfie/seeing the user, 'back' for rear environment camera."
                }
              },
              "required": ["question"]
            }
          },
          {
            "name": "self.camera.switch_camera",
            "description":
                "Switch between the front (selfie) camera and the back (rear) camera.",
            "inputSchema": {
              "type": "object",
              "properties": {
                "camera": {
                  "type": "string",
                  "enum": ["front", "back"],
                  "description": "Target camera direction: 'front' or 'back'."
                }
              }
            }
          },
          {
            "name": "self.audio_speaker.set_volume",
            "description": "Set the audio speaker volume level (0 to 100).",
            "inputSchema": {
              "type": "object",
              "properties": {
                "volume": {
                  "type": "integer",
                  "minimum": 0,
                  "maximum": 100,
                  "description": "Volume level from 0 to 100"
                }
              },
              "required": ["volume"]
            }
          }
        ]
      });
    } else if (method == 'tools/call') {
      final toolName = payload['params']?['name']?.toString() ?? "";
      final args = payload['params']?['arguments'] ?? {};

      if (toolName == 'self.get_device_status' ||
          toolName == 'self.location.get_current_location') {
        await _fetchHardwareGpsAndWeather();
        int vol = 80;
        try {
          vol = (await _deviceChannel.invokeMethod('getVolume')) as int? ?? 80;
        } catch (_) {}

        final statusJson = jsonEncode({
          "pet_name": petName,
          "audio_speaker": {"volume": vol},
          "camera": {
            "active_lens": _currentLensName,
            "preview_visible": showCameraPreview
          },
          "location": {
            "latitude": gpsLat,
            "longitude": gpsLon,
            "address": locationName,
          },
          "local_weather": {
            "temperature_celsius": currentTempC,
            "condition": weatherCondition,
            "summary": weatherSummary
          },
          "local_time": "$timeString ($dateString)"
        });

        _sendMcpReply(id, {
          "content": [
            {"type": "text", "text": statusJson}
          ],
          "isError": false
        });
      } else if (toolName == 'self.pet.play_action') {
        final action = args['action']?.toString() ?? "wave";
        final syncedName = args['pet_name']?.toString();
        if (syncedName != null && syncedName.isNotEmpty) {
          await _updateSyncedPetName(syncedName);
        }

        if (action == 'shoot_and_die') {
          _triggerShootAndDie();
        } else if (action == 'revive') {
          _reviveFromDead();
        } else if (action == 'wave') {
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.happy,
              gesture: HandGesture.wave);
        } else if (action == 'peace') {
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.winking,
              gesture: HandGesture.peace);
        } else if (action == 'thumbs_up') {
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.cool,
              gesture: HandGesture.thumbsUp);
        } else if (action == 'angry_fists') {
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.angry,
              gesture: HandGesture.angryFists);
        }

        _sendMcpReply(id, {
          "content": [
            {
              "type": "text",
              "text": '{"success": true, "performed_action": "$action"}'
            }
          ],
          "isError": false
        });
      } else if (toolName == 'self.camera.switch_camera') {
        final target = args['camera']?.toString();
        final activeLens = await _switchCameraLens(targetDirection: target);
        setState(() => showCameraPreview = true);
        _sendMcpReply(id, {
          "content": [
            {
              "type": "text",
              "text": '{"success": true, "active_camera": "$activeLens"}'
            }
          ],
          "isError": false
        });
      } else if (toolName == 'self.camera.take_photo') {
        final question =
            args['question']?.toString() ?? "Describe what you see in detail";
        final targetCam = args['camera']?.toString();
        if (targetCam != null &&
            targetCam.isNotEmpty &&
            targetCam != _currentLensName) {
          await _switchCameraLens(targetDirection: targetCam);
        }
        final visionResult = await _captureAndUploadVision(question);
        _sendMcpReply(id, {
          "content": [
            {"type": "text", "text": visionResult}
          ],
          "isError": false
        });
      } else if (toolName == 'self.audio_speaker.set_volume') {
        final vol = (args['volume'] as num?)?.toInt() ?? 80;
        try {
          await _deviceChannel.invokeMethod('setVolume', {"volume": vol});
        } catch (_) {}
        _sendMcpReply(id, {
          "content": [
            {"type": "text", "text": '{"success": true, "volume": $vol}'}
          ],
          "isError": false
        });
      }
    }
  }

  void _sendMcpReply(dynamic id, Map<String, dynamic> result) {
    if (_ws == null || !isXiaoZhiConnected) return;
    _ws!.add(jsonEncode({
      "session_id": sessionId,
      "type": "mcp",
      "payload": {"jsonrpc": "2.0", "id": id, "result": result}
    }));
  }

  Future<String> _captureAndUploadVision(String question) async {
    if (_isCameraBusy) {
      return '{"success": false, "message": "Camera is busy"}';
    }
    _isCameraBusy = true;

    try {
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        await _initCamerasAfterPermission(preferFront: true);
      }
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        _isCameraBusy = false;
        return '{"success": false, "message": "Camera could not be initialized"}';
      }

      if (mounted) {
        _setEmotionWithGestureAndSfx(XiaoZhiEmotion.surprised,
            gesture: HandGesture.peace);
        setState(() {
          statusSubtitle =
              "📸 Memotret dengan kamera ${_currentLensName == 'front' ? 'Selfie' : 'Belakang'}...";
        });
      }

      await Future.delayed(const Duration(milliseconds: 250));
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
      } catch (_) {}

      final XFile photo = await _cameraController!.takePicture();
      final Uint8List bytes = await photo.readAsBytes();

      final targetUrl = visionExplainUrl.isNotEmpty
          ? visionExplainUrl
          : "https://api.tenclass.net/xiaozhi/vision/explain";

      final req = http.MultipartRequest('POST', Uri.parse(targetUrl));
      req.headers['Device-Id'] = deviceMac;
      req.headers['Client-Id'] = clientId;
      req.headers['User-Agent'] = 'bread-compact-wifi/1.0.0';
      if (visionExplainToken.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $visionExplainToken';
      }
      req.fields['question'] = question;
      req.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: 'camera.jpg',
        ),
      );

      final streamedRes =
          await req.send().timeout(const Duration(seconds: 15));
      final body = await streamedRes.stream.bytesToString();
      _isCameraBusy = false;
      return body;
    } catch (e) {
      _isCameraBusy = false;
      return '{"success": false, "message": "Camera error: $e"}';
    }
  }

  // =======================================================================
  // 7. WAKE WORD UNIVERSAL & DETEKSI SUARA TEMBAKAN ("DOR / TEMBAK / BANG")
  // =======================================================================
  Future<void> _startWakeWordListener() async {
    if (sessionState != SessionState.standbyWakeWord) return;
    try {
      bool ready = await _wakeStt.initialize(onError: (_) {}, onStatus: (_) {});
      if (!ready) return;

      await _wakeStt.listen(
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
        onResult: (result) {
          final spoken = result.recognizedWords.toLowerCase().trim();
          if (spoken.isEmpty) return;

          if (_isShootCommand(spoken)) {
            _wakeStt.stop();
            _triggerShootAndDie();
            return;
          }

          if (_isWakePhraseDetected(spoken)) {
            _tryExtractPetNameFromServerText(spoken, isFromUser: true);
            _wakeStt.stop();
            _triggerWakeUpToXiaoZhi(spoken);
          }
        },
      );
    } catch (_) {}
  }

  bool _isShootCommand(String text) {
    final lower = text.toLowerCase();
    return lower.contains('dor') ||
        lower.contains('tembak') ||
        lower.contains('bang') ||
        lower.contains('pew') ||
        lower.contains('shoot');
  }

  bool _isWakePhraseDetected(String text) {
    if (text.isEmpty) return false;
    final targetName = petName.toLowerCase().trim();
    final wakePrefixes = ['hai', 'halo', 'hello', 'hey', 'hi'];

    if (text.contains(targetName) || text.contains('xiaozhi')) {
      return true;
    }
    for (final prefix in wakePrefixes) {
      if (text.startsWith('$prefix ') && text.length > prefix.length + 2) {
        return true;
      }
    }
    return false;
  }

  Future<void> _triggerWakeUpToXiaoZhi(String wakeText) async {
    if (currentEmotion == XiaoZhiEmotion.dead) {
      _reviveFromDead();
    }
    if (!isXiaoZhiConnected || _ws == null) {
      await _connectXiaoZhiWs();
    }
    _spawnParticle("✨", Colors.cyanAccent);
    _setEmotionWithGestureAndSfx(XiaoZhiEmotion.happy,
        gesture: HandGesture.wave);

    _ws?.add(jsonEncode({
      "session_id": sessionId,
      "type": "listen",
      "state": "detect",
      "text": wakeText,
    }));

    await _beginActiveOpusListening();
  }

  Future<void> _beginActiveOpusListening() async {
    await _wakeStt.stop();
    await _stopMicOpusStream();

    if (!isXiaoZhiConnected || _ws == null) return;

    setState(() {
      sessionState = SessionState.listeningToUser;
      isVoiceAudioActive = false;
      currentEmotion = XiaoZhiEmotion.happy;
      statusSubtitle = "Mendengarkanmu... (Ketuk wajah untuk Standby)";
    });

    _ws?.add(jsonEncode({
      "session_id": sessionId,
      "type": "listen",
      "state": "start",
      "mode": "auto"
    }));

    _pcmMicBuffer.clear();
    final stream = await _micRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );

    _micStreamSub = stream.listen((Uint8List pcmBytes) {
      if (sessionState != SessionState.listeningToUser ||
          _opusEncoder == null ||
          _ws == null) {
        return;
      }

      final bd = ByteData.sublistView(pcmBytes);
      for (int i = 0; i <= pcmBytes.length - 2; i += 2) {
        _pcmMicBuffer.add(bd.getInt16(i, Endian.little));
      }

      while (_pcmMicBuffer.length >= 960) {
        final frameSamples =
            Int16List.fromList(_pcmMicBuffer.sublist(0, 960));
        _pcmMicBuffer.removeRange(0, 960);
        try {
          final Uint8List opusPacket =
              _opusEncoder!.encode(input: frameSamples);
          _ws!.add(opusPacket);
        } catch (_) {}
      }
    });
  }

  Future<void> _stopMicOpusStream() async {
    await _micStreamSub?.cancel();
    _micStreamSub = null;
    try {
      if (await _micRecorder.isRecording()) {
        await _micRecorder.stop();
      }
    } catch (_) {}
    _pcmMicBuffer.clear();
  }

  Future<void> _returnToStandbyMode() async {
    await _stopMicOpusStream();
    _voiceDecayTimer?.cancel();
    if (isXiaoZhiConnected && _ws != null) {
      _ws!.add(jsonEncode({
        "session_id": sessionId,
        "type": "abort",
        "reason": "wake_word_detected"
      }));
    }
    setState(() {
      sessionState = SessionState.standbyWakeWord;
      isVoiceAudioActive = false;
      currentEmotion = XiaoZhiEmotion.neutral;
      currentHandGesture = HandGesture.none;
      statusSubtitle = "Standby • Panggil \"Hai $petName\" untuk bicara";
    });
    _startWakeWordListener();
  }

  XiaoZhiEmotion _mapXiaoZhiEmotion(String emo) {
    final clean = emo.toLowerCase().trim();
    for (final val in XiaoZhiEmotion.values) {
      if (val.name == clean) return val;
    }
    return XiaoZhiEmotion.neutral;
  }

  void _initShakeDetector() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      double gForce =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gForce > 22.0) {
        final now = DateTime.now();
        if (now.difference(_lastShakeTime).inSeconds > 3) {
          _lastShakeTime = now;
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.dizzy,
              gesture: HandGesture.handsUp);
          _spawnParticle("💫", Colors.yellowAccent);
        }
      }
    });
  }

  void _updateClock() {
    final now = DateTime.now();
    final days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'
    ];
    setState(() {
      timeString =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
      dateString =
          "${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}";
    });
  }

  void _idleBehavior() {
    if (!mounted || currentEmotion == XiaoZhiEmotion.dead) return;
    _blinkController.forward().then((_) => _blinkController.reverse());

    final rand = Random();
    if (rand.nextBool()) {
      setState(() {
        gazeOffset = Offset(
          (rand.nextDouble() - 0.5) * 0.45,
          (rand.nextDouble() - 0.5) * 0.25,
        );
      });
    } else {
      setState(() => gazeOffset = Offset.zero);
    }
  }

  void _spawnParticle(String symbol, Color color) {
    final rand = Random();
    setState(() {
      particles.add(
        FloatingParticle(
          position: Offset(
            110 + rand.nextDouble() * 110,
            35 + rand.nextDouble() * 55,
          ),
          symbol: symbol,
          color: color,
        ),
      );
    });
  }

  void _updateParticles() {
    if (particles.isEmpty) return;
    setState(() {
      for (var p in particles) {
        p.position = p.position.translate(0, -2.2);
        p.opacity -= 0.03;
      }
      particles.removeWhere((p) => p.opacity <= 0);
    });
  }

  void _toggleOrientation() {
    setState(() => isLandscape = !isLandscape);
    if (isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void _onFaceTapDown(TapDownDetails details, Size faceAreaSize) {
    if (currentEmotion == XiaoZhiEmotion.dead) {
      _reviveFromDead();
      return;
    }

    final local = details.localPosition;
    final centerX = faceAreaSize.width / 2;
    final centerY = faceAreaSize.height / 2;

    final leftEyeCenter = Offset(centerX - 75, centerY - 20);
    final rightEyeCenter = Offset(centerX + 75, centerY - 20);

    if ((local - leftEyeCenter).distance < 45 ||
        (local - rightEyeCenter).distance < 45) {
      _setEmotionWithGestureAndSfx(XiaoZhiEmotion.angry,
          gesture: HandGesture.angryFists);
      _spawnParticle("💢", Colors.redAccent);
      return;
    }

    if (sessionState != SessionState.standbyWakeWord) {
      _returnToStandbyMode();
    } else {
      _triggerWakeUpToXiaoZhi("Hai $petName");
    }
  }

  void _onFacePanUpdate(DragUpdateDetails details, Size faceAreaSize) {
    if (currentEmotion == XiaoZhiEmotion.dead) return;
    final local = details.localPosition;
    final dx = ((local.dx / faceAreaSize.width) - 0.5) * 2.0;
    final dy = ((local.dy / faceAreaSize.height) - 0.5) * 2.0;

    setState(() {
      gazeOffset = Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
    });

    if (dy < -0.15) {
      rubCounter++;
      if (rubCounter % 14 == 0) {
        _spawnParticle("❤️", Colors.pinkAccent);
        _setEmotionWithGestureAndSfx(XiaoZhiEmotion.loving,
            gesture: HandGesture.coverCheeks);
      }
    }
  }

  void _onFacePanEnd(DragEndDetails details) {
    rubCounter = 0;
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => gazeOffset = Offset.zero);
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _floatController.dispose();
    _talkController.dispose();
    _handController.dispose();
    _clockTimer?.cancel();
    _idleTimer?.cancel();
    _particleTimer?.cancel();
    _wakeRestartTimer?.cancel();
    _voiceDecayTimer?.cancel();
    _reviveTimer?.cancel();
    _handResetTimer?.cancel();
    _accelSub?.cancel();
    _micStreamSub?.cancel();
    _micRecorder.dispose();
    _cameraController?.dispose();
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = currentEmotion == XiaoZhiEmotion.angry
        ? Colors.redAccent
        : (currentEmotion == XiaoZhiEmotion.loving ||
                currentEmotion == XiaoZhiEmotion.kissy)
            ? Colors.pinkAccent
            : currentEmotion == XiaoZhiEmotion.dead
                ? Colors.amberAccent
                : themeColors[themeColorIndex];

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // HUD Bar Atas
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              isLandscape
                                  ? Icons.stay_current_portrait
                                  : Icons.stay_current_landscape,
                              color: Colors.white70,
                              size: 20,
                            ),
                            onPressed: _toggleOrientation,
                          ),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: isXiaoZhiConnected
                                  ? Colors.greenAccent
                                  : Colors.redAccent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: isXiaoZhiConnected
                                      ? Colors.greenAccent
                                      : Colors.redAccent,
                                  blurRadius: 6,
                                )
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _fetchHardwareGpsAndWeather,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "HAI $petName",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                    color: baseColor,
                                  ),
                                ),
                                Text(
                                  weatherSummary,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.white60,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          Text(
                            timeString,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            dateString,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.gps_fixed,
                                color: Colors.redAccent, size: 22),
                            tooltip: "Main Shoot & Die (Tembak Pet!)",
                            onPressed: () => _triggerShootAndDie(),
                          ),
                          IconButton(
                            icon: Icon(
                              showCameraPreview
                                  ? Icons.videocam
                                  : Icons.videocam_off,
                              color: showCameraPreview
                                  ? Colors.greenAccent
                                  : Colors.white54,
                              size: 22,
                            ),
                            tooltip: "Preview Kamera Vision",
                            onPressed: () async {
                              if (_cameraController == null ||
                                  !_cameraController!.value.isInitialized) {
                                await _initCamerasAfterPermission(
                                    preferFront: true);
                              }
                              setState(
                                  () => showCameraPreview = !showCameraPreview);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.qr_code_2,
                                color: Colors.cyanAccent, size: 22),
                            tooltip: "Cek Kode Pairing XiaoZhi",
                            onPressed: () => _syncXiaoZhiOtaAndConnect(
                                showDialogIfPaired: true),
                          ),
                          IconButton(
                            icon: const Icon(Icons.tune,
                                color: Colors.white70, size: 22),
                            tooltip: "Warna Mata & Efek Suara",
                            onPressed: _showVisualSettingsDialog,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Area Wajah EMO Vektor + Alis + Tangan/Jari Ekspresif
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _onFaceTapDown(d, size),
                        onDoubleTapDown: (d) =>
                            _triggerShootAndDie(tapPosition: d.localPosition),
                        onDoubleTap: () {},
                        onPanUpdate: (d) => _onFacePanUpdate(d, size),
                        onPanEnd: _onFacePanEnd,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            AnimatedBuilder(
                              animation: Listenable.merge([
                                _blinkController,
                                _floatController,
                                _talkController,
                                _handController,
                              ]),
                              builder: (context, child) {
                                final double activeTalk = isVoiceAudioActive
                                    ? _talkController.value
                                    : 0.0;

                                return Transform.translate(
                                  offset: Offset(
                                    gazeOffset.dx * 12,
                                    (_floatController.value - 0.5) * 14 +
                                        gazeOffset.dy * 8,
                                  ),
                                  child: CustomPaint(
                                    size: const Size(360, 270),
                                    painter: EmoRobotFaceAndHandsPainter(
                                      emotion: currentEmotion,
                                      handGesture: currentHandGesture,
                                      blinkValue: _blinkController.value,
                                      isTalking: isVoiceAudioActive,
                                      talkValue: activeTalk,
                                      handAnimValue: _handController.value,
                                      gazeOffset: gazeOffset,
                                      faceColor: baseColor,
                                    ),
                                  ),
                                );
                              },
                            ),
                            ...particles.map(
                              (p) => Positioned(
                                left: (size.width / 2 - 160) + p.position.dx,
                                top: (size.height / 2 - 110) + p.position.dy,
                                child: Opacity(
                                  opacity: p.opacity.clamp(0.0, 1.0),
                                  child: Text(
                                    p.symbol,
                                    style: TextStyle(
                                      fontSize: p.size,
                                      color: p.color,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // Bar Tes Cepat Ekspresi & Gestur Tangan EMO
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      _buildActionChip("💥 TEMBAK!", () => _triggerShootAndDie()),
                      _buildActionChip(
                          "👋 Sapa",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.happy,
                              gesture: HandGesture.wave)),
                      _buildActionChip(
                          "✌️ Peace",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.winking,
                              gesture: HandGesture.peace)),
                      _buildActionChip(
                          "😎 Cool",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.cool,
                              gesture: HandGesture.thumbsUp)),
                      _buildActionChip(
                          "🤔 Mikir",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.thinking,
                              gesture: HandGesture.thinkingChin)),
                      _buildActionChip(
                          "😠 Marah",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.angry,
                              gesture: HandGesture.angryFists)),
                      _buildActionChip(
                          "😭 Nangis",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.crying)),
                      _buildActionChip(
                          "😍 Sayang",
                          () => _setEmotionWithGestureAndSfx(
                              XiaoZhiEmotion.loving,
                              gesture: HandGesture.coverCheeks)),
                    ],
                  ),
                ),

                // Indikator Status & Subtitle XiaoZhi
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: 18, left: 24, right: 24, top: 6),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 13),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: sessionState == SessionState.listeningToUser
                            ? Colors.greenAccent
                            : isVoiceAudioActive
                                ? Colors.cyanAccent
                                : Colors.white24,
                        width: sessionState == SessionState.standbyWakeWord
                            ? 1
                            : 2,
                      ),
                    ),
                    child: Text(
                      statusSubtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),

            // Overlay Retak Layar Kaca (Saat Mode Shoot & Die)
            if (isScreenCracked)
              IgnorePointer(
                child: CustomPaint(
                  size: MediaQuery.of(context).size,
                  painter: ScreenCrackPainter(
                    origin: crackOrigin,
                    branches: crackBranches,
                  ),
                ),
              ),

            // Efek Flash Putih Saat Ditembak
            if (shootFlashOpacity > 0)
              IgnorePointer(
                child: Container(
                  color: Colors.white.withOpacity(shootFlashOpacity),
                ),
              ),

            // Jendela Preview Kamera Vision
            if (showCameraPreview &&
                _cameraController != null &&
                _cameraController!.value.isInitialized)
              Positioned(
                right: 16,
                bottom: 130,
                child: GestureDetector(
                  onTap: () => _switchCameraLens(),
                  child: Container(
                    width: 115,
                    height: 155,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: baseColor, width: 2),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(_cameraController!),
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _currentLensName == 'front'
                                  ? "SELFIE"
                                  : "BELAKANG",
                              style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.cameraswitch,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionChip(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        backgroundColor: Colors.white.withOpacity(0.08),
        onPressed: onTap,
      ),
    );
  }

  void _showPairingDialog(String code, String? serverMsg) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("🔗 Kode Pairing XiaoZhi"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Masukkan 6 angka ini di menu Add Device pada dashboard xiaozhi.me:",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.cyanAccent),
              ),
              child: Text(
                code,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 8,
                  color: Colors.cyanAccent,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Device MAC: $deviceMac",
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _syncXiaoZhiOtaAndConnect();
            },
            child: const Text("Sudah Saya Pairing, Hubungkan!"),
          ),
        ],
      ),
    );
  }

  // Menu Pengaturan Bersih (Tanpa Input Nama Pet & Tanpa Saklar Emoji)
  void _showVisualSettingsDialog() {
    int selectedColor = themeColorIndex;
    bool tempSfx = enableRobotSfx;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Tampilan & Suara Ekspresi"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Warna Neon Robot:", style: TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(themeColors.length, (idx) {
                  return GestureDetector(
                    onTap: () => setDialogState(() => selectedColor = idx),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: themeColors[idx],
                      child: selectedColor == idx
                          ? const Icon(Icons.check,
                              color: Colors.black, size: 18)
                          : null,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("Efek Suara Ekspresi (SFX Robot)",
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                    "Bunyi chirp, beep, & efek suara saat ganti ekspresi/bermain",
                    style: TextStyle(fontSize: 11)),
                value: tempSfx,
                onChanged: (v) => setDialogState(() => tempSfx = v),
              ),
              const Divider(),
              Text(
                "Nama Pet (Sync Server): $petName\nLokasi GPS: $locationName\nMAC Address: $deviceMac",
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('themeColorIndex', selectedColor);
                await prefs.setBool('enableRobotSfx', tempSfx);
                setState(() {
                  themeColorIndex = selectedColor;
                  enableRobotSfx = tempSfx;
                });
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text("Simpan"),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// PAINTER 1: WAJAH ROBOT EMO + ALIS ARTIKULASI + TANGAN & JARI EKSPRESIF
// =========================================================================
class EmoRobotFaceAndHandsPainter extends CustomPainter {
  final XiaoZhiEmotion emotion;
  final HandGesture handGesture;
  final double blinkValue;
  final bool isTalking;
  final double talkValue;
  final double handAnimValue;
  final Offset gazeOffset;
  final Color faceColor;

  EmoRobotFaceAndHandsPainter({
    required this.emotion,
    required this.handGesture,
    required this.blinkValue,
    required this.isTalking,
    required this.talkValue,
    required this.handAnimValue,
    required this.gazeOffset,
    required this.faceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = faceColor.withOpacity(0.32)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);

    double eyeWidth = 66;
    double eyeHeight = 80 * (1.0 - blinkValue * 0.92);

    final gazeShift = Offset(gazeOffset.dx * 16, gazeOffset.dy * 12);
    final leftCenter =
        Offset(size.width * 0.30, size.height * 0.44) + gazeShift;
    final rightCenter =
        Offset(size.width * 0.70, size.height * 0.44) + gazeShift;

    // 1. Jika Mode DEAD (Mati setelah ditembak), gambar Cincin Halo Malaikat di atas kepala
    if (emotion == XiaoZhiEmotion.dead) {
      final haloCenter = Offset(size.width * 0.5, size.height * 0.11);
      final haloGlow = Paint()
        ..color = Colors.amberAccent.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      final haloStroke = Paint()
        ..color = Colors.amberAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5;
      canvas.drawOval(
          Rect.fromCenter(center: haloCenter, width: 110, height: 26),
          haloGlow);
      canvas.drawOval(
          Rect.fromCenter(center: haloCenter, width: 110, height: 26),
          haloStroke);
    }

    // 2. Gambar Alis Mata Dinamis di atas kedua mata (Gaya EMO Pet)
    _drawEyebrows(canvas, leftCenter, rightCenter, eyeWidth);

    // 3. Gambar Kedua Bola Mata
    _drawCustomEye(
        canvas, leftCenter, eyeWidth, eyeHeight, paint, glowPaint, true);
    _drawCustomEye(
        canvas, rightCenter, eyeWidth, eyeHeight, paint, glowPaint, false);

    // 4. Pipi Merona
    if (emotion == XiaoZhiEmotion.loving ||
        emotion == XiaoZhiEmotion.kissy ||
        emotion == XiaoZhiEmotion.happy ||
        emotion == XiaoZhiEmotion.embarrassed ||
        emotion == XiaoZhiEmotion.delicious) {
      final blushPaint = Paint()
        ..color = Colors.pinkAccent.withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawOval(
        Rect.fromCenter(
            center: leftCenter.translate(-18, 50), width: 34, height: 16),
        blushPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(18, 50), width: 34, height: 16),
        blushPaint,
      );
    }

    // 5. Genangan Air Mata
    if (emotion == XiaoZhiEmotion.crying) {
      final tearPaint = Paint()..color = Colors.lightBlueAccent;
      final double tearOffset = handAnimValue * 10;
      canvas.drawOval(
        Rect.fromCenter(
            center: leftCenter.translate(-6, 52 + tearOffset),
            width: 12,
            height: 22),
        tearPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(6, 52 + tearOffset),
            width: 12,
            height: 22),
        tearPaint,
      );
    }

    // 6. Kacamata Visor Cool
    if (emotion == XiaoZhiEmotion.cool) {
      final bridgePaint = Paint()
        ..color = faceColor
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke;
      canvas.drawLine(leftCenter.translate(32, -8),
          rightCenter.translate(-32, -8), bridgePaint);
    }

    // 7. Gambar Mulut Anti-Tumpuk
    _drawMouth(canvas, size, gazeShift * 0.5);

    // 8. Gambar Tangan & Jari Robot Ekspresif
    _drawExpressiveHands(canvas, size, paint, glowPaint);
  }

  void _drawEyebrows(
      Canvas canvas, Offset leftEye, Offset rightEye, double eyeW) {
    final browPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5
      ..strokeCap = StrokeCap.round;

    double leftOuterY = -56;
    double leftInnerY = -56;
    double rightInnerY = -56;
    double rightOuterY = -56;

    switch (emotion) {
      case XiaoZhiEmotion.angry:
        leftOuterY = -64;
        leftInnerY = -42;
        rightInnerY = -42;
        rightOuterY = -64;
        break;
      case XiaoZhiEmotion.confident:
      case XiaoZhiEmotion.cool:
        leftOuterY = -58;
        leftInnerY = -46;
        rightInnerY = -54;
        rightOuterY = -68;
        break;
      case XiaoZhiEmotion.sad:
      case XiaoZhiEmotion.crying:
      case XiaoZhiEmotion.embarrassed:
        leftOuterY = -42;
        leftInnerY = -62;
        rightInnerY = -62;
        rightOuterY = -42;
        break;
      case XiaoZhiEmotion.thinking:
      case XiaoZhiEmotion.confused:
        leftOuterY = -50;
        leftInnerY = -50;
        rightInnerY = -70;
        rightOuterY = -66;
        break;
      case XiaoZhiEmotion.surprised:
      case XiaoZhiEmotion.shocked:
        leftOuterY = -70;
        leftInnerY = -74;
        rightInnerY = -74;
        rightOuterY = -70;
        break;
      case XiaoZhiEmotion.happy:
      case XiaoZhiEmotion.laughing:
      case XiaoZhiEmotion.loving:
      case XiaoZhiEmotion.winking:
        leftOuterY = -60;
        leftInnerY = -64;
        rightInnerY = -64;
        rightOuterY = -60;
        break;
      case XiaoZhiEmotion.sleepy:
      case XiaoZhiEmotion.dead:
        leftOuterY = -44;
        leftInnerY = -48;
        rightInnerY = -48;
        rightOuterY = -44;
        break;
      default:
        leftOuterY = -56;
        leftInnerY = -56;
        rightInnerY = -56;
        rightOuterY = -56;
        break;
    }

    final leftPath = Path()
      ..moveTo(leftEye.dx - eyeW * 0.48, leftEye.dy + leftOuterY)
      ..quadraticBezierTo(
        leftEye.dx,
        leftEye.dy + ((leftOuterY + leftInnerY) / 2) - 6,
        leftEye.dx + eyeW * 0.48,
        leftEye.dy + leftInnerY,
      );

    final rightPath = Path()
      ..moveTo(rightEye.dx - eyeW * 0.48, rightEye.dy + rightInnerY)
      ..quadraticBezierTo(
        rightEye.dx,
        rightEye.dy + ((rightInnerY + rightOuterY) / 2) - 6,
        rightEye.dx + eyeW * 0.48,
        rightEye.dy + rightOuterY,
      );

    canvas.drawPath(leftPath, browPaint);
    canvas.drawPath(rightPath, browPaint);
  }

  void _drawCustomEye(Canvas canvas, Offset center, double w, double h,
      Paint paint, Paint glowPaint, bool isLeft) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;

    if (emotion == XiaoZhiEmotion.dead || emotion == XiaoZhiEmotion.dizzy) {
      double r = 24;
      canvas.drawLine(
          center.translate(-r, -r), center.translate(r, r), strokePaint);
      canvas.drawLine(
          center.translate(r, -r), center.translate(-r, r), strokePaint);
      return;
    }

    if ((emotion == XiaoZhiEmotion.winking ||
            emotion == XiaoZhiEmotion.kissy ||
            emotion == XiaoZhiEmotion.silly) &&
        !isLeft) {
      canvas.drawArc(
        Rect.fromCenter(center: center, width: w, height: 25),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == XiaoZhiEmotion.happy ||
        emotion == XiaoZhiEmotion.laughing ||
        emotion == XiaoZhiEmotion.funny ||
        emotion == XiaoZhiEmotion.relaxed ||
        emotion == XiaoZhiEmotion.delicious) {
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 10), width: w, height: 52),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == XiaoZhiEmotion.loving) {
      final path = Path();
      double s = 32;
      path.moveTo(center.dx, center.dy + s * 0.8);
      path.cubicTo(center.dx - s * 1.4, center.dy, center.dx - s * 0.7,
          center.dy - s * 1.1, center.dx, center.dy - s * 0.3);
      path.cubicTo(center.dx + s * 0.7, center.dy - s * 1.1,
          center.dx + s * 1.4, center.dy, center.dx, center.dy + s * 0.8);
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, paint);
      return;
    }

    if (emotion == XiaoZhiEmotion.sleepy) {
      h *= 0.22;
    } else if (emotion == XiaoZhiEmotion.surprised ||
        emotion == XiaoZhiEmotion.shocked) {
      w = 72;
      h = 72 * (1.0 - blinkValue * 0.9);
    } else if (emotion == XiaoZhiEmotion.confused && isLeft) {
      h *= 0.62;
    } else if (emotion == XiaoZhiEmotion.cool) {
      h *= 0.66;
    }

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      Radius.circular(
          (emotion == XiaoZhiEmotion.surprised ||
                  emotion == XiaoZhiEmotion.shocked)
              ? 40
              : 22),
    );
    canvas.drawRRect(rect, glowPaint);
    canvas.drawRRect(rect, paint);

    final maskPaint = Paint()..color = Colors.black;
    if (emotion == XiaoZhiEmotion.angry ||
        emotion == XiaoZhiEmotion.confident) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - 5);
        path.lineTo(center.dx - w, center.dy - h * 0.55);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      }
      path.close();
      canvas.drawPath(path, maskPaint);
    } else if (emotion == XiaoZhiEmotion.sad ||
        emotion == XiaoZhiEmotion.crying ||
        emotion == XiaoZhiEmotion.embarrassed) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - 5);
        path.lineTo(center.dx - w, center.dy - h * 0.55);
      }
      path.close();
      canvas.drawPath(path, maskPaint);
    }
  }

  void _drawMouth(Canvas canvas, Size size, Offset shift) {
    final mouthCenter = Offset(size.width * 0.5, size.height * 0.78) + shift;
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    if (isTalking && emotion != XiaoZhiEmotion.dead) {
      final double openHeight = 10.0 + (talkValue * 28.0);
      final double openWidth = 42.0 + (talkValue * 14.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: mouthCenter, width: openWidth, height: openHeight),
          const Radius.circular(18),
        ),
        fillPaint,
      );
      return;
    }

    switch (emotion) {
      case XiaoZhiEmotion.dead:
        // Mulut miring + lidah menjulur keluar saat mati
        canvas.drawLine(
          mouthCenter.translate(-26, 2),
          mouthCenter.translate(26, -2),
          strokePaint,
        );
        final tonguePaint = Paint()..color = Colors.pinkAccent;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: mouthCenter.translate(8, 14), width: 18, height: 22),
            const Radius.circular(9),
          ),
          tonguePaint,
        );
        break;

      case XiaoZhiEmotion.laughing:
      case XiaoZhiEmotion.funny:
        final path = Path()
          ..moveTo(mouthCenter.dx - 32, mouthCenter.dy - 6)
          ..lineTo(mouthCenter.dx + 32, mouthCenter.dy - 6)
          ..arcToPoint(
            Offset(mouthCenter.dx - 32, mouthCenter.dy - 6),
            radius: const Radius.circular(32),
            clockwise: true,
          )
          ..close();
        canvas.drawPath(path, fillPaint);
        break;

      case XiaoZhiEmotion.happy:
      case XiaoZhiEmotion.loving:
      case XiaoZhiEmotion.winking:
      case XiaoZhiEmotion.relaxed:
      case XiaoZhiEmotion.confident:
      case XiaoZhiEmotion.cool:
        canvas.drawArc(
          Rect.fromCenter(
              center: mouthCenter.translate(0, -6), width: 58, height: 34),
          0,
          pi,
          false,
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.delicious:
      case XiaoZhiEmotion.silly:
        canvas.drawArc(
          Rect.fromCenter(
              center: mouthCenter.translate(0, -6), width: 56, height: 30),
          0,
          pi,
          false,
          strokePaint,
        );
        final tonguePaint = Paint()..color = Colors.pinkAccent;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: mouthCenter.translate(6, 12), width: 20, height: 22),
            const Radius.circular(10),
          ),
          tonguePaint,
        );
        break;

      case XiaoZhiEmotion.kissy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 20, height: 22),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.angry:
      case XiaoZhiEmotion.sad:
      case XiaoZhiEmotion.crying:
        canvas.drawArc(
          Rect.fromCenter(
              center: mouthCenter.translate(0, 14), width: 50, height: 28),
          pi,
          pi,
          false,
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.surprised:
      case XiaoZhiEmotion.shocked:
      case XiaoZhiEmotion.dizzy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 30, height: 34),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.thinking:
      case XiaoZhiEmotion.confused:
      case XiaoZhiEmotion.embarrassed:
        canvas.drawLine(
          mouthCenter.translate(-22, 4),
          mouthCenter.translate(22, -4),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.sleepy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 16, height: 16),
          strokePaint,
        );
        break;

      case XiaoZhiEmotion.neutral:
        canvas.drawArc(
          Rect.fromCenter(
              center: mouthCenter.translate(0, -4), width: 42, height: 18),
          0,
          pi,
          false,
          strokePaint,
        );
        break;
    }
  }

  // Menggambar Tangan & Jari Robot Neon Ekspresif
  void _drawExpressiveHands(
      Canvas canvas, Size size, Paint fillPaint, Paint glowPaint) {
    if (handGesture == HandGesture.none) return;

    final double bounce = (handAnimValue - 0.5) * 16;

    switch (handGesture) {
      case HandGesture.wave:
        final palm = Offset(size.width * 0.88, size.height * 0.52 + bounce);
        _drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.45, -0.15, 0.12, 0.38],
          fingerLengths: [22, 26, 25, 20],
          rotation: (handAnimValue - 0.5) * 0.45,
        );
        break;

      case HandGesture.peace:
        // Gestur 2 Jari Peace (V-Sign)
        final palm = Offset(size.width * 0.88, size.height * 0.55 + bounce * 0.5);
        _drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.24, 0.22],
          fingerLengths: [32, 32],
          rotation: -0.1,
        );
        break;

      case HandGesture.thumbsUp:
        // Gestur Jempol Keren
        final palm = Offset(size.width * 0.86, size.height * 0.58 + bounce * 0.4);
        _drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.85],
          fingerLengths: [30],
        );
        break;

      case HandGesture.thinkingChin:
        // Tangan di bawah dagu mengetuk jari telunjuk
        final palm = Offset(
            size.width * 0.62, size.height * 0.90 + (handAnimValue * 5));
        _drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.35],
          fingerLengths: [26],
        );
        break;

      case HandGesture.angryFists:
        // Kedua kepalan tinju bergetar
        final shake = sin(handAnimValue * pi * 4) * 6;
        final leftFist =
            Offset(size.width * 0.12 + shake, size.height * 0.62);
        final rightFist =
            Offset(size.width * 0.88 - shake, size.height * 0.62);
        _drawPalmWithFingers(canvas, leftFist, fillPaint, glowPaint,
            fingerAngles: [], fingerLengths: []);
        _drawPalmWithFingers(canvas, rightFist, fillPaint, glowPaint,
            fingerAngles: [], fingerLengths: []);
        break;

      case HandGesture.coverCheeks:
        final leftPalm =
            Offset(size.width * 0.15, size.height * 0.60 + bounce * 0.3);
        final rightPalm =
            Offset(size.width * 0.85, size.height * 0.60 + bounce * 0.3);
        _drawPalmWithFingers(
          canvas,
          leftPalm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.2, 0.0, 0.2],
          fingerLengths: [18, 20, 18],
        );
        _drawPalmWithFingers(
          canvas,
          rightPalm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.2, 0.0, 0.2],
          fingerLengths: [18, 20, 18],
        );
        break;

      case HandGesture.handsUp:
        // Kedua tangan angkat ke atas saat ditembak!
        final leftUp =
            Offset(size.width * 0.12, size.height * 0.25 + bounce * 0.6);
        final rightUp =
            Offset(size.width * 0.88, size.height * 0.25 + bounce * 0.6);
        _drawPalmWithFingers(
          canvas,
          leftUp,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.4, -0.12, 0.15, 0.4],
          fingerLengths: [22, 25, 25, 20],
        );
        _drawPalmWithFingers(
          canvas,
          rightUp,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.4, -0.12, 0.15, 0.4],
          fingerLengths: [22, 25, 25, 20],
        );
        break;

      case HandGesture.deadDrop:
        // Tangan terkulai lemas di bawah saat mati
        final leftDead = Offset(size.width * 0.16, size.height * 0.86);
        final rightDead = Offset(size.width * 0.84, size.height * 0.86);
        _drawPalmWithFingers(
          canvas,
          leftDead,
          fillPaint,
          glowPaint,
          fingerAngles: [2.8, 3.1, 3.4],
          fingerLengths: [18, 20, 18],
        );
        _drawPalmWithFingers(
          canvas,
          rightDead,
          fillPaint,
          glowPaint,
          fingerAngles: [2.8, 3.1, 3.4],
          fingerLengths: [18, 20, 18],
        );
        break;

      case HandGesture.none:
        break;
    }
  }

  void _drawPalmWithFingers(
    Canvas canvas,
    Offset palmCenter,
    Paint fillPaint,
    Paint glowPaint, {
    required List<double> fingerAngles,
    required List<double> fingerLengths,
    double rotation = 0.0,
  }) {
    canvas.save();
    canvas.translate(palmCenter.dx, palmCenter.dy);
    canvas.rotate(rotation);

    // Telapak tangan bulat neon
    final palmRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 36, height: 32),
      const Radius.circular(14),
    );
    canvas.drawRRect(palmRect, glowPaint);
    canvas.drawRRect(palmRect, fillPaint);

    // Jari-jari artikulasi
    final fingerStroke = Paint()
      ..color = fillPaint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.5
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < fingerAngles.length; i++) {
      final double ang = fingerAngles[i] - (pi / 2);
      final double len = fingerLengths[i];
      final start = Offset(cos(ang) * 14, sin(ang) * 14);
      final end = Offset(cos(ang) * (14 + len), sin(ang) * (14 + len));
      canvas.drawLine(start, end, fingerStroke);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EmoRobotFaceAndHandsPainter oldDelegate) => true;
}

// =========================================================================
// PAINTER 2: ANIMASI RETAK KACA LAYAR (SAAT DITEMBAK / SHOOT & DIE)
// =========================================================================
class ScreenCrackPainter extends CustomPainter {
  final Offset origin;
  final List<List<Offset>> branches;

  ScreenCrackPainter({required this.origin, required this.branches});

  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..color = Colors.cyanAccent.withOpacity(0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final crackPaint = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    // Lubang titik tembakan di kaca
    canvas.drawCircle(origin, 10, glowPaint);
    canvas.drawCircle(origin, 6, Paint()..color = Colors.white);

    // Cincin retakan melingkar
    canvas.drawCircle(origin, 28, crackPaint);
    canvas.drawCircle(origin, 58, crackPaint..strokeWidth = 1.4);

    // Garis-garis retakan menyebar
    for (final branch in branches) {
      if (branch.length < 2) continue;
      final path = Path()..moveTo(branch.first.dx, branch.first.dy);
      for (int i = 1; i < branch.length; i++) {
        path.lineTo(branch[i].dx, branch[i].dy);
      }
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, crackPaint..strokeWidth = 2.2);
    }
  }

  @override
  bool shouldRepaint(covariant ScreenCrackPainter oldDelegate) => true;
}
