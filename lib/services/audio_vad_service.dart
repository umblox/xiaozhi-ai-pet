import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import '../models/pet_models.dart';

class AudioVadService {
  final AudioRecorder _micRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micStreamSub;
  SimpleOpusEncoder? _opusEncoder;
  SimpleOpusDecoder? _opusDecoder;

  final List<int> _pcmMicBuffer = [];
  final Queue<Uint8List> _preRollOpusBuffer = Queue<Uint8List>();
  int _vadSpeechFrameCount = 0;

  int serverSampleRate = 24000;
  bool isVoiceAudioActive = false;
  Timer? _voiceDecayTimer;
  DateTime lastTtsStopTime = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isMicStreamActive => _micStreamSub != null;

  Future<void> initEngine() async {
    try {
      _opusEncoder = SimpleOpusEncoder(
        sampleRate: 16000,
        channels: 1,
        application: Application.voip,
      );
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: serverSampleRate,
        channels: 1,
      );
      await FlutterPcmSound.setup(
        sampleRate: serverSampleRate,
        channelCount: 1,
      );
      await FlutterPcmSound.setFeedThreshold(960);
    } catch (_) {}
  }

  Future<void> updateServerSampleRate(int newRate) async {
    if (newRate == serverSampleRate) return;
    serverSampleRate = newRate;
    try {
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: serverSampleRate,
        channels: 1,
      );
      await FlutterPcmSound.setup(
        sampleRate: serverSampleRate,
        channelCount: 1,
      );
    } catch (_) {}
  }

  void decodeAndPlayServerOpus(
    Uint8List opusPacket, {
    required VoidCallback onVoiceStateChanged,
  }) {
    if (_opusDecoder == null || opusPacket.isEmpty) return;
    try {
      final Int16List pcm16 = _opusDecoder!.decode(input: opusPacket);
      if (pcm16.isNotEmpty) {
        FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm16.toList()));

        if (!isVoiceAudioActive) {
          isVoiceAudioActive = true;
          onVoiceStateChanged();
        }
        _voiceDecayTimer?.cancel();
        _voiceDecayTimer = Timer(const Duration(milliseconds: 280), () {
          isVoiceAudioActive = false;
          onVoiceStateChanged();
        });
      }
    } catch (_) {}
  }

  void markTtsStopped({required VoidCallback onVoiceStateChanged}) {
    _voiceDecayTimer?.cancel();
    lastTtsStopTime = DateTime.now();
    if (isVoiceAudioActive) {
      isVoiceAudioActive = false;
      onVoiceStateChanged();
    }
  }

  List<Uint8List> drainPreRollBuffer() {
    final list = _preRollOpusBuffer.toList();
    _preRollOpusBuffer.clear();
    return list;
  }

  void clearPreRollBuffer() {
    _preRollOpusBuffer.clear();
  }

  Future<void> ensureContinuousMicStream({
    bool forceRestart = false,
    required SessionState Function() getSessionState,
    required bool Function() isMusicPlaying,
    required VoidCallback onVadTriggered,
    required VoidCallback onVoiceDetectedInListening,
    required void Function(Uint8List opusPacket) onSendOpusPacket,
  }) async {
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
        (Uint8List pcmBytes) {
          _processRawMicPcmChunk(
            pcmBytes,
            getSessionState: getSessionState,
            isMusicPlaying: isMusicPlaying,
            onVadTriggered: onVadTriggered,
            onVoiceDetectedInListening: onVoiceDetectedInListening,
            onSendOpusPacket: onSendOpusPacket,
          );
        },
        onError: (_) => _micStreamSub = null,
        onDone: () => _micStreamSub = null,
      );
    } catch (_) {
      _micStreamSub = null;
    }
  }

  void _processRawMicPcmChunk(
    Uint8List pcmBytes, {
    required SessionState Function() getSessionState,
    required bool Function() isMusicPlaying,
    required VoidCallback onVadTriggered,
    required VoidCallback onVoiceDetectedInListening,
    required void Function(Uint8List opusPacket) onSendOpusPacket,
  }) {
    if (_opusEncoder == null) return;

    final currentSession = getSessionState();
    if (currentSession == SessionState.speakingTts || isVoiceAudioActive) {
      _pcmMicBuffer.clear();
      _vadSpeechFrameCount = 0;
      return;
    }

    if (DateTime.now().difference(lastTtsStopTime).inMilliseconds < 350) {
      return;
    }

    final bd = ByteData.sublistView(pcmBytes);
    for (int i = 0; i <= pcmBytes.length - 2; i += 2) {
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

      if (currentSession == SessionState.standbyVad) {
        _preRollOpusBuffer.addLast(opusPacket);
        while (_preRollOpusBuffer.length > 15) {
          _preRollOpusBuffer.removeFirst();
        }

        final double threshold = isMusicPlaying() ? 780.0 : 480.0;
        if (rms > threshold) {
          _vadSpeechFrameCount++;
          if (_vadSpeechFrameCount >= 2) {
            _vadSpeechFrameCount = 0;
            onVadTriggered();
          }
        } else {
          if (_vadSpeechFrameCount > 0) _vadSpeechFrameCount--;
        }
      } else if (currentSession == SessionState.listeningToUser) {
        if (rms > 420.0) {
          onVoiceDetectedInListening();
        }
        onSendOpusPacket(opusPacket);
      }
    }
  }

  void dispose() {
    _voiceDecayTimer?.cancel();
    _micStreamSub?.cancel();
    _micRecorder.dispose();
  }
}
