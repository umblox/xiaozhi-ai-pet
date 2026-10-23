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

// 21 Emosi Resmi Bawaan XiaoZhi + Dizzy (Sensor Goyang)
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

  // Pengaturan Wake Word & Tampilan
  String wakePetName = "kimmi";
  int themeColorIndex = 1;
  bool useEmojiStyle = false; // false = Robot Neon, true = Emoji XiaoZhi

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
  bool isVoiceAudioActive = false; // True hanya saat paket suara Opus berbunyi
  Timer? _voiceDecayTimer;

  final stt.SpeechToText _wakeStt = stt.SpeechToText();
  final AudioRecorder _micRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micStreamSub;
  SimpleOpusEncoder? _opusEncoder;
  SimpleOpusDecoder? _opusDecoder;
  final List<int> _pcmMicBuffer = [];
  int _serverSampleRate = 24000;

  // Kamera MCP Vision (Mendukung Pindah Selfie / Belakang)
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
  String statusSubtitle = "Menginisialisasi koneksi XiaoZhi...";

  Offset gazeOffset = Offset.zero;
  int rubCounter = 0;
  final List<FloatingParticle> particles = [];

  late AnimationController _blinkController;
  late AnimationController _floatController;
  late AnimationController _talkController;
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
      wakePetName = prefs.getString('wakePetName') ?? "kimmi";
      themeColorIndex = prefs.getInt('themeColorIndex') ?? 1;
      useEmojiStyle = prefs.getBool('useEmojiStyle') ?? false;
    });
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
  // 1. KAMERA VISION (DEFAULT KAMERA SELFIE & BISA PINDAH DEPAN/BELAKANG)
  // =======================================================================
  Future<void> _initCamerasAfterPermission({bool preferFront = true}) async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      if (preferFront) {
        final frontIdx = _cameras.indexWhere(
            (c) => c.lensDirection == CameraLensDirection.front);
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
        ResolutionPreset.low, // Ukuran ringan agar upload Vision cepat & anti gagal
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
    final lens = _cameras[_selectedCameraIdx].lensDirection ==
            CameraLensDirection.front
        ? "front"
        : "back";
    return lens;
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
  // 2. LOKASI GPS ASLI HP + CUACA REAL-TIME
  // =======================================================================
  Future<void> _fetchHardwareGpsAndWeather() async {
    try {
      // Ambil titik koordinat dari Hardware GPS Android via Native Channel
      final dynamic gpsMap =
          await _deviceChannel.invokeMethod('getGpsLocation');
      if (gpsMap != null && gpsMap is Map) {
        gpsLat = (gpsMap['lat'] as num?)?.toDouble();
        gpsLon = (gpsMap['lon'] as num?)?.toDouble();
      }

      // Jika GPS di dalam ruangan belum mengunci, gunakan fallback geo
      if (gpsLat == null || gpsLon == null) {
        final ipRes = await http
            .get(Uri.parse("https://api.bigdatacloud.net/data/reverse-geocode-client?localityLanguage=id"))
            .timeout(const Duration(seconds: 6));
        if (ipRes.statusCode == 200) {
          final d = jsonDecode(ipRes.body);
          gpsLat = (d['latitude'] as num?)?.toDouble();
          gpsLon = (d['longitude'] as num?)?.toDouble();
        }
      }

      if (gpsLat != null && gpsLon != null) {
        // Reverse Geocoding akurat dari koordinat GPS ke Nama Kecamatan/Kota
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

        // Ambil cuaca sesuai koordinat GPS
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
  // 3. PROTOKOL OTA & WEBSOCKET XIAOZHI
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
          setState(() {
            currentEmotion = XiaoZhiEmotion.surprised;
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
          statusSubtitle =
              "Standby • Panggil \"Hai $wakePetName\" untuk bicara";
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
          setState(() {
            statusSubtitle = "\"$text\"";
            currentEmotion = XiaoZhiEmotion.thinking;
          });
        }
      } else if (type == 'llm') {
        final emo = data['emotion']?.toString() ?? "neutral";
        if (mounted) {
          setState(() => currentEmotion = _mapXiaoZhiEmotion(emo));
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
            // Jika teks diawali '%' (contoh: % self.camera.take_photo...), tampilkan rapi
            if (text.trim().startsWith('%')) {
              setState(() {
                statusSubtitle = "⚙️ Menjalankan perintah: ${text.replaceFirst('%', '').trim()}";
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
            if (mounted && isXiaoZhiConnected) {
              _beginActiveOpusListening();
            }
          });
        }
      } else if (type == 'mcp') {
        _handleMcpPayload(data['payload']);
      }
    } catch (_) {}
  }

  // Decode Paket Audio Opus Biner -> Speaker HP + Aktifkan Animasi Mulut Mulus
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
  // 4. PROTOKOL MCP LENGKAP (VISION, SWITCH CAMERA, GPS, WEATHER, VOLUME)
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
        "serverInfo": {"name": "XiaoZhi-Android-Pet", "version": "2.1.0"}
      });
    } else if (method == 'tools/list') {
      _sendMcpReply(id, {
        "tools": [
          {
            "name": "self.get_device_status",
            "description":
                "Provides real-time device status including GPS location, city/district name, local weather, audio speaker volume, and active camera direction (front/back).",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.location.get_current_location",
            "description":
                "Get the user's exact hardware GPS coordinates, subdistrict/city address, and local weather condition.",
            "inputSchema": {"type": "object", "properties": {}}
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
        setState(() {
          currentEmotion = XiaoZhiEmotion.surprised;
          statusSubtitle =
              "📸 Memotret dengan kamera ${_currentLensName == 'front' ? 'Selfie' : 'Belakang'}...";
        });
      }

      // Beri jeda singkat agar sensor kamera stabil
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
  // 5. WAKE WORD HANDS-FREE & STREAMING MIKROFON OPUS
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
          if (_isWakePhraseDetected(spoken)) {
            _wakeStt.stop();
            _triggerWakeUpToXiaoZhi(spoken);
          }
        },
      );
    } catch (_) {}
  }

  bool _isWakePhraseDetected(String text) {
    if (text.isEmpty) return false;
    final targetName = wakePetName.toLowerCase().trim();
    final wakePrefixes = ['hai', 'halo', 'hello', 'hey', 'hi'];

    for (final prefix in wakePrefixes) {
      if (text.contains('$prefix $targetName') || text.contains(targetName)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _triggerWakeUpToXiaoZhi(String wakeText) async {
    if (!isXiaoZhiConnected || _ws == null) {
      await _connectXiaoZhiWs();
    }
    _spawnParticle("✨", Colors.cyanAccent);

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
      statusSubtitle = "Standby • Panggil \"Hai $wakePetName\" untuk bicara";
    });
    _startWakeWordListener();
  }

  // Pemetaan 21 Emosi Resmi XiaoZhi
  XiaoZhiEmotion _mapXiaoZhiEmotion(String emo) {
    final clean = emo.toLowerCase().trim();
    for (final val in XiaoZhiEmotion.values) {
      if (val.name == clean) return val;
    }
    return XiaoZhiEmotion.neutral;
  }

  String _getXiaoZhiEmojiChar(XiaoZhiEmotion emo) {
    switch (emo) {
      case XiaoZhiEmotion.neutral:
        return "😶";
      case XiaoZhiEmotion.happy:
        return "🙂";
      case XiaoZhiEmotion.laughing:
        return "😆";
      case XiaoZhiEmotion.funny:
        return "😂";
      case XiaoZhiEmotion.sad:
        return "😔";
      case XiaoZhiEmotion.angry:
        return "😠";
      case XiaoZhiEmotion.crying:
        return "😭";
      case XiaoZhiEmotion.loving:
        return "😍";
      case XiaoZhiEmotion.embarrassed:
        return "😳";
      case XiaoZhiEmotion.surprised:
        return "😲";
      case XiaoZhiEmotion.shocked:
        return "😱";
      case XiaoZhiEmotion.thinking:
        return "🤔";
      case XiaoZhiEmotion.winking:
        return "😉";
      case XiaoZhiEmotion.cool:
        return "😎";
      case XiaoZhiEmotion.relaxed:
        return "😌";
      case XiaoZhiEmotion.delicious:
        return "🤤";
      case XiaoZhiEmotion.kissy:
        return "😘";
      case XiaoZhiEmotion.confident:
        return "😏";
      case XiaoZhiEmotion.sleepy:
        return "😴";
      case XiaoZhiEmotion.silly:
        return "😜";
      case XiaoZhiEmotion.confused:
        return "🙄";
      case XiaoZhiEmotion.dizzy:
        return "😵‍💫";
    }
  }

  void _initShakeDetector() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      double gForce =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gForce > 22.0) {
        final now = DateTime.now();
        if (now.difference(_lastShakeTime).inSeconds > 3) {
          _lastShakeTime = now;
          setState(() => currentEmotion = XiaoZhiEmotion.dizzy);
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
    if (!mounted) return;
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
    final local = details.localPosition;
    final centerX = faceAreaSize.width / 2;
    final centerY = faceAreaSize.height / 2;

    final leftEyeCenter = Offset(centerX - 75, centerY - 20);
    final rightEyeCenter = Offset(centerX + 75, centerY - 20);

    if (!useEmojiStyle &&
        ((local - leftEyeCenter).distance < 45 ||
            (local - rightEyeCenter).distance < 45)) {
      setState(() => currentEmotion = XiaoZhiEmotion.angry);
      _spawnParticle("💢", Colors.redAccent);
      return;
    }

    if (sessionState != SessionState.standbyWakeWord) {
      _returnToStandbyMode();
    } else {
      _triggerWakeUpToXiaoZhi("Hai $wakePetName");
    }
  }

  void _onFacePanUpdate(DragUpdateDetails details, Size faceAreaSize) {
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
        setState(() => currentEmotion = XiaoZhiEmotion.loving);
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
    _clockTimer?.cancel();
    _idleTimer?.cancel();
    _particleTimer?.cancel();
    _wakeRestartTimer?.cancel();
    _voiceDecayTimer?.cancel();
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
            : themeColors[themeColorIndex];

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // HUD Bar Atas (Status XiaoZhi, Lokasi GPS Asli, Jam, Kamera, Pairing)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                                  "HAI ${wakePetName.toUpperCase()}",
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
                            icon: Icon(
                              showCameraPreview
                                  ? Icons.videocam
                                  : Icons.videocam_off,
                              color: showCameraPreview
                                  ? Colors.greenAccent
                                  : Colors.white54,
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
                                color: Colors.cyanAccent),
                            tooltip: "Cek Kode Pairing XiaoZhi",
                            onPressed: () => _syncXiaoZhiOtaAndConnect(
                                showDialogIfPaired: true),
                          ),
                          IconButton(
                            icon: const Icon(Icons.tune, color: Colors.white70),
                            tooltip: "Atur Wake Word & Mode Wajah",
                            onPressed: _showWakeSettingsDialog,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Area Wajah (Mode Robot Neon 21 Ekspresi ATAU Mode Emoji Animasi XiaoZhi)
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _onFaceTapDown(d, size),
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
                              ]),
                              builder: (context, child) {
                                final double activeTalk = isVoiceAudioActive
                                    ? _talkController.value
                                    : 0.0;

                                if (useEmojiStyle) {
                                  // Mode Animasi Emoji Bawaan XiaoZhi
                                  final scale =
                                      1.0 + (activeTalk * 0.14);
                                  return Transform.translate(
                                    offset: Offset(
                                      gazeOffset.dx * 14,
                                      (_floatController.value - 0.5) * 16 +
                                          gazeOffset.dy * 10,
                                    ),
                                    child: Transform.scale(
                                      scale: scale,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _getXiaoZhiEmojiChar(
                                                currentEmotion),
                                            style: const TextStyle(
                                                fontSize: 135),
                                          ),
                                          const SizedBox(height: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: baseColor.withOpacity(0.15),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              currentEmotion.name.toUpperCase(),
                                              style: TextStyle(
                                                fontSize: 11,
                                                letterSpacing: 1.5,
                                                color: baseColor,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }

                                // Mode Wajah Robot Neon 21 Ekspresi (Bebas Tumpuk)
                                return Transform.translate(
                                  offset: Offset(
                                    gazeOffset.dx * 12,
                                    (_floatController.value - 0.5) * 14 +
                                        gazeOffset.dy * 8,
                                  ),
                                  child: CustomPaint(
                                    size: const Size(320, 230),
                                    painter: RobotFacePainter(
                                      emotion: currentEmotion,
                                      blinkValue: _blinkController.value,
                                      isTalking: isVoiceAudioActive,
                                      talkValue: activeTalk,
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

                // Indikator Status & Subtitle XiaoZhi
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: 22, left: 24, right: 24),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
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

            // Jendela Preview Kamera Vision (Ketuk untuk Ganti Selfie <-> Belakang)
            if (showCameraPreview &&
                _cameraController != null &&
                _cameraController!.value.isInitialized)
              Positioned(
                right: 16,
                bottom: 90,
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

  void _showWakeSettingsDialog() {
    final wakeCtrl = TextEditingController(text: wakePetName);
    int selectedColor = themeColorIndex;
    bool tempEmojiStyle = useEmojiStyle;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Wake Word & Mode Wajah"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Warna Mata Neon:", style: TextStyle(fontSize: 13)),
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
                  title: const Text("Gunakan Emoji Bawaan XiaoZhi",
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                      "Aktif: 21 Emoji XiaoZhi • Nonaktif: Wajah Robot Neon",
                      style: TextStyle(fontSize: 11)),
                  value: tempEmojiStyle,
                  onChanged: (v) => setDialogState(() => tempEmojiStyle = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: wakeCtrl,
                  decoration: const InputDecoration(
                    labelText: "Nama Panggilan (Sesuai Web XiaoZhi)",
                    helperText:
                        "Panggil dengan: \"Hai / Halo / Hello [Nama ini]\"",
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Lokasi GPS: $locationName\nMAC Address: $deviceMac",
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Batal"),
            ),
            ElevatedButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                final newWake = wakeCtrl.text.trim().isEmpty
                    ? "kimmi"
                    : wakeCtrl.text.trim();
                await prefs.setString('wakePetName', newWake);
                await prefs.setInt('themeColorIndex', selectedColor);
                await prefs.setBool('useEmojiStyle', tempEmojiStyle);
                setState(() {
                  wakePetName = newWake;
                  themeColorIndex = selectedColor;
                  useEmojiStyle = tempEmojiStyle;
                  if (sessionState == SessionState.standbyWakeWord) {
                    statusSubtitle =
                        "Standby • Panggil \"Hai $wakePetName\" untuk bicara";
                  }
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

class RobotFacePainter extends CustomPainter {
  final XiaoZhiEmotion emotion;
  final double blinkValue;
  final bool isTalking;
  final double talkValue;
  final Offset gazeOffset;
  final Color faceColor;

  RobotFacePainter({
    required this.emotion,
    required this.blinkValue,
    required this.isTalking,
    required this.talkValue,
    required this.gazeOffset,
    required this.faceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = faceColor.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);

    double eyeWidth = 68;
    double eyeHeight = 82 * (1.0 - blinkValue * 0.92);

    final gazeShift = Offset(gazeOffset.dx * 18, gazeOffset.dy * 14);
    final leftCenter =
        Offset(size.width * 0.26, size.height * 0.42) + gazeShift;
    final rightCenter =
        Offset(size.width * 0.74, size.height * 0.42) + gazeShift;

    _drawCustomEye(
        canvas, leftCenter, eyeWidth, eyeHeight, paint, glowPaint, true);
    _drawCustomEye(
        canvas, rightCenter, eyeWidth, eyeHeight, paint, glowPaint, false);

    // Pipi merona untuk ekspresi ceria / sayang / malu
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
            center: leftCenter.translate(-20, 52), width: 34, height: 16),
        blushPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(20, 52), width: 34, height: 16),
        blushPaint,
      );
    }

    // Air mata untuk crying
    if (emotion == XiaoZhiEmotion.crying) {
      final tearPaint = Paint()..color = Colors.lightBlueAccent;
      canvas.drawOval(
        Rect.fromCenter(
            center: leftCenter.translate(0, 54), width: 12, height: 22),
        tearPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(0, 54), width: 12, height: 22),
        tearPaint,
      );
    }

    // Kacamata jembatan untuk mode Cool
    if (emotion == XiaoZhiEmotion.cool) {
      final bridgePaint = Paint()
        ..color = faceColor
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
          leftCenter.translate(34, -8), rightCenter.translate(-34, -8), bridgePaint);
    }

    // Gambar Mulut Tunggal (Anti-Tumpuk)
    _drawMouth(canvas, size, gazeShift * 0.5);
  }

  void _drawCustomEye(Canvas canvas, Offset center, double w, double h,
      Paint paint, Paint glowPaint, bool isLeft) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;

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
        Rect.fromCenter(center: center.translate(0, 10), width: w, height: 55),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == XiaoZhiEmotion.dizzy) {
      double r = 24;
      canvas.drawLine(
          center.translate(-r, -r), center.translate(r, r), strokePaint);
      canvas.drawLine(
          center.translate(r, -r), center.translate(-r, r), strokePaint);
      return;
    }

    if (emotion == XiaoZhiEmotion.loving) {
      final path = Path();
      double s = 34;
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
      w = 74;
      h = 74 * (1.0 - blinkValue * 0.9);
    } else if (emotion == XiaoZhiEmotion.confused && isLeft) {
      h *= 0.65;
    } else if (emotion == XiaoZhiEmotion.cool) {
      h *= 0.68;
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

    // 1. Jika sedang mengeluarkan suara bicara (isTalking == true),
    // HANYA gambar 1 bentuk mulut kapsul dinamis dari tinggi 8px -> 36px.
    // Tidak pernah berganti ke garis lengkung di tengah kalimat sehingga bebas tumpuk!
    if (isTalking) {
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

    // 2. Jika sedang diam (tidak ada suara keluar), gambar mulut sesuai 21 emosi XiaoZhi:
    switch (emotion) {
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
        // Senyum dengan lidah menjulur
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

  @override
  bool shouldRepaint(covariant RobotFacePainter oldDelegate) => true;
}
