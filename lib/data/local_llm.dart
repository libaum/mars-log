import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

/// The analysis model on the phone: Gemma 4 E2B through LiteRT-LM
/// (`flutter_gemma`). Open weights, runs offline; nothing leaves the device.
///
/// Gemini Nano was the first choice, but Google's API for it (ML Kit Prompt
/// API) doesn't support the owner's Galaxy S24. This is the "small
/// pre-analysis" — a better model on the laptop is meant to overwrite it
/// later (PLAN_LOCAL_ANALYSIS.md).
class LocalLlm {
  static const modelName = 'gemma-4-e2b';

  /// Ungated on Hugging Face — no account or token needed. ~2.6 GB, CPU+GPU.
  static const _modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

  /// Download progress in percent while the model is being fetched, else
  /// null. Settings shows it.
  final progress = ValueNotifier<int?>(null);

  Future<void>? _installing;
  InferenceModel? _model;

  /// Downloads the model on first use (a no-op once installed) and makes it
  /// the active one. Concurrent callers share one download.
  Future<void> ensureReady() => _installing ??= _install().whenComplete(() {
        _installing = null;
      });

  Future<void> _install() async {
    try {
      await FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      )
          // A foreground service with a notification: a 2.6 GB download
          // outlives Android's limit for background work otherwise.
          .fromNetwork(_modelUrl, foreground: true)
          .withProgress((p) => progress.value = p)
          .install();
    } catch (e) {
      throw LocalLlmException('Das Analysemodell konnte nicht geladen werden: $e');
    } finally {
      progress.value = null;
    }
  }

  /// One prompt in, the model's text out. Each call is a fresh conversation.
  Future<String> generate(
    String prompt, {
    double temperature = 0.4,
    int maxOutputTokens = 512,
  }) async {
    await ensureReady();
    final model = _model ??= await _open();
    final chat = await model.createChat(
      temperature: temperature,
      topK: 40,
      modelType: ModelType.gemma4,
      maxOutputTokens: maxOutputTokens,
    );
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final response = await chat.generateChatResponse();
    return switch (response) {
      TextResponse(:final token) => token.trim(),
      _ => '',
    };
  }

  /// GPU first; some GPUs can't run it (driver, memory) — then the CPU,
  /// slower but always there.
  Future<InferenceModel> _open() async {
    try {
      return await FlutterGemma.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.gpu,
      );
    } catch (_) {
      return FlutterGemma.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.cpu,
      );
    }
  }
}

class LocalLlmException implements Exception {
  final String message;
  LocalLlmException(this.message);
  @override
  String toString() => message;
}
