import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
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

// 23 Ekspresi Lengkap ala Robot EMO + State Dead
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
  highFive,
  deadDrop,
}

// 4 Mode Musisi Konser YouTube
enum MusicianMode {
  none,
  dj,
  guitar,
  piano,
  vocal,
}

enum SessionState { standbyVad, listeningToUser, speakingTts }

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

  // Pengaturan Visual & Suara
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

  // Status Sesi, Smart Audio VAD, & Pre-Roll Opus Buffer
  SessionState sessionState = SessionState.standbyVad;
  bool isVoiceAudioActive = false;
  Timer? _voiceDecayTimer;
  DateTime _lastTtsStopTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastUserVoiceTime = DateTime.now();
  DateTime _listeningStartedTime = DateTime.now();
  DateTime _emotionLockUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _hasDetectedVoiceInCurrentTurn = false;

  final AudioRecorder _micRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micStreamSub;
  SimpleOpusEncoder? _opusEncoder;
  SimpleOpusDecoder? _opusDecoder;
  final List<int> _pcmMicBuffer = [];
  final Queue<Uint8List> _preRollOpusBuffer = Queue<Uint8List>();
  int _vadSpeechFrameCount = 0;
  int _serverSampleRate = 24000;
  bool _isMusicDucked = false;

  // Kamera MCP Vision (Selfie & Belakang)
  List<CameraDescription> _cameras = [];
  CameraController? _cameraController;
  int _selectedCameraIdx = 0;
  bool showCameraPreview = false;
  bool _isCameraBusy = false;

  // Data GPS Asli, Waktu Lokal & Cuaca
  double? gpsLat;
  double? gpsLon;
  String locationName = "Mencari GPS...";
  String weatherSummary = "Memuat cuaca...";
  double currentTempC = 28.0;
  String weatherCondition = "Cerah";
  String timeString = "";
  String dateString = "";
  String timePhaseName = "Pagi";
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
  MusicianMode currentMusicianMode = MusicianMode.none;
  String currentSongTitle = "";
  String statusSubtitle = "Menghubungkan ke server XiaoZhi...";

  // State Interaksi Fisik
  bool isCrossEyed = false;
  double cheekStretchX = 1.0;
  double tickleShakeOffset = 0.0;
  bool isScreenCracked = false;
  double shootFlashOpacity = 0.0;
  Offset crackOrigin = const Offset(180, 300);
  final List<List<Offset>> crackBranches = [];
  Timer? _reviveTimer;
  Timer? _handResetTimer;
  DateTime _lastTouchSpeechTime = DateTime.fromMillisecondsSinceEpoch(0);

  Offset gazeOffset = Offset.zero;
  int rubCounter = 0;
  int tickleCounter = 0;
  final List<FloatingParticle> particles = [];

  late AnimationController _blinkController;
  late AnimationController _floatController;
  late AnimationController _talkController;
  late AnimationController _handController;
  late AnimationController _beatController;
  Timer? _clockTimer;
  Timer? _idleTimer;
  Timer? _particleTimer;
  Timer? _micWatchdogTimer;
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
      duration: const Duration(milliseconds: 520),
    )..repeat(reverse: true);
    _beatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    )..repeat(reverse: true);

    _updateClock();
    _bootstrapSystem();

    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _idleTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _idleBehavior());
    _particleTimer = Timer.periodic(
        const Duration(milliseconds: 50), (_) => _updateParticles());

    _micWatchdogTimer =
        Timer.periodic(const Duration(milliseconds: 800), (_) {
      _checkMicAndSessionHealth();
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
    await _ensureContinuousMicStream();
  }

  Future<void> _loadIdentityAndSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wakePetName');
    await prefs.remove('syncedPetName');

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
      themeColorIndex = prefs.getInt('themeColorIndex') ?? 1;
      enableRobotSfx = prefs.getBool('enableRobotSfx') ?? true;
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

  bool get _isWsOpen =>
      _ws != null && _ws!.readyState == WebSocket.open && isXiaoZhiConnected;

  // =======================================================================
  // 1. MESIN MIKROFON SENSITIF + VAD + SIKLUS LISTEN START/STOP BERSIH
  // =======================================================================
  Future<void> _ensureContinuousMicStream({bool forceRestart = false}) async {
    if (forceRestart) {
      await _micStreamSub?.cancel();
      _micStreamSub = null;
      try {
        if (await _micRecorder.isRecording()) {
          await _micRecorder.stop();
        }
      } catch (_) {}
    }

    if (_micStreamSub != null) return;

    try {
      _pcmMicBuffer.clear();
      _preRollOpusBuffer.clear();
      final stream = await _micRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );

      _micStreamSub = stream.listen(
        _processRawMicPcmChunk,
        onError: (_) {
          _micStreamSub = null;
        },
        onDone: () {
          _micStreamSub = null;
        },
      );
    } catch (_) {
      _micStreamSub = null;
    }
  }

  void _processRawMicPcmChunk(Uint8List pcmBytes) {
    if (_opusEncoder == null) return;

    // Jangan rekam suara sendiri saat TTS XiaoZhi sedang aktif berbicara
    if (sessionState == SessionState.speakingTts || isVoiceAudioActive) {
      _pcmMicBuffer.clear();
      _vadSpeechFrameCount = 0;
      return;
    }

    // Jeda singkat 350ms usai TTS selesai agar sisa gema speaker tidak memicu mic
    if (DateTime.now().difference(_lastTtsStopTime).inMilliseconds < 350) {
      return;
    }

    final bd = ByteData.sublistView(pcmBytes);
    for (int i = 0; i <= pcmBytes.length - 2; i += 2) {
      // Penguat kepekaan mikrofon (Software Mic Gain 1.85x) agar tidak perlu teriak
      final int rawSample = bd.getInt16(i, Endian.little);
      final int boosted = (rawSample * 1.85).round().clamp(-32767, 32767);
      _pcmMicBuffer.add(boosted);
    }

    while (_pcmMicBuffer.length >= 960) {
      final frameSamples = Int16List.fromList(_pcmMicBuffer.sublist(0, 960));
      _pcmMicBuffer.removeRange(0, 960);

      double sumSq = 0;
      for (int i = 0; i < 960; i++) {
        final double s = frameSamples[i].toDouble();
        sumSq += s * s;
      }
      final double rms = sqrt(sumSq / 960.0);

      Uint8List opusPacket;
      try {
        opusPacket = _opusEncoder!.encode(input: frameSamples);
      } catch (_) {
        continue;
      }

      if (sessionState == SessionState.standbyVad) {
        // Simpan 15 frame terakhir (900ms) di Pre-Roll Buffer agar suku kata pertama utuh
        _preRollOpusBuffer.addLast(opusPacket);
        while (_preRollOpusBuffer.length > 15) {
          _preRollOpusBuffer.removeFirst();
        }

        // Ambang batas sensitif: 480 saat hening, 1050 saat musik YouTube berputar
        final double threshold =
            currentMusicianMode != MusicianMode.none ? 1050.0 : 480.0;

        if (rms > threshold) {
          _vadSpeechFrameCount++;
          if (_vadSpeechFrameCount >= 2) {
            _vadSpeechFrameCount = 0;
            _activateListeningFromVad(isManualTap: false);
          }
        } else {
          if (_vadSpeechFrameCount > 0) _vadSpeechFrameCount--;
        }
      } else if (sessionState == SessionState.listeningToUser) {
        if (rms > 420.0) {
          _lastUserVoiceTime = DateTime.now();
          _hasDetectedVoiceInCurrentTurn = true;
        }
        if (_isWsOpen) {
          try {
            _ws!.add(opusPacket);
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _activateListeningFromVad({bool isManualTap = false}) async {
    if (!_isWsOpen) {
      await _connectXiaoZhiWs();
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!_isWsOpen) return;

    final now = DateTime.now();
    _listeningStartedTime = now;
    _lastUserVoiceTime = now;
    _hasDetectedVoiceInCurrentTurn = !isManualTap;

    // Jika sedang memutar musik YouTube, kecilkan volume YouTube ke 5% (Ducking) seketika
    if (currentMusicianMode != MusicianMode.none && !_isMusicDucked) {
      _isMusicDucked = true;
      try {
        await _deviceChannel.invokeMethod('duckYoutube', {'duck': true});
      } catch (_) {}
    }

    setState(() {
      sessionState = SessionState.listeningToUser;
      isVoiceAudioActive = false;
      if (currentMusicianMode == MusicianMode.none &&
          DateTime.now().isAfter(_emotionLockUntil)) {
        currentEmotion = XiaoZhiEmotion.happy;
      }
      statusSubtitle = currentMusicianMode != MusicianMode.none
          ? "🎧 Mendengarkan perintahmu..."
          : "🎙️ Mendengarkanmu...";
    });

    try {
      _ws!.add(jsonEncode({
        "session_id": sessionId,
        "type": "listen",
        "state": "start",
        "mode": "auto"
      }));

      // Kirim seluruh rekaman Pre-Roll 900ms agar awal kalimat terdengar utuh oleh server
      while (_preRollOpusBuffer.isNotEmpty) {
        _ws!.add(_preRollOpusBuffer.removeFirst());
      }
    } catch (_) {}
  }

  // Kirim perintah/kejadian agar Pet langsung berbicara dengan suara asli XiaoZhi
  Future<void> _requestPetVoiceReaction(
    String promptText, {
    XiaoZhiEmotion? lockEmotion,
    HandGesture? lockGesture,
    int lockSeconds = 4,
  }) async {
    if (lockEmotion != null) {
      _emotionLockUntil = DateTime.now().add(Duration(seconds: lockSeconds));
      _setEmotionWithGestureAndSfx(lockEmotion, gesture: lockGesture);
    }

    if (!_isWsOpen) {
      await _connectXiaoZhiWs();
      await Future.delayed(const Duration(milliseconds: 220));
    }
    if (!_isWsOpen) return;

    try {
      // Jika sebelumnya sedang mode listening, tutup dulu dengan stop agar server tidak bingung
      if (sessionState == SessionState.listeningToUser) {
        _ws!.add(jsonEncode({
          "session_id": sessionId,
          "type": "listen",
          "state": "stop",
        }));
      }

      setState(() {
        sessionState = SessionState.speakingTts;
      });

      // Kirim trigger detect bersih ke server XiaoZhi agar LLM & TTS langsung merespons dengan suara
      _ws!.add(jsonEncode({
        "session_id": sessionId,
        "type": "listen",
        "state": "detect",
        "text": promptText,
      }));
    } catch (_) {}
  }

  Future<void> _restoreMusicVolumeIfNeeded() async {
    if (_isMusicDucked) {
      _isMusicDucked = false;
      try {
        await _deviceChannel.invokeMethod('duckYoutube', {'duck': false});
      } catch (_) {}
    }
  }

  void _checkMicAndSessionHealth() async {
    if (_micStreamSub == null) {
      await _ensureContinuousMicStream();
    }

    if (sessionState == SessionState.listeningToUser) {
      final now = DateTime.now();
      final silentMs = now.difference(_lastUserVoiceTime).inMilliseconds;
      final totalListenMs =
          now.difference(_listeningStartedTime).inMilliseconds;

      // 1. Jika user sudah bicara lalu berhenti bicara selama 1.6 detik, kirim listen:stop
      // agar server XiaoZhi langsung memproses STT & membalas tanpa menggantung!
      if (_hasDetectedVoiceInCurrentTurn &&
          silentMs >= 1600 &&
          totalListenMs >= 1800) {
        _hasDetectedVoiceInCurrentTurn = false;
        if (_isWsOpen) {
          try {
            _ws!.add(jsonEncode({
              "session_id": sessionId,
              "type": "listen",
              "state": "stop"
            }));
          } catch (_) {}
        }
      }

      // 2. Jika sudah menunggu 6.5 detik tanpa ada balasan server, tutup sesi listen dengan bersih
      // dan kembalikan ke Standby VAD agar Pet tidak pernah menjadi tuli!
      if (silentMs >= 6500) {
        if (_isWsOpen) {
          try {
            _ws!.add(jsonEncode({
              "session_id": sessionId,
              "type": "listen",
              "state": "stop"
            }));
          } catch (_) {}
        }
        await _restoreMusicVolumeIfNeeded();
        if (mounted) {
          setState(() {
            sessionState = SessionState.standbyVad;
            statusSubtitle = currentMusicianMode != MusicianMode.none
                ? "🎶 Konser ${currentMusicianMode.name.toUpperCase()}: \"$currentSongTitle\""
                : "Ketuk wajah atau langsung bicara...";
          });
        }
      }
    }
  }

  // =======================================================================
  // 2. PEMUTAR MUSIK YOUTUBE & RESPON SUARA + EKSPRESI SAAT DI-STOP
  // =======================================================================
  MusicianMode _detectMusicianStyle(String text, {String? explicitStyle}) {
    final raw = "${explicitStyle ?? ''} $text".toLowerCase();
    if (raw.contains('gitar') ||
        raw.contains('guitar') ||
        raw.contains('rock') ||
        raw.contains('metal') ||
        raw.contains('band')) {
      return MusicianMode.guitar;
    }
    if (raw.contains('piano') ||
        raw.contains('keyboard') ||
        raw.contains('klasik') ||
        raw.contains('classic') ||
        raw.contains('jazz') ||
        raw.contains('ballad')) {
      return MusicianMode.piano;
    }
    if (raw.contains('vokal') ||
        raw.contains('vocal') ||
        raw.contains('nyanyi') ||
        raw.contains('sing') ||
        raw.contains('karaoke')) {
      return MusicianMode.vocal;
    }
    if (raw.contains('dj') ||
        raw.contains('remix') ||
        raw.contains('jedag') ||
        raw.contains('edm') ||
        raw.contains('bass') ||
        raw.contains('disco')) {
      return MusicianMode.dj;
    }
    const styles = [
      MusicianMode.dj,
      MusicianMode.guitar,
      MusicianMode.piano,
      MusicianMode.vocal
    ];
    return styles[Random().nextInt(styles.length)];
  }

  Future<void> _startYoutubeConcert(String query, {String? styleHint}) async {
    _isMusicDucked = false;
    final chosenMode = _detectMusicianStyle(query, explicitStyle: styleHint);
    setState(() {
      isScreenCracked = false;
      currentMusicianMode = chosenMode;
      currentSongTitle = query.trim();
      sessionState = SessionState.standbyVad;
      currentEmotion = chosenMode == MusicianMode.guitar
          ? XiaoZhiEmotion.cool
          : chosenMode == MusicianMode.dj
              ? XiaoZhiEmotion.confident
              : XiaoZhiEmotion.happy;
      statusSubtitle =
          "🎵 Memutar \"$currentSongTitle\" (${chosenMode.name.toUpperCase()})";
    });

    _spawnParticle("🎵", Colors.cyanAccent);
    _spawnParticle("🎶", Colors.pinkAccent);

    try {
      await _deviceChannel.invokeMethod('playYoutube', {'query': query});
    } catch (_) {}

    // Pastikan mikrofon tetap segar setelah WebView YouTube menyala
    Future.delayed(const Duration(milliseconds: 900), () {
      _ensureContinuousMicStream(forceRestart: true);
    });
  }

  // Menghentikan Musik disertai Animasi Wajah Kecewa + UCAPAN SUARA ASLI XIAOZHI
  Future<void> _stopYoutubeConcert({
    required bool byButton,
    required bool speakReaction,
  }) async {
    final String stoppedSong =
        currentSongTitle.isNotEmpty ? currentSongTitle : "musik";

    try {
      await _deviceChannel.invokeMethod('stopYoutube');
    } catch (_) {}
    _isMusicDucked = false;

    // Segarkan mikrofon karena WebView baru saja ditutup
    await _ensureContinuousMicStream(forceRestart: true);

    if (!mounted) return;

    final bool useSad = Random().nextBool();
    final XiaoZhiEmotion reactionEmo =
        useSad ? XiaoZhiEmotion.sad : XiaoZhiEmotion.confused;
    final HandGesture reactionHand =
        useSad ? HandGesture.handsUp : HandGesture.thinkingChin;

    setState(() {
      currentMusicianMode = MusicianMode.none;
      currentSongTitle = "";
      sessionState = SessionState.standbyVad;
      statusSubtitle = byButton
          ? "🥺 Yah, kok musiknya dimatiin sih..."
          : "🤔 Musik dihentikan...";
    });

    _spawnParticle(useSad ? "🥺" : "❓", Colors.amberAccent);

    if (speakReaction) {
      // Minta XiaoZhi langsung berbicara dengan nada kecewa/manja/heran
      final String prompt = byButton
          ? "Aku barusan matiin lagu $stoppedSong yang lagi kamu mainkan lewat tombol stop. Kamu protes manja dan agak kecewa dong kenapa lagunya dimatiin"
          : "Aku barusan nyuruh kamu berhentiin lagu $stoppedSong. Kamu respon dengan nada manja dan agak kecewa ya kenapa musiknya di-stop";
      await _requestPetVoiceReaction(
        prompt,
        lockEmotion: reactionEmo,
        lockGesture: reactionHand,
        lockSeconds: 6,
      );
    } else {
      _emotionLockUntil = DateTime.now().add(const Duration(seconds: 5));
      _setEmotionWithGestureAndSfx(reactionEmo, gesture: reactionHand);
    }
  }

  void _cycleMusicianStyle() {
    if (currentMusicianMode == MusicianMode.none) return;
    const modes = [
      MusicianMode.dj,
      MusicianMode.guitar,
      MusicianMode.piano,
      MusicianMode.vocal
    ];
    final nextIdx = (modes.indexOf(currentMusicianMode) + 1) % modes.length;
    setState(() {
      currentMusicianMode = modes[nextIdx];
      statusSubtitle =
          "🎶 Konser ${currentMusicianMode.name.toUpperCase()}: \"$currentSongTitle\"";
    });
    _spawnParticle("✨", Colors.amberAccent);
  }

  bool _tryHandleVoiceMusicCommand(String spokenText) {
    final lower = spokenText.toLowerCase().trim();

    // Interupsi Suara untuk Stop / Pause / Matikan Musik
    if (currentMusicianMode != MusicianMode.none &&
        (lower.contains('stop') ||
            lower.contains('pause') ||
            lower.contains('jeda') ||
            lower.contains('matikan') ||
            lower.contains('matiin') ||
            lower.contains('berhenti') ||
            lower.contains('cukup') ||
            lower.contains('udah dulu') ||
            lower.contains('diam'))) {
      // Saat diinterupsi lewat suara, server XiaoZhi sudah menerima STT ini dan akan langsung menjawab dengan suara!
      _stopYoutubeConcert(byButton: false, speakReaction: false);
      return true;
    }

    // Perintah ganti gaya alat musik saat lagu sedang jalan
    if (currentMusicianMode != MusicianMode.none &&
        (lower.contains('ganti gaya') ||
            lower.contains('jadi dj') ||
            lower.contains('main gitar') ||
            lower.contains('main piano') ||
            lower.contains('jadi vokalis'))) {
      _restoreMusicVolumeIfNeeded();
      setState(() {
        currentMusicianMode = _detectMusicianStyle(lower);
        sessionState = SessionState.standbyVad;
      });
      return true;
    }

    // Deteksi perintah putar lagu YouTube
    final reg = RegExp(
        r'(?:putar|putarkan|mainkan|nyanyikan|stel|setel)\s+(?:lagu|musik|youtube|dj|gitar|piano)?\s*(.+)',
        caseSensitive: false);
    final match = reg.firstMatch(lower);
    if (match != null) {
      String songQuery = match.group(1)?.trim() ?? "";
      songQuery = songQuery
          .replaceAll(RegExp(r'\b(di youtube|dari youtube|dong|ya)\b'), '')
          .trim();
      if (songQuery.length >= 2) {
        _startYoutubeConcert(songQuery, styleHint: lower);
        return true;
      }
    }
    return false;
  }

  // =======================================================================
  // 3. SYNTHESIZER EFEK SUARA ROBOT EMO (PROCEDURAL PCM16 SFX)
  // =======================================================================
  void _playRobotSfx(String sfxType) {
    if (!enableRobotSfx || isVoiceAudioActive) return;
    if (sessionState == SessionState.speakingTts) return;

    try {
      final int sr = _serverSampleRate;
      final List<int> samples = [];

      void addTone(double fStart, double fEnd, int durationMs,
          {double volume = 0.26, bool square = false, bool noise = false}) {
        final int count = (sr * durationMs) ~/ 1000;
        double phase = 0.0;
        final rand = Random();
        for (int i = 0; i < count; i++) {
          final double progress = i / count;
          final double freq = fStart + (fEnd - fStart) * progress;
          final double env = sin(progress * pi);
          phase += (2 * pi * freq) / sr;
          double val = sin(phase);
          if (square) val = val >= 0 ? 0.8 : -0.8;
          if (noise) val = (val * 0.4) + ((rand.nextDouble() * 2 - 1) * 0.6);
          samples.add((val * env * volume * 32767).toInt().clamp(-32760, 32760));
        }
      }

      switch (sfxType) {
        case 'shoot_and_die':
          addTone(1500, 180, 140, volume: 0.42, noise: true);
          addTone(2400, 900, 90, volume: 0.32, noise: true);
          addTone(680, 140, 480, volume: 0.32, square: true);
          break;
        case 'revive':
          addTone(320, 580, 110);
          addTone(580, 880, 130);
          addTone(880, 1320, 180);
          break;
        case 'boop':
          addTone(450, 980, 90);
          addTone(980, 620, 70);
          break;
        case 'high_five':
          addTone(1200, 400, 65, volume: 0.38, noise: true);
          addTone(700, 1350, 120);
          break;
        case 'happy':
        case 'laughing':
        case 'funny':
          addTone(520, 780, 80);
          addTone(680, 1050, 85);
          addTone(850, 1280, 100);
          break;
        case 'loving':
        case 'kissy':
          addTone(600, 950, 140);
          addTone(950, 1400, 200);
          break;
        case 'angry':
          addTone(220, 150, 160, square: true, volume: 0.30);
          addTone(190, 120, 220, square: true, volume: 0.30);
          break;
        case 'sad':
        case 'crying':
        case 'confused':
          addTone(620, 420, 220);
          addTone(410, 260, 300);
          break;
        case 'surprised':
        case 'shocked':
          addTone(400, 1450, 160);
          break;
        case 'sleepy':
          addTone(480, 240, 360, volume: 0.22);
          break;
        case 'dizzy':
          addTone(400, 800, 90);
          addTone(800, 350, 90);
          addTone(350, 750, 90);
          break;
        default:
          addTone(660, 880, 80, volume: 0.18);
          break;
      }

      if (samples.isNotEmpty) {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
      }
    } catch (_) {}
  }

  // =======================================================================
  // 4. MODE BERMAIN: SHOOT & DIE + RETAK LAYAR + UCAPAN SUARA DRAMATIS
  // =======================================================================
  void _triggerShootAndDie({Offset? tapPosition, bool askAiToSpeak = true}) {
    _reviveTimer?.cancel();
    _handResetTimer?.cancel();

    final rand = Random();
    final center = tapPosition ?? const Offset(180, 260);
    crackOrigin = center;
    crackBranches.clear();

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

    _emotionLockUntil = DateTime.now().add(const Duration(seconds: 6));
    _playRobotSfx('shoot_and_die');
    _spawnParticle("💥", Colors.orangeAccent);

    setState(() {
      isScreenCracked = true;
      shootFlashOpacity = 0.85;
      currentEmotion = XiaoZhiEmotion.shocked;
      currentHandGesture = HandGesture.handsUp;
      statusSubtitle = "💥 DOR!! Aduh... aku tertembak!!";
    });

    if (askAiToSpeak) {
      _requestPetVoiceReaction(
        "Dor! Aku barusan nembak kamu dalam permainan tembak-tembakan, kamu akting dramatis kaget ketembak lalu pura-pura mati dengan manja dong",
        lockEmotion: XiaoZhiEmotion.dead,
        lockGesture: HandGesture.deadDrop,
        lockSeconds: 6,
      );
    }

    Future.delayed(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => shootFlashOpacity = 0.0);
    });

    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      _spawnParticle("👻", Colors.white70);
      setState(() {
        currentEmotion = XiaoZhiEmotion.dead;
        currentHandGesture = HandGesture.deadDrop;
        statusSubtitle = "💀 X_X ... Pura-pura mati... (Ketuk untuk bangunkan)";
      });
    });

    _reviveTimer = Timer(const Duration(milliseconds: 6500), () {
      if (mounted && currentEmotion == XiaoZhiEmotion.dead) {
        _reviveFromDead();
      }
    });
  }

  void _reviveFromDead() {
    _reviveTimer?.cancel();
    _emotionLockUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _playRobotSfx('revive');
    _spawnParticle("✨", Colors.greenAccent);
    setState(() {
      isScreenCracked = false;
      crackBranches.clear();
      currentEmotion = XiaoZhiEmotion.happy;
      currentHandGesture = HandGesture.peace;
      statusSubtitle = "Ketuk wajah atau langsung bicara...";
    });
    _scheduleHandReset();
  }

  void _setEmotionWithGestureAndSfx(XiaoZhiEmotion emo, {HandGesture? gesture}) {
    if (currentEmotion == XiaoZhiEmotion.dead && emo != XiaoZhiEmotion.dead) {
      if (DateTime.now().isBefore(_emotionLockUntil)) return;
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
  // 5. KAMERA VISION (DEFAULT SELFIE & BISA PINDAH DEPAN/BELAKANG)
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
  // 6. LOKASI GPS ASLI HP, FASE WAKTU INTERNAL & CUACA
  // =======================================================================
  String _computeIndonesianTimePhase(DateTime now) {
    final int totalMinutes = now.hour * 60 + now.minute;
    if (totalMinutes >= 180 && totalMinutes <= 330) {
      return "Waktu Subuh / Dini Hari";
    } else if (totalMinutes > 330 && totalMinutes < 660) {
      return "Waktu Pagi";
    } else if (totalMinutes >= 660 && totalMinutes < 900) {
      return "Waktu Siang";
    } else if (totalMinutes >= 900 && totalMinutes <= 1080) {
      return "Waktu Sore";
    } else {
      return "Waktu Malam";
    }
  }

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
  // 7. PROTOKOL OTA & WEBSOCKET XIAOZHI
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
              "Timezone": "Asia/Jakarta",
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
                "compile_time": "Oct 24 2026",
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
          "Timezone": "Asia/Jakarta",
        },
      ).timeout(const Duration(seconds: 8));

      _ws = socket;
      if (mounted) {
        setState(() {
          isXiaoZhiConnected = true;
          sessionState = SessionState.standbyVad;
          statusSubtitle = "Ketuk wajah atau langsung bicara...";
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
          if (_isShootCommand(text)) {
            _triggerShootAndDie(askAiToSpeak: false);
            return;
          }

          if (_tryHandleVoiceMusicCommand(text)) {
            return;
          }

          setState(() {
            statusSubtitle = "\"$text\"";
          });
          if (DateTime.now().isAfter(_emotionLockUntil)) {
            _setEmotionWithGestureAndSfx(XiaoZhiEmotion.thinking);
          }
        }
      } else if (type == 'llm') {
        final emo = data['emotion']?.toString() ?? "neutral";
        if (mounted && DateTime.now().isAfter(_emotionLockUntil)) {
          _setEmotionWithGestureAndSfx(_mapXiaoZhiEmotion(emo));
        }
      } else if (type == 'tts') {
        final state = data['state'];
        final text = data['text']?.toString() ?? "";

        if (state == 'start') {
          if (mounted) {
            setState(() => sessionState = SessionState.speakingTts);
          }
        } else if (state == 'sentence_start' && text.isNotEmpty) {
          if (mounted) {
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
          _lastTtsStopTime = DateTime.now();
          _restoreMusicVolumeIfNeeded();

          if (mounted) {
            setState(() {
              isVoiceAudioActive = false;
              sessionState = SessionState.standbyVad;
            });
          }

          // Jika tidak sedang konser YouTube dan tidak sedang mati, buka pendengaran giliran berikutnya
          Future.delayed(const Duration(milliseconds: 420), () {
            if (mounted &&
                _isWsOpen &&
                currentEmotion != XiaoZhiEmotion.dead &&
                currentMusicianMode == MusicianMode.none) {
              _activateListeningFromVad(isManualTap: true);
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
  // 8. PROTOKOL MCP LENGKAP
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
        "serverInfo": {
          "name": "XiaoZhi-EMO-Android-Pet",
          "version": "5.2.0",
          "localTime": "$timeString WIB ($timePhaseName)",
          "localDate": dateString,
          "location": locationName
        }
      });
    } else if (method == 'tools/list') {
      final String fullTimeContext =
          "WAKTU LOKAL PENGGUNA SAAT INI: Pukul $timeString WIB ($timePhaseName), Hari/Tanggal: $dateString, Lokasi GPS: $locationName, Cuaca: $weatherSummary.";

      _sendMcpReply(id, {
        "tools": [
          {
            "name": "self.get_device_status",
            "description":
                "Provides real-time device status including local time, GPS location, and weather. [$fullTimeContext]",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.time.get_local_time",
            "description":
                "Get the user's exact local time and Indonesian time phase. Current: $fullTimeContext",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.location.get_current_location",
            "description":
                "Get the user's exact hardware GPS coordinates, subdistrict/city address ($locationName), and local weather ($weatherSummary).",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.music.play_youtube",
            "description":
                "Play any song, music, or audio from YouTube while the pet performs an animated concert as a DJ, Guitarist, Pianist, or Vocalist.",
            "inputSchema": {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "Song title, artist name, or music search query."
                },
                "style": {
                  "type": "string",
                  "enum": ["dj", "guitar", "piano", "vocal"],
                  "description":
                      "Performance style: 'dj' (turntable & headphones), 'guitar' (electric guitar), 'piano' (keyboard), or 'vocal' (stage mic)."
                }
              },
              "required": ["query"]
            }
          },
          {
            "name": "self.music.stop_youtube",
            "description":
                "Stop or pause the currently playing YouTube music concert when the user asks to stop, pause, or turn off the music.",
            "inputSchema": {"type": "object", "properties": {}}
          },
          {
            "name": "self.pet.play_action",
            "description":
                "Trigger expressive robot pet animations, hand gestures, or play games like shoot_and_die, high_five, wave, peace, thumbs_up, angry_fists, or revive.",
            "inputSchema": {
              "type": "object",
              "properties": {
                "action": {
                  "type": "string",
                  "enum": [
                    "shoot_and_die",
                    "high_five",
                    "wave",
                    "peace",
                    "thumbs_up",
                    "angry_fists",
                    "revive"
                  ],
                  "description": "The interactive action or gesture to perform."
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

      if (toolName == 'self.music.play_youtube') {
        final query = args['query']?.toString() ?? "Lofi hip hop beats";
        final style = args['style']?.toString();
        await _startYoutubeConcert(query, styleHint: style);
        _sendMcpReply(id, {
          "content": [
            {
              "type": "text",
              "text":
                  '{"success": true, "playing": "$query", "musician_mode": "${currentMusicianMode.name}"}'
            }
          ],
          "isError": false
        });
      } else if (toolName == 'self.music.stop_youtube') {
        await _stopYoutubeConcert(byButton: false, speakReaction: false);
        _sendMcpReply(id, {
          "content": [
            {
              "type": "text",
              "text":
                  '{"success": true, "status": "stopped", "instruction": "Express a cute, slightly disappointed or curious reaction about why the user stopped your music concert"}'
            }
          ],
          "isError": false
        });
      } else if (toolName == 'self.get_device_status' ||
          toolName == 'self.location.get_current_location' ||
          toolName == 'self.time.get_local_time') {
        await _fetchHardwareGpsAndWeather();
        int vol = 80;
        try {
          vol = (await _deviceChannel.invokeMethod('getVolume')) as int? ?? 80;
        } catch (_) {}

        final statusJson = jsonEncode({
          "local_time": {
            "clock_24h": "$timeString WIB",
            "time_of_day_phase": timePhaseName,
            "date": dateString,
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
          "audio_speaker": {"volume": vol},
          "music_concert": {
            "playing": currentMusicianMode != MusicianMode.none,
            "mode": currentMusicianMode.name,
            "song": currentSongTitle,
          },
          "camera": {
            "active_lens": _currentLensName,
            "preview_visible": showCameraPreview
          },
        });

        _sendMcpReply(id, {
          "content": [
            {"type": "text", "text": statusJson}
          ],
          "isError": false
        });
      } else if (toolName == 'self.pet.play_action') {
        final action = args['action']?.toString() ?? "wave";

        if (action == 'shoot_and_die') {
          _triggerShootAndDie(askAiToSpeak: false);
        } else if (action == 'revive') {
          _reviveFromDead();
        } else if (action == 'high_five') {
          _playRobotSfx('high_five');
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.happy,
              gesture: HandGesture.highFive);
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
    if (!_isWsOpen) return;
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

  bool _isShootCommand(String text) {
    final lower = text.toLowerCase();
    return lower.contains('dor') ||
        lower.contains('tembak') ||
        lower.contains('bang') ||
        lower.contains('pew') ||
        lower.contains('shoot');
  }

  Future<void> _returnToStandbyMode() async {
    _voiceDecayTimer?.cancel();
    await _restoreMusicVolumeIfNeeded();
    if (_isWsOpen) {
      try {
        _ws!.add(jsonEncode({
          "session_id": sessionId,
          "type": "listen",
          "state": "stop"
        }));
      } catch (_) {}
    }
    setState(() {
      sessionState = SessionState.standbyVad;
      isVoiceAudioActive = false;
      currentEmotion = XiaoZhiEmotion.neutral;
      currentHandGesture = HandGesture.none;
      statusSubtitle = currentMusicianMode != MusicianMode.none
          ? "🎶 Konser ${currentMusicianMode.name.toUpperCase()}: \"$currentSongTitle\""
          : "Ketuk wajah atau langsung bicara...";
    });
  }

  XiaoZhiEmotion _mapXiaoZhiEmotion(String emo) {
    final clean = emo.toLowerCase().trim();
    for (final val in XiaoZhiEmotion.values) {
      if (val.name == clean) return val;
    }
    return XiaoZhiEmotion.neutral;
  }

  // =======================================================================
  // 9. INTERAKSI SENTUHAN FISIK LENGKAP (DENGAN UCAPAN SUARA XIAOZHI)
  // =======================================================================
  void _initShakeDetector() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      double gForce =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      if (gForce > 22.0) {
        final now = DateTime.now();
        if (now.difference(_lastShakeTime).inSeconds > 4) {
          _lastShakeTime = now;
          _spawnParticle("💫", Colors.yellowAccent);
          _requestPetVoiceReaction(
            "Aku barusan goyang-goyangin badan kamu sampai pusing, kamu ngeluh pusing dengan nada manja dong",
            lockEmotion: XiaoZhiEmotion.dizzy,
            lockGesture: HandGesture.handsUp,
            lockSeconds: 5,
          );
        }
      }
    });
  }

  void _onFaceTapDown(TapDownDetails details, Size faceAreaSize) {
    if (currentEmotion == XiaoZhiEmotion.dead) {
      _reviveFromDead();
      return;
    }

    final local = details.localPosition;
    final centerX = faceAreaSize.width / 2;
    final centerY = faceAreaSize.height / 2;

    final leftEyeCenter = Offset(centerX - 72, centerY - 22);
    final rightEyeCenter = Offset(centerX + 72, centerY - 22);
    final noseCenter = Offset(centerX, centerY - 10);

    // 1. Colok Mata Kiri / Kanan -> Marah + Ucapkan Protes Manja
    if ((local - leftEyeCenter).distance < 42 ||
        (local - rightEyeCenter).distance < 42) {
      _spawnParticle("💢", Colors.redAccent);
      setState(() => statusSubtitle = "😠 Aduh! Jangan colok mataku dong!");
      _requestPetVoiceReaction(
        "Aduh, aku barusan iseng nyolok mata kamu, kamu protes ngambek dan manja dong karena matamu perih",
        lockEmotion: XiaoZhiEmotion.angry,
        lockGesture: HandGesture.angryFists,
        lockSeconds: 5,
      );
      return;
    }

    // 2. Pencet Hidung (Nose Boop) -> Mata Juling + Ucapkan Gemas
    if ((local - noseCenter).distance < 32) {
      _playRobotSfx('boop');
      _spawnParticle("😜", Colors.amberAccent);
      setState(() {
        isCrossEyed = true;
        currentEmotion = XiaoZhiEmotion.silly;
        statusSubtitle = "😜 Boop! Hidungku dipencet jadi juling nih!";
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => isCrossEyed = false);
      });
      _requestPetVoiceReaction(
        "Aku barusan mencet hidung kamu sampai mata kamu juling, kamu ketawa manja dan gemes dong",
        lockEmotion: XiaoZhiEmotion.silly,
        lockGesture: HandGesture.peace,
        lockSeconds: 4,
      );
      return;
    }

    // Jika sedang memutar konser musik YouTube:
    // - Ketuk bagian bawah (instrumen) untuk ganti alat musik
    // - Ketuk bagian tengah wajah untuk mengecilkan musik & bicara perintah
    if (currentMusicianMode != MusicianMode.none) {
      if (local.dy > centerY + 45) {
        _cycleMusicianStyle();
      } else {
        _activateListeningFromVad(isManualTap: true);
      }
      return;
    }

    // Ketuk wajah biasa: Membuka/menutup saluran pendengaran mikrofon
    if (sessionState == SessionState.listeningToUser) {
      _returnToStandbyMode();
    } else {
      _spawnParticle("✨", Colors.cyanAccent);
      _activateListeningFromVad(isManualTap: true);
    }
  }

  void _onFaceLongPress() {
    if (currentEmotion == XiaoZhiEmotion.dead) return;
    _playRobotSfx('sleepy');
    _spawnParticle("💤", Colors.cyanAccent);
    setState(() {
      statusSubtitle = "😴 Hoaaam... ngantuk sekali... Zzz...";
    });
    _requestPetVoiceReaction(
      "Kamu lagi ngantuk banget nih, menguap manja dan bilang mau bobo sebentar dong",
      lockEmotion: XiaoZhiEmotion.sleepy,
      lockGesture: HandGesture.none,
      lockSeconds: 5,
    );
  }

  void _onFacePanUpdate(DragUpdateDetails details, Size faceAreaSize) {
    if (currentEmotion == XiaoZhiEmotion.dead) return;
    final local = details.localPosition;
    final dx = ((local.dx / faceAreaSize.width) - 0.5) * 2.0;
    final dy = ((local.dy / faceAreaSize.height) - 0.5) * 2.0;

    setState(() {
      gazeOffset = Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
    });

    // Elus Dahi / Kepala Atas
    if (dy < -0.18) {
      rubCounter++;
      if (rubCounter % 14 == 0) {
        _spawnParticle("❤️", Colors.pinkAccent);
        setState(
            () => statusSubtitle = "😍 Nyaman banget kepalaku dielus-elus...");
        if (DateTime.now().difference(_lastTouchSpeechTime).inSeconds > 6) {
          _lastTouchSpeechTime = DateTime.now();
          _requestPetVoiceReaction(
            "Aku lagi elus-elus kepala kamu dengan lembut nih, kamu mendesah nyaman dan respon manja dong",
            lockEmotion: XiaoZhiEmotion.loving,
            lockGesture: HandGesture.coverCheeks,
            lockSeconds: 5,
          );
        } else {
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.loving,
              gesture: HandGesture.coverCheeks);
        }
      }
      return;
    }

    // Gelitik Dagu / Perut Bawah
    if (dy > 0.22 && details.delta.dx.abs() > 2.5) {
      tickleCounter++;
      setState(() {
        tickleShakeOffset = (tickleCounter.isEven ? 9.0 : -9.0);
      });
      if (tickleCounter % 12 == 0) {
        _spawnParticle("😆", Colors.amberAccent);
        setState(
            () => statusSubtitle = "😆 Hahaha geli tau! Jangan digelitikin!");
        if (DateTime.now().difference(_lastTouchSpeechTime).inSeconds > 6) {
          _lastTouchSpeechTime = DateTime.now();
          _requestPetVoiceReaction(
            "Aku lagi gelitikin dagu dan perut kamu nih, kamu ketawa kegelian dan minta ampun dengan manja dong",
            lockEmotion: XiaoZhiEmotion.laughing,
            lockGesture: HandGesture.peace,
            lockSeconds: 5,
          );
        } else {
          _setEmotionWithGestureAndSfx(XiaoZhiEmotion.laughing,
              gesture: HandGesture.peace);
        }
      }
      return;
    }

    // Tarik Pipi Kiri / Kanan
    if (dx.abs() > 0.42 && dy.abs() < 0.25) {
      setState(() {
        cheekStretchX = (1.0 + (dx.abs() - 0.42) * 0.45).clamp(1.0, 1.28);
        currentEmotion = XiaoZhiEmotion.embarrassed;
        statusSubtitle = "😳 Uwaaa pipiku ditarik-tarik jadi melar!";
      });
    }
  }

  void _onFacePanEnd(DragEndDetails details) {
    final bool wasStretchingCheek = cheekStretchX > 1.08;
    rubCounter = 0;
    tickleCounter = 0;

    final velocity = details.velocity.pixelsPerSecond.distance;
    if (velocity > 1100 && !wasStretchingCheek) {
      if (currentMusicianMode != MusicianMode.none) {
        _cycleMusicianStyle();
      } else {
        _playRobotSfx('high_five');
        _spawnParticle("🙌", Colors.cyanAccent);
        setState(() => statusSubtitle = "🙌 TOS!! High-Five!");
        _requestPetVoiceReaction(
          "Kita barusan tos high-five bareng, kamu bersorak senang dan manja dong",
          lockEmotion: XiaoZhiEmotion.happy,
          lockGesture: HandGesture.highFive,
          lockSeconds: 4,
        );
      }
    } else if (wasStretchingCheek &&
        DateTime.now().difference(_lastTouchSpeechTime).inSeconds > 5) {
      _lastTouchSpeechTime = DateTime.now();
      _requestPetVoiceReaction(
        "Aku barusan cubit dan tarik pipi kamu sampai melar, kamu merajuk manja dong",
        lockEmotion: XiaoZhiEmotion.embarrassed,
        lockGesture: HandGesture.coverCheeks,
        lockSeconds: 4,
      );
    }

    setState(() {
      cheekStretchX = 1.0;
      tickleShakeOffset = 0.0;
    });

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => gazeOffset = Offset.zero);
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
      timePhaseName = _computeIndonesianTimePhase(now);
      timeString =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
      dateString =
          "${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]} ${now.year}";
    });
  }

  void _idleBehavior() {
    if (!mounted || currentEmotion == XiaoZhiEmotion.dead) return;
    _blinkController.forward().then((_) => _blinkController.reverse());

    if (currentMusicianMode != MusicianMode.none) {
      _spawnParticle(Random().nextBool() ? "🎵" : "🎶",
          themeColors[Random().nextInt(themeColors.length)]);
    } else if (currentEmotion == XiaoZhiEmotion.sleepy) {
      _spawnParticle("Zzz", Colors.cyanAccent);
    }

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
            90 + rand.nextDouble() * 140,
            30 + rand.nextDouble() * 60,
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

  @override
  void dispose() {
    _blinkController.dispose();
    _floatController.dispose();
    _talkController.dispose();
    _handController.dispose();
    _beatController.dispose();
    _clockTimer?.cancel();
    _idleTimer?.cancel();
    _particleTimer?.cancel();
    _micWatchdogTimer?.cancel();
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

    final String topStatusLabel = !isXiaoZhiConnected
        ? "OFFLINE"
        : currentMusicianMode != MusicianMode.none
            ? "KONSER ${currentMusicianMode.name.toUpperCase()}"
            : sessionState == SessionState.listeningToUser
                ? "MENDENGARKAN"
                : sessionState == SessionState.speakingTts
                    ? "BERBICARA"
                    : "ONLINE";

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // HUD Bar Atas (Bersih Tanpa Teks "Standby Subuh")
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
                              color: !isXiaoZhiConnected
                                  ? Colors.redAccent
                                  : sessionState == SessionState.listeningToUser
                                      ? Colors.cyanAccent
                                      : Colors.greenAccent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: !isXiaoZhiConnected
                                      ? Colors.redAccent
                                      : Colors.greenAccent,
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
                                  topStatusLabel,
                                  style: TextStyle(
                                    fontSize: 12,
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
                          if (currentMusicianMode != MusicianMode.none)
                            IconButton(
                              icon: const Icon(Icons.music_off,
                                  color: Colors.amberAccent, size: 22),
                              tooltip: "Hentikan Musik YouTube",
                              onPressed: () => _stopYoutubeConcert(
                                  byButton: true, speakReaction: true),
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

                // Area Wajah EMO + Sentuhan Fisik + Panggung Musisi
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _onFaceTapDown(d, size),
                        onLongPress: _onFaceLongPress,
                        onDoubleTapDown: (d) => _triggerShootAndDie(
                            tapPosition: d.localPosition, askAiToSpeak: true),
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
                                _beatController,
                              ]),
                              builder: (context, child) {
                                final double activeTalk = isVoiceAudioActive
                                    ? _talkController.value
                                    : 0.0;
                                final double beatVal =
                                    currentMusicianMode != MusicianMode.none
                                        ? _beatController.value
                                        : 0.0;

                                final double grooveY = currentMusicianMode !=
                                        MusicianMode.none
                                    ? (beatVal - 0.5) * 22
                                    : (_floatController.value - 0.5) * 14;
                                final double grooveX =
                                    currentMusicianMode == MusicianMode.piano
                                        ? sin(beatVal * pi * 2) * 14
                                        : tickleShakeOffset;

                                return Transform.translate(
                                  offset: Offset(
                                    gazeOffset.dx * 12 + grooveX,
                                    grooveY + gazeOffset.dy * 8,
                                  ),
                                  child: Transform.scale(
                                    scaleX: cheekStretchX,
                                    scaleY: 1.0 - ((cheekStretchX - 1.0) * 0.25),
                                    child: CustomPaint(
                                      size: const Size(360, 310),
                                      painter: EmoRobotFaceAndHandsPainter(
                                        emotion: currentEmotion,
                                        handGesture: currentHandGesture,
                                        musicianMode: currentMusicianMode,
                                        blinkValue: _blinkController.value,
                                        isTalking: isVoiceAudioActive ||
                                            currentMusicianMode ==
                                                MusicianMode.vocal,
                                        talkValue: currentMusicianMode ==
                                                MusicianMode.vocal
                                            ? beatVal
                                            : activeTalk,
                                        handAnimValue: _handController.value,
                                        beatValue: beatVal,
                                        isCrossEyed: isCrossEyed,
                                        gazeOffset: gazeOffset,
                                        faceColor: baseColor,
                                      ),
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

                // Indikator Status & Subtitle Percakapan XiaoZhi
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
                            : currentMusicianMode != MusicianMode.none
                                ? Colors.amberAccent
                                : isVoiceAudioActive
                                    ? Colors.cyanAccent
                                    : Colors.white24,
                        width: sessionState == SessionState.standbyVad &&
                                currentMusicianMode == MusicianMode.none
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

            // Overlay Retak Layar Kaca
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
                bottom: 95,
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
                    "Bunyi chirp, beep, & efek suara saat sentuhan fisik",
                    style: TextStyle(fontSize: 11)),
                value: tempSfx,
                onChanged: (v) => setDialogState(() => tempSfx = v),
              ),
              const Divider(),
              Text(
                "Lokasi GPS: $locationName\nMAC Address: $deviceMac",
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
// PAINTER UTAMA: WAJAH EMO + TANGAN/JARI + PANGGUNG MUSISI (DJ/GITAR/PIANO/VOKAL)
// =========================================================================
class EmoRobotFaceAndHandsPainter extends CustomPainter {
  final XiaoZhiEmotion emotion;
  final HandGesture handGesture;
  final MusicianMode musicianMode;
  final double blinkValue;
  final bool isTalking;
  final double talkValue;
  final double handAnimValue;
  final double beatValue;
  final bool isCrossEyed;
  final Offset gazeOffset;
  final Color faceColor;

  EmoRobotFaceAndHandsPainter({
    required this.emotion,
    required this.handGesture,
    required this.musicianMode,
    required this.blinkValue,
    required this.isTalking,
    required this.talkValue,
    required this.handAnimValue,
    required this.beatValue,
    required this.isCrossEyed,
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

    double eyeWidth = 64;
    double eyeHeight = 76 * (1.0 - blinkValue * 0.92);

    final gazeShift = Offset(gazeOffset.dx * 16, gazeOffset.dy * 12);
    final Offset leftCross = isCrossEyed ? const Offset(22, 6) : Offset.zero;
    final Offset rightCross = isCrossEyed ? const Offset(-22, 6) : Offset.zero;

    final leftCenter =
        Offset(size.width * 0.30, size.height * 0.38) + gazeShift + leftCross;
    final rightCenter =
        Offset(size.width * 0.70, size.height * 0.38) + gazeShift + rightCross;

    if (musicianMode == MusicianMode.vocal) {
      final spotPath = Path()
        ..moveTo(size.width * 0.35, 0)
        ..lineTo(size.width * 0.65, 0)
        ..lineTo(size.width * 0.92, size.height)
        ..lineTo(size.width * 0.08, size.height)
        ..close();
      canvas.drawPath(
        spotPath,
        Paint()..color = faceColor.withOpacity(0.08 + beatValue * 0.06),
      );
    }

    if (musicianMode == MusicianMode.dj) {
      _drawDjHeadphones(canvas, size, paint, glowPaint);
    }

    if (emotion == XiaoZhiEmotion.dead) {
      final haloCenter = Offset(size.width * 0.5, size.height * 0.09);
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
          Rect.fromCenter(center: haloCenter, width: 110, height: 24),
          haloGlow);
      canvas.drawOval(
          Rect.fromCenter(center: haloCenter, width: 110, height: 24),
          haloStroke);
    }

    _drawEyebrows(canvas, leftCenter, rightCenter, eyeWidth);
    _drawCustomEye(
        canvas, leftCenter, eyeWidth, eyeHeight, paint, glowPaint, true);
    _drawCustomEye(
        canvas, rightCenter, eyeWidth, eyeHeight, paint, glowPaint, false);

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
            center: leftCenter.translate(-18, 48), width: 34, height: 16),
        blushPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(18, 48), width: 34, height: 16),
        blushPaint,
      );
    }

    if (emotion == XiaoZhiEmotion.crying) {
      final tearPaint = Paint()..color = Colors.lightBlueAccent;
      final double tearOffset = handAnimValue * 10;
      canvas.drawOval(
        Rect.fromCenter(
            center: leftCenter.translate(-6, 50 + tearOffset),
            width: 12,
            height: 22),
        tearPaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
            center: rightCenter.translate(6, 50 + tearOffset),
            width: 12,
            height: 22),
        tearPaint,
      );
    }

    if (emotion == XiaoZhiEmotion.cool ||
        musicianMode == MusicianMode.dj ||
        musicianMode == MusicianMode.guitar) {
      final bridgePaint = Paint()
        ..color = faceColor
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke;
      canvas.drawLine(leftCenter.translate(30, -8),
          rightCenter.translate(-30, -8), bridgePaint);
    }

    _drawMouth(canvas, size, gazeShift * 0.5);

    if (musicianMode != MusicianMode.none) {
      _drawMusicianStageAndHands(canvas, size, paint, glowPaint);
    } else {
      _drawExpressiveHands(canvas, size, paint, glowPaint);
    }
  }

  void _drawDjHeadphones(
      Canvas canvas, Size size, Paint fillPaint, Paint glowPaint) {
    final bandPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    final arcRect = Rect.fromCenter(
      center: Offset(size.width * 0.5, size.height * 0.36),
      width: size.width * 0.72,
      height: size.height * 0.55,
    );
    canvas.drawArc(arcRect, pi * 1.05, pi * 0.9, false, glowPaint);
    canvas.drawArc(arcRect, pi * 1.05, pi * 0.9, false, bandPaint);

    final double cupPulse = 4.0 * beatValue;
    final leftCup = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(size.width * 0.12, size.height * 0.38),
          width: 26 + cupPulse,
          height: 64 + cupPulse),
      const Radius.circular(14),
    );
    final rightCup = RRect.fromRectAndRadius(
      Rect.fromCenter(
          center: Offset(size.width * 0.88, size.height * 0.38),
          width: 26 + cupPulse,
          height: 64 + cupPulse),
      const Radius.circular(14),
    );
    canvas.drawRRect(leftCup, glowPaint);
    canvas.drawRRect(leftCup, fillPaint);
    canvas.drawRRect(rightCup, glowPaint);
    canvas.drawRRect(rightCup, fillPaint);
  }

  void _drawMusicianStageAndHands(
      Canvas canvas, Size size, Paint fillPaint, Paint glowPaint) {
    final strokePaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;

    switch (musicianMode) {
      case MusicianMode.dj:
        final deckRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(size.width * 0.5, size.height * 0.88),
              width: size.width * 0.84,
              height: 58),
          const Radius.circular(16),
        );
        canvas.drawRRect(
            deckRect, Paint()..color = Colors.white.withOpacity(0.08));
        canvas.drawRRect(deckRect, strokePaint);

        for (int i = 0; i < 7; i++) {
          final double barH =
              10.0 + ((sin((beatValue + i * 0.3) * pi * 2) + 1) * 14);
          final double bx = size.width * 0.38 + (i * 14.0);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                  center: Offset(bx, size.height * 0.88),
                  width: 8,
                  height: barH),
              const Radius.circular(4),
            ),
            Paint()
              ..color = i.isEven ? Colors.cyanAccent : Colors.pinkAccent,
          );
        }

        final leftDisc = Offset(size.width * 0.24, size.height * 0.88);
        final rightDisc = Offset(size.width * 0.76, size.height * 0.88);
        canvas.drawCircle(leftDisc, 24, strokePaint);
        canvas.drawCircle(leftDisc, 8, fillPaint);
        canvas.drawCircle(rightDisc, 24, strokePaint);
        canvas.drawCircle(rightDisc, 8, fillPaint);

        _drawPalmWithFingers(
          canvas,
          Offset(size.width * 0.14, size.height * 0.44),
          fillPaint,
          glowPaint,
          fingerAngles: [0.2, 0.5],
          fingerLengths: [18, 18],
        );
        final double scratchShift = (handAnimValue - 0.5) * 26;
        _drawPalmWithFingers(
          canvas,
          Offset(size.width * 0.76 + scratchShift, size.height * 0.82),
          fillPaint,
          glowPaint,
          fingerAngles: [2.8, 3.1, 3.4],
          fingerLengths: [20, 22, 20],
        );
        break;

      case MusicianMode.guitar:
        final bodyCenter = Offset(size.width * 0.38, size.height * 0.84);
        final neckEnd = Offset(size.width * 0.88, size.height * 0.64);

        final neckPaint = Paint()
          ..color = faceColor
          ..strokeWidth = 16
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(bodyCenter, neckEnd, glowPaint);
        canvas.drawLine(bodyCenter, neckEnd, neckPaint);

        final guitarBody = RRect.fromRectAndRadius(
          Rect.fromCenter(center: bodyCenter, width: 96, height: 52),
          const Radius.circular(24),
        );
        canvas.drawRRect(guitarBody, glowPaint);
        canvas.drawRRect(guitarBody, fillPaint);
        canvas.drawCircle(
            bodyCenter, 14, Paint()..color = Colors.black.withOpacity(0.7));

        final double strumY = (beatValue - 0.5) * 28;
        _drawPalmWithFingers(
          canvas,
          Offset(bodyCenter.dx - 10, bodyCenter.dy - 12 + strumY),
          fillPaint,
          glowPaint,
          fingerAngles: [2.6, 3.0, 3.3],
          fingerLengths: [20, 22, 18],
        );

        final double chordSlide = (handAnimValue - 0.5) * 24;
        _drawPalmWithFingers(
          canvas,
          Offset(size.width * 0.72 + chordSlide, size.height * 0.70),
          fillPaint,
          glowPaint,
          fingerAngles: [-0.3, 0.0, 0.3],
          fingerLengths: [20, 22, 20],
        );
        break;

      case MusicianMode.piano:
        final double pianoTop = size.height * 0.82;
        final double pianoWidth = size.width * 0.84;
        final double startX = size.width * 0.08;
        final int keyCount = 10;
        final double keyW = pianoWidth / keyCount;

        for (int i = 0; i < keyCount; i++) {
          final bool isPressed =
              ((beatValue * keyCount).floor() % keyCount) == i ||
                  (((1.0 - handAnimValue) * keyCount).floor() % keyCount) == i;
          final keyRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(
                startX + i * keyW + 2, pianoTop, keyW - 4, isPressed ? 42 : 48),
            const Radius.circular(6),
          );
          canvas.drawRRect(
            keyRect,
            Paint()
              ..color =
                  isPressed ? faceColor : Colors.white.withOpacity(0.85),
          );
        }

        final double leftHandX =
            size.width * 0.28 + sin(handAnimValue * pi * 2) * 38;
        final double rightHandX =
            size.width * 0.72 + cos(beatValue * pi * 2) * 38;
        _drawPalmWithFingers(
          canvas,
          Offset(leftHandX, pianoTop - 10 + (beatValue * 8)),
          fillPaint,
          glowPaint,
          fingerAngles: [2.7, 3.0, 3.3, 3.6],
          fingerLengths: [20, 24, 24, 18],
        );
        _drawPalmWithFingers(
          canvas,
          Offset(rightHandX, pianoTop - 10 + ((1 - beatValue) * 8)),
          fillPaint,
          glowPaint,
          fingerAngles: [2.7, 3.0, 3.3, 3.6],
          fingerLengths: [20, 24, 24, 18],
        );
        break;

      case MusicianMode.vocal:
        final micHead = Offset(size.width * 0.56, size.height * 0.78);
        final standBottom = Offset(size.width * 0.62, size.height * 0.98);
        canvas.drawLine(
          micHead,
          standBottom,
          Paint()
            ..color = Colors.white70
            ..strokeWidth = 6
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawOval(
          Rect.fromCenter(center: micHead, width: 28, height: 34),
          glowPaint,
        );
        canvas.drawOval(
          Rect.fromCenter(center: micHead, width: 28, height: 34),
          fillPaint,
        );

        _drawPalmWithFingers(
          canvas,
          micHead.translate(18, 12),
          fillPaint,
          glowPaint,
          fingerAngles: [-1.2, -1.5],
          fingerLengths: [18, 18],
        );
        _drawPalmWithFingers(
          canvas,
          Offset(
              size.width * 0.14, size.height * 0.52 + (beatValue - 0.5) * 24),
          fillPaint,
          glowPaint,
          fingerAngles: [-0.4, -0.1, 0.2, 0.45],
          fingerLengths: [22, 26, 25, 20],
          rotation: (handAnimValue - 0.5) * 0.5,
        );
        break;

      case MusicianMode.none:
        break;
    }
  }

  void _drawEyebrows(
      Canvas canvas, Offset leftEye, Offset rightEye, double eyeW) {
    final browPaint = Paint()
      ..color = faceColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5
      ..strokeCap = StrokeCap.round;

    double leftOuterY = -52;
    double leftInnerY = -52;
    double rightInnerY = -52;
    double rightOuterY = -52;

    switch (emotion) {
      case XiaoZhiEmotion.angry:
        leftOuterY = -60;
        leftInnerY = -38;
        rightInnerY = -38;
        rightOuterY = -60;
        break;
      case XiaoZhiEmotion.confident:
      case XiaoZhiEmotion.cool:
        leftOuterY = -54;
        leftInnerY = -44;
        rightInnerY = -50;
        rightOuterY = -64;
        break;
      case XiaoZhiEmotion.sad:
      case XiaoZhiEmotion.crying:
      case XiaoZhiEmotion.embarrassed:
        leftOuterY = -40;
        leftInnerY = -58;
        rightInnerY = -58;
        rightOuterY = -40;
        break;
      case XiaoZhiEmotion.thinking:
      case XiaoZhiEmotion.confused:
        leftOuterY = -48;
        leftInnerY = -48;
        rightInnerY = -66;
        rightOuterY = -62;
        break;
      case XiaoZhiEmotion.surprised:
      case XiaoZhiEmotion.shocked:
        leftOuterY = -66;
        leftInnerY = -70;
        rightInnerY = -70;
        rightOuterY = -66;
        break;
      case XiaoZhiEmotion.happy:
      case XiaoZhiEmotion.laughing:
      case XiaoZhiEmotion.loving:
      case XiaoZhiEmotion.winking:
        leftOuterY = -56;
        leftInnerY = -60;
        rightInnerY = -60;
        rightOuterY = -56;
        break;
      case XiaoZhiEmotion.sleepy:
      case XiaoZhiEmotion.dead:
        leftOuterY = -42;
        leftInnerY = -46;
        rightInnerY = -46;
        rightOuterY = -42;
        break;
      default:
        leftOuterY = -52;
        leftInnerY = -52;
        rightInnerY = -52;
        rightOuterY = -52;
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
        !isLeft &&
        !isCrossEyed) {
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
        Rect.fromCenter(center: center.translate(0, 10), width: w, height: 50),
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
      w = 70;
      h = 70 * (1.0 - blinkValue * 0.9);
    } else if (emotion == XiaoZhiEmotion.confused && isLeft) {
      h *= 0.62;
    } else if (emotion == XiaoZhiEmotion.cool ||
        musicianMode == MusicianMode.dj ||
        musicianMode == MusicianMode.guitar) {
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
    final mouthCenter = Offset(size.width * 0.5, size.height * 0.66) + shift;
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

  void _drawExpressiveHands(
      Canvas canvas, Size size, Paint fillPaint, Paint glowPaint) {
    if (handGesture == HandGesture.none) return;

    final double bounce = (handAnimValue - 0.5) * 16;

    switch (handGesture) {
      case HandGesture.highFive:
        final palm = Offset(size.width * 0.5, size.height * 0.56);
        _drawPalmWithFingers(
          canvas,
          palm,
          fillPaint,
          glowPaint,
          fingerAngles: [-0.65, -0.32, 0.0, 0.32, 0.65],
          fingerLengths: [28, 36, 40, 36, 28],
          palmScale: 1.45,
        );
        break;

      case HandGesture.wave:
        final palm = Offset(size.width * 0.88, size.height * 0.48 + bounce);
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
        final palm =
            Offset(size.width * 0.88, size.height * 0.50 + bounce * 0.5);
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
        final palm =
            Offset(size.width * 0.86, size.height * 0.52 + bounce * 0.4);
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
        final palm = Offset(
            size.width * 0.62, size.height * 0.80 + (handAnimValue * 5));
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
        final shake = sin(handAnimValue * pi * 4) * 6;
        final leftFist = Offset(size.width * 0.12 + shake, size.height * 0.56);
        final rightFist = Offset(size.width * 0.88 - shake, size.height * 0.56);
        _drawPalmWithFingers(canvas, leftFist, fillPaint, glowPaint,
            fingerAngles: [], fingerLengths: []);
        _drawPalmWithFingers(canvas, rightFist, fillPaint, glowPaint,
            fingerAngles: [], fingerLengths: []);
        break;

      case HandGesture.coverCheeks:
        final leftPalm =
            Offset(size.width * 0.15, size.height * 0.54 + bounce * 0.3);
        final rightPalm =
            Offset(size.width * 0.85, size.height * 0.54 + bounce * 0.3);
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
        final leftUp =
            Offset(size.width * 0.12, size.height * 0.22 + bounce * 0.6);
        final rightUp =
            Offset(size.width * 0.88, size.height * 0.22 + bounce * 0.6);
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
        final leftDead = Offset(size.width * 0.16, size.height * 0.78);
        final rightDead = Offset(size.width * 0.84, size.height * 0.78);
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
    double palmScale = 1.0,
  }) {
    canvas.save();
    canvas.translate(palmCenter.dx, palmCenter.dy);
    canvas.rotate(rotation);
    canvas.scale(palmScale);

    final palmRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 36, height: 32),
      const Radius.circular(14),
    );
    canvas.drawRRect(palmRect, glowPaint);
    canvas.drawRRect(palmRect, fillPaint);

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

    canvas.drawCircle(origin, 10, glowPaint);
    canvas.drawCircle(origin, 6, Paint()..color = Colors.white);

    canvas.drawCircle(origin, 28, crackPaint);
    canvas.drawCircle(origin, 58, crackPaint..strokeWidth = 1.4);

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
