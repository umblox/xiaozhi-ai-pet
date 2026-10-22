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

List<CameraDescription> globalCameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  try {
    initOpus(await opus_flutter.load());
  } catch (_) {}

  try {
    globalCameras = await availableCameras();
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

enum PetEmotion {
  normal,
  happy,
  love,
  excited,
  thinking,
  surprised,
  sad,
  crying,
  angry,
  sleepy,
  wink,
  dizzy
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
  // Konfigurasi Minimalis (Hanya Wake Word & Warna Mata)
  String wakePetName = "xiaozhi";
  int themeColorIndex = 0;

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
  final stt.SpeechToText _wakeStt = stt.SpeechToText();
  final AudioRecorder _micRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micStreamSub;
  SimpleOpusEncoder? _opusEncoder;
  SimpleOpusDecoder? _opusDecoder;
  final List<int> _pcmMicBuffer = [];
  int _serverSampleRate = 24000;

  // Kamera MCP Vision
  CameraController? _cameraController;
  int _selectedCameraIdx = 0;
  bool showCameraPreview = false;

  // Data Waktu & Cuaca HUD
  String weatherSummary = "Memuat cuaca...";
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

  PetEmotion currentEmotion = PetEmotion.normal;
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
      duration: const Duration(milliseconds: 150),
    );
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _talkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    )..repeat(reverse: true);

    _updateClock();
    _bootstrapSystem();

    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _idleTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _idleBehavior());
    _particleTimer = Timer.periodic(
        const Duration(milliseconds: 50), (_) => _updateParticles());

    // Penjaga agar Wake Word selalu aktif saat mode Standby
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
    ].request();

    await _loadIdentityAndSettings();
    await _initOpusAndPcmEngine();
    await _initCameraController();
    _fetchWeatherHud();
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
      wakePetName = prefs.getString('wakePetName') ?? "xiaozhi";
      themeColorIndex = prefs.getInt('themeColorIndex') ?? 0;
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

  Future<void> _initCameraController() async {
    if (globalCameras.isEmpty) return;
    try {
      _cameraController?.dispose();
      _cameraController = CameraController(
        globalCameras[_selectedCameraIdx],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _switchCameraLens() async {
    if (globalCameras.length < 2) return;
    _selectedCameraIdx = (_selectedCameraIdx + 1) % globalCameras.length;
    await _initCameraController();
  }

  // =======================================================================
  // 1. PROTOKOL OTA & WEBSOCKET RESMI XIAOZHI (MURNI TANPA AI LOKAL)
  // =======================================================================
  Future<void> _syncXiaoZhiOtaAndConnect({bool showDialogIfPaired = false}) async {
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
                "rssi": -40,
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
            currentEmotion = PetEmotion.excited;
            statusSubtitle =
                "Belum di-pairing! Masukkan kode $code di web xiaozhi.me";
          });
          _showPairingDialog(code, data['activation']['message']?.toString());
          return;
        }

        if (showDialogIfPaired && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text("Perangkat sudah terdaftar di akun XiaoZhi!")),
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

      // Paket Hello + Dukungan MCP (Kamera Vision)
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
            currentEmotion = PetEmotion.thinking;
          });
        }
      } else if (type == 'llm') {
        final emo = data['emotion']?.toString() ?? "normal";
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
            setState(() => statusSubtitle = text);
          }
        } else if (state == 'stop') {
          // Begitu XiaoZhi selesai bicara, otomatis dengarkan balasan user (Auto-Conversation)
          Future.delayed(const Duration(milliseconds: 350), () {
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

  // Decode Paket Audio Opus Biner dari Server XiaoZhi -> Speaker HP
  void _handleServerOpusBinary(Uint8List opusPacket) {
    if (_opusDecoder == null || opusPacket.isEmpty) return;
    try {
      final Int16List pcm16 = _opusDecoder!.decode(input: opusPacket);
      if (pcm16.isNotEmpty) {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm16.toList()));
      }
    } catch (_) {}
  }

  // =======================================================================
  // 2. PROTOKOL MCP VISION (KAMERA XIAOZHI)
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
        "serverInfo": {"name": "XiaoZhi-Android-Pet", "version": "2.0.0"}
      });
    } else if (method == 'tools/list') {
      _sendMcpReply(id, {
        "tools": [
          {
            "name": "self.camera.take_photo",
            "description":
                "Take a photo using the Android camera to see what is in front of the pet robot.",
            "inputSchema": {
              "type": "object",
              "properties": {
                "question": {
                  "type": "string",
                  "description": "Question about what to look for in the photo"
                }
              },
              "required": ["question"]
            }
          }
        ]
      });
    } else if (method == 'tools/call') {
      final toolName = payload['params']?['name']?.toString() ?? "";
      final args = payload['params']?['arguments'] ?? {};

      if (toolName == 'self.camera.take_photo') {
        final question =
            args['question']?.toString() ?? "Please describe this image";
        final visionResult = await _captureAndUploadVision(question);
        _sendMcpReply(id, {
          "content": [
            {"type": "text", "text": visionResult}
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
    try {
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        await _initCameraController();
      }
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        return '{"success": false, "message": "Camera not available"}';
      }

      if (mounted) {
        setState(() {
          currentEmotion = PetEmotion.surprised;
          statusSubtitle = "📸 Mengambil foto kamera untuk dilihat XiaoZhi...";
        });
      }

      final XFile photo = await _cameraController!.takePicture();
      final bytes = await photo.readAsBytes();

      final targetUrl = visionExplainUrl.isNotEmpty
          ? visionExplainUrl
          : "https://api.tenclass.net/xiaozhi/vision/explain";

      final req = http.MultipartRequest('POST', Uri.parse(targetUrl));
      req.headers['Device-Id'] = deviceMac;
      req.headers['Client-Id'] = clientId;
      if (visionExplainToken.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $visionExplainToken';
      }
      req.fields['question'] = question;
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: 'capture.jpg'),
      );

      final streamedRes =
          await req.send().timeout(const Duration(seconds: 15));
      final body = await streamedRes.stream.bytesToString();
      return body;
    } catch (e) {
      return '{"success": false, "message": "$e"}';
    }
  }

  // =======================================================================
  // 3. WAKE WORD HANDS-FREE ("HAI / HALO / HELLO [NAMA PET]") & STREAM OPUS
  // =======================================================================
  Future<void> _startWakeWordListener() async {
    if (sessionState != SessionState.standbyWakeWord) return;
    try {
      bool ready = await _wakeStt.initialize(onError: (_) {}, onStatus: (_) {});
      if (!ready) return;

      await _wakeStt.listen(
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        cancelOnError: false,
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

    // Kirim sinyal Wake Word terdeteksi ke server XiaoZhi
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
      currentEmotion = PetEmotion.happy;
      statusSubtitle = "Mendengarkanmu... (Ketuk wajah untuk kembali Standby)";
    });

    // Beritahu XiaoZhi bahwa aliran mikrofon Opus dimulai (mode auto-stop)
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

      // Konversi byte PCM16 Little-Endian ke Int16 sampel
      final bd = ByteData.sublistView(pcmBytes);
      for (int i = 0; i <= pcmBytes.length - 2; i += 2) {
        _pcmMicBuffer.add(bd.getInt16(i, Endian.little));
      }

      // Frame 60ms pada 16kHz = 960 sampel per paket Opus
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
    if (isXiaoZhiConnected && _ws != null) {
      _ws!.add(jsonEncode({
        "session_id": sessionId,
        "type": "abort",
        "reason": "wake_word_detected"
      }));
    }
    setState(() {
      sessionState = SessionState.standbyWakeWord;
      currentEmotion = PetEmotion.normal;
      statusSubtitle = "Standby • Panggil \"Hai $wakePetName\" untuk bicara";
    });
    _startWakeWordListener();
  }

  PetEmotion _mapXiaoZhiEmotion(String emo) {
    switch (emo.toLowerCase()) {
      case 'happy':
      case 'laughing':
      case 'funny':
        return PetEmotion.happy;
      case 'loving':
      case 'kissy':
        return PetEmotion.love;
      case 'confident':
      case 'cool':
      case 'delicious':
        return PetEmotion.excited;
      case 'winking':
      case 'silly':
        return PetEmotion.wink;
      case 'sad':
        return PetEmotion.sad;
      case 'crying':
        return PetEmotion.crying;
      case 'angry':
        return PetEmotion.angry;
      case 'surprised':
      case 'shocked':
        return PetEmotion.surprised;
      case 'thinking':
      case 'confused':
        return PetEmotion.thinking;
      case 'sleepy':
      case 'relaxed':
        return PetEmotion.sleepy;
      default:
        return PetEmotion.normal;
    }
  }

  // =======================================================================
  // 4. CUACA HUD, SENSOR GOYANG, & INTERAKSI WAJAH
  // =======================================================================
  Future<void> _fetchWeatherHud() async {
    try {
      double lat = -6.2088;
      double lon = 106.8456;
      String city = "Indonesia";

      final geoRes = await http
          .get(Uri.parse("http://ip-api.com/json"))
          .timeout(const Duration(seconds: 5));
      if (geoRes.statusCode == 200) {
        final g = jsonDecode(geoRes.body);
        lat = (g['lat'] as num?)?.toDouble() ?? lat;
        lon = (g['lon'] as num?)?.toDouble() ?? lon;
        city = g['city'] ?? city;
      }

      final wRes = await http
          .get(Uri.parse(
              "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current_weather=true"))
          .timeout(const Duration(seconds: 5));
      if (wRes.statusCode == 200) {
        final w = jsonDecode(wRes.body)['current_weather'];
        if (mounted) {
          setState(() => weatherSummary = "${w['temperature']}°C • $city");
        }
      }
    } catch (_) {
      if (mounted) setState(() => weatherSummary = "XiaoZhi Online");
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
          setState(() => currentEmotion = PetEmotion.dizzy);
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

    if ((local - leftEyeCenter).distance < 45 ||
        (local - rightEyeCenter).distance < 45) {
      setState(() => currentEmotion = PetEmotion.angry);
      _spawnParticle("💢", Colors.redAccent);
      return;
    }

    // Jika sedang dalam sesi obrolan aktif, ketuk wajah untuk kembali ke Standby
    if (sessionState != SessionState.standbyWakeWord) {
      _returnToStandbyMode();
    } else {
      // Jika sedang standby, ketuk wajah juga bisa membangunkan XiaoZhi
      _triggerWakeUpToXiaoZhi("Halo $wakePetName");
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
        setState(() => currentEmotion = PetEmotion.love);
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
    _accelSub?.cancel();
    _micStreamSub?.cancel();
    _micRecorder.dispose();
    _cameraController?.dispose();
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = currentEmotion == PetEmotion.angry
        ? Colors.redAccent
        : currentEmotion == PetEmotion.love
            ? Colors.pinkAccent
            : themeColors[themeColorIndex];

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // HUD Bar Atas (Status XiaoZhi, Jam/Cuaca, Kamera Vision, Pairing)
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
                          Column(
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
                            tooltip: "Intip Kamera Vision",
                            onPressed: () {
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
                            tooltip: "Atur Wake Word & Warna",
                            onPressed: _showWakeSettingsDialog,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Area Wajah Robot Ekspresif
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
                                return Transform.translate(
                                  offset: Offset(
                                    gazeOffset.dx * 12,
                                    (_floatController.value - 0.5) * 14 +
                                        gazeOffset.dy * 8,
                                  ),
                                  child: CustomPaint(
                                    size: const Size(320, 220),
                                    painter: RobotFacePainter(
                                      emotion: currentEmotion,
                                      blinkValue: _blinkController.value,
                                      talkValue: sessionState ==
                                              SessionState.speakingTts
                                          ? _talkController.value
                                          : 0.0,
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

                // Indikator Status Hands-Free & Subtitle XiaoZhi (Tanpa Tombol Mic)
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
                            : sessionState == SessionState.speakingTts
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

            // Jendela Kecil Preview Kamera Vision (Jika Diaktifkan)
            if (showCameraPreview &&
                _cameraController != null &&
                _cameraController!.value.isInitialized)
              Positioned(
                right: 16,
                bottom: 90,
                child: GestureDetector(
                  onTap: _switchCameraLens,
                  child: Container(
                    width: 110,
                    height: 150,
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
                          bottom: 4,
                          right: 4,
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

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Wake Word & Tampilan"),
          content: Column(
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
              const SizedBox(height: 18),
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
                "MAC Address: $deviceMac",
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
                final newWake = wakeCtrl.text.trim().isEmpty
                    ? "xiaozhi"
                    : wakeCtrl.text.trim();
                await prefs.setString('wakePetName', newWake);
                await prefs.setInt('themeColorIndex', selectedColor);
                setState(() {
                  wakePetName = newWake;
                  themeColorIndex = selectedColor;
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
  final PetEmotion emotion;
  final double blinkValue;
  final double talkValue;
  final Offset gazeOffset;
  final Color faceColor;

  RobotFacePainter({
    required this.emotion,
    required this.blinkValue,
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

    if (emotion == PetEmotion.love || emotion == PetEmotion.happy) {
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

    _drawMouth(canvas, size, gazeShift * 0.5);
  }

  void _drawCustomEye(Canvas canvas, Offset center, double w, double h,
      Paint paint, Paint glowPaint, bool isLeft) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;

    if (emotion == PetEmotion.wink && !isLeft) {
      canvas.drawArc(
        Rect.fromCenter(center: center, width: w, height: 25),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == PetEmotion.happy) {
      canvas.drawArc(
        Rect.fromCenter(center: center.translate(0, 10), width: w, height: 55),
        pi,
        pi,
        false,
        strokePaint,
      );
      return;
    }

    if (emotion == PetEmotion.dizzy) {
      double r = 24;
      canvas.drawLine(
          center.translate(-r, -r), center.translate(r, r), strokePaint);
      canvas.drawLine(
          center.translate(r, -r), center.translate(-r, r), strokePaint);
      return;
    }

    if (emotion == PetEmotion.love) {
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

    if (emotion == PetEmotion.sleepy) {
      h *= 0.22;
    } else if (emotion == PetEmotion.surprised) {
      w = 72;
      h = 72 * (1.0 - blinkValue * 0.9);
    } else if (emotion == PetEmotion.excited) {
      h *= 1.15;
    }

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      Radius.circular(emotion == PetEmotion.surprised ? 40 : 24),
    );
    canvas.drawRRect(rect, glowPaint);
    canvas.drawRRect(rect, paint);

    final maskPaint = Paint()..color = Colors.black;
    if (emotion == PetEmotion.angry) {
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
    } else if (emotion == PetEmotion.sad || emotion == PetEmotion.crying) {
      final path = Path();
      if (isLeft) {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h * 0.55);
        path.lineTo(center.dx - w, center.dy - 5);
      } else {
        path.moveTo(center.dx - w, center.dy - h);
        path.lineTo(center.dx + w, center.dy - h);
        path.lineTo(center.dx - w, center.dy - 5);
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

    if (talkValue > 0.05) {
      double openH = 14 + (talkValue * 28);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: mouthCenter, width: 48, height: openH),
          const Radius.circular(18),
        ),
        fillPaint,
      );
      return;
    }

    switch (emotion) {
      case PetEmotion.happy:
      case PetEmotion.love:
      case PetEmotion.excited:
      case PetEmotion.wink:
        canvas.drawArc(
          Rect.fromCenter(center: mouthCenter, width: 62, height: 42),
          0,
          pi,
          false,
          strokePaint,
        );
        break;
      case PetEmotion.angry:
      case PetEmotion.sad:
      case PetEmotion.crying:
        canvas.drawArc(
          Rect.fromCenter(
              center: mouthCenter.translate(0, 16), width: 52, height: 32),
          pi,
          pi,
          false,
          strokePaint,
        );
        break;
      case PetEmotion.surprised:
      case PetEmotion.dizzy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 28, height: 32),
          strokePaint,
        );
        break;
      case PetEmotion.thinking:
        canvas.drawLine(
          mouthCenter.translate(-22, 5),
          mouthCenter.translate(20, -6),
          strokePaint,
        );
        break;
      case PetEmotion.sleepy:
        canvas.drawOval(
          Rect.fromCenter(center: mouthCenter, width: 18, height: 18),
          strokePaint,
        );
        break;
      default:
        canvas.drawArc(
          Rect.fromCenter(center: mouthCenter, width: 44, height: 22),
          0,
          pi,
          false,
          strokePaint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant RobotFacePainter oldDelegate) => true;
}
