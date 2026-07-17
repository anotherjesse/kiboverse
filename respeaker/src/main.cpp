#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <Wire.h>
#include <driver/i2s.h>
#include <esp_heap_caps.h>
#include <esp_http_client.h>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <mbedtls/sha256.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "device_config.h"

namespace {

constexpr i2s_port_t kI2SPort = I2S_NUM_0;
constexpr int kI2SBclkPin = 8;
constexpr int kI2SWsPin = 7;
constexpr int kI2SDoutPin = 43;
constexpr int kI2SDinPin = 44;
constexpr int kI2SBitsPerSample = 32;
constexpr int kPcmBitsPerSample = 16;
constexpr int kI2SChannels = 2;
constexpr size_t kI2SFramesPerBlock = 256;
constexpr int kBootButtonPin = 0;
constexpr int kUserButtonPin = 3;  // ReSpeaker USR -> D2 solder jumper.
constexpr int kAskButtonPin = 4;   // ReSpeaker MUTE -> D3 solder jumper.
constexpr uint8_t kXmosAddress = 0x42;
constexpr uint32_t kWiFiTimeoutMs = 18000;
constexpr uint32_t kSpeechReadyTimeoutMs = 60000;
constexpr uint32_t kButtonDebounceMs = 30;
constexpr uint32_t kAskHoldTimeoutMs = 15000;
constexpr uint32_t kMuteTogglePulseMs = 300;
constexpr uint32_t kSpeakerDmaTailMs = 140;
constexpr uint32_t kRecordCueDecayMs = 80;
constexpr size_t kWavHeaderBytes = 44;

Preferences preferences;
String wifi_ssid;
String wifi_password;
String server_url = KIBO_DEFAULT_SERVER;
String project_id = KIBO_DEFAULT_PROJECT;
String conversation_id = KIBO_DEFAULT_CONVERSATION;
String serial_line;
uint8_t speaker_volume_percent = KIBO_DEFAULT_VOLUME_PERCENT;
uint32_t last_wifi_attempt_ms = 0;
bool record_button_was_down = false;
bool ask_button_was_down = false;
bool suppress_timed_out_ask = false;
volatile bool ask_edge_pending = false;
volatile uint32_t ask_edge_generation = 0;
volatile bool suppress_ask_interrupt = false;

enum class AskPhase {
  Idle,
  NeedPost,
  NeedSpeech,
};

enum class CaptureAskRestorePhase {
  Idle,
  WaitingForRelease,
  PulsingLow,
  Verifying,
  Done,
};

struct CaptureAskRestore {
  CaptureAskRestorePhase phase = CaptureAskRestorePhase::Idle;
  uint32_t high_since = 0;
  uint32_t pulse_started = 0;
  uint32_t verify_started = 0;
  uint32_t last_check = 0;
  uint32_t edge_generation = 0;
  bool previous_interrupt_suppression = false;
};

struct PendingAsk {
  AskPhase phase = AskPhase::Idle;
  String turn_id;

  void clear() {
    phase = AskPhase::Idle;
    turn_id = "";
  }
};

PendingAsk pending_ask;

void IRAM_ATTR noteAskButtonEdge() {
  if (!suppress_ask_interrupt) {
    ++ask_edge_generation;
    ask_edge_pending = true;
  }
}

uint32_t currentAskEdgeGeneration() {
  noInterrupts();
  const uint32_t generation = ask_edge_generation;
  interrupts();
  return generation;
}

void clearAskButtonEdge() {
  noInterrupts();
  ask_edge_pending = false;
  interrupts();
}

bool takeAskButtonEdge() {
  noInterrupts();
  const bool pending = ask_edge_pending;
  ask_edge_pending = false;
  interrupts();
  return pending;
}

int32_t i2s_stereo[kI2SFramesPerBlock * kI2SChannels];

struct Capture {
  uint8_t *wav = nullptr;
  size_t samples = 0;
  size_t capacity_samples = 0;
  uint16_t peak = 0;

  size_t wavBytes() const { return kWavHeaderBytes + samples * sizeof(int16_t); }
  uint32_t durationMs() const {
    return static_cast<uint32_t>((samples * 1000ULL) / RESPEAKER_I2S_SAMPLE_RATE);
  }
  uint32_t peakPercent() const {
    return std::min<uint32_t>(100, (static_cast<uint32_t>(peak) * 100U + 16383U) / 32767U);
  }
  int16_t *pcm() { return reinterpret_cast<int16_t *>(wav + kWavHeaderBytes); }
  void reset() {
    samples = 0;
    peak = 0;
    if (wav != nullptr) {
      memset(wav, 0, kWavHeaderBytes);
    }
  }
  void release() {
    if (wav != nullptr) {
      heap_caps_free(wav);
      wav = nullptr;
    }
    samples = 0;
    capacity_samples = 0;
    peak = 0;
  }
};

struct RecordingSession;

enum class PartBufferState : uint8_t {
  Free,
  Capturing,
  Queued,
  Uploading,
  RetainedAfterFailure,
};

struct PartBuffer {
  Capture capture;
  RecordingSession *session = nullptr;
  uint32_t sequence = 0;
  PartBufferState state = PartBufferState::Free;
};

struct RecordingSession {
  String recording_id;
  String api_root;
  PartBuffer buffers[RESPEAKER_RECORD_BUFFER_COUNT];
  portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
  volatile bool failed = false;
  volatile uint32_t pending_jobs = 0;
  volatile uint32_t acknowledged_parts = 0;
  uint32_t part_count = 0;
  uint64_t total_samples = 0;
  uint16_t peak = 0;
};

QueueHandle_t upload_queue = nullptr;
TaskHandle_t upload_task_handle = nullptr;

void putLe16(uint8_t *destination, uint16_t value) {
  destination[0] = static_cast<uint8_t>(value);
  destination[1] = static_cast<uint8_t>(value >> 8);
}

void putLe32(uint8_t *destination, uint32_t value) {
  destination[0] = static_cast<uint8_t>(value);
  destination[1] = static_cast<uint8_t>(value >> 8);
  destination[2] = static_cast<uint8_t>(value >> 16);
  destination[3] = static_cast<uint8_t>(value >> 24);
}

void finalizeWav(Capture &capture) {
  const uint32_t pcm_bytes = static_cast<uint32_t>(capture.samples * sizeof(int16_t));
  uint8_t *header = capture.wav;
  memcpy(header, "RIFF", 4);
  putLe32(header + 4, 36 + pcm_bytes);
  memcpy(header + 8, "WAVEfmt ", 8);
  putLe32(header + 16, 16);
  putLe16(header + 20, 1);
  putLe16(header + 22, 1);
  putLe32(header + 24, RESPEAKER_I2S_SAMPLE_RATE);
  putLe32(header + 28, RESPEAKER_I2S_SAMPLE_RATE * sizeof(int16_t));
  putLe16(header + 32, sizeof(int16_t));
  putLe16(header + 34, kPcmBitsPerSample);
  memcpy(header + 36, "data", 4);
  putLe32(header + 40, pcm_bytes);
}

void sha256Hex(const uint8_t *data, size_t length, char output[65]) {
  uint8_t digest[32];
  mbedtls_sha256_context context;
  mbedtls_sha256_init(&context);
  mbedtls_sha256_starts_ret(&context, 0);
  mbedtls_sha256_update_ret(&context, data, length);
  mbedtls_sha256_finish_ret(&context, digest);
  mbedtls_sha256_free(&context);
  for (size_t index = 0; index < sizeof(digest); ++index) {
    snprintf(output + index * 2, 3, "%02x", digest[index]);
  }
  output[64] = '\0';
}

String cleanServerUrl(String value) {
  value.trim();
  while (value.endsWith("/")) {
    value.remove(value.length() - 1);
  }
  return value;
}

String apiRoot() {
  return server_url + "/v1/projects/" + project_id + "/conversations/" + conversation_id;
}

String makeId(const char *kind) {
  const uint64_t mac = ESP.getEfuseMac();
  char value[80];
  snprintf(value, sizeof(value), "respeaker-%s-%04lx-%08lx-%08lx", kind,
           static_cast<unsigned long>(mac & 0xffff),
           static_cast<unsigned long>(millis()),
           static_cast<unsigned long>(esp_random()));
  return String(value);
}

void loadSettings() {
  preferences.begin("kibo", false);
  wifi_ssid = preferences.getString("wifi_ssid", "");
  wifi_password = preferences.getString("wifi_pass", "");
  server_url = cleanServerUrl(preferences.getString("server", KIBO_DEFAULT_SERVER));
  project_id = preferences.getString("project", KIBO_DEFAULT_PROJECT);
  conversation_id = preferences.getString("conversation", KIBO_DEFAULT_CONVERSATION);
  speaker_volume_percent =
      std::min<uint8_t>(100, preferences.getUChar("volume", KIBO_DEFAULT_VOLUME_PERCENT));
}

bool connectWiFi(bool force = false) {
  if (WiFi.status() == WL_CONNECTED) {
    return true;
  }
  if (wifi_ssid.isEmpty()) {
    Serial.println("Wi-Fi is not provisioned. Use: wifi <ssid> <password>");
    return false;
  }
  const uint32_t now = millis();
  if (!force && now - last_wifi_attempt_ms < 10000) {
    return false;
  }
  last_wifi_attempt_ms = now;

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setHostname("kibo-respeaker");
  WiFi.begin(wifi_ssid.c_str(), wifi_password.c_str());
  Serial.printf("Connecting to Wi-Fi '%s'", wifi_ssid.c_str());
  const uint32_t started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < kWiFiTimeoutMs) {
    Serial.print('.');
    delay(400);
  }
  if (WiFi.status() != WL_CONNECTED) {
    Serial.printf(" failed (status %d)\n", static_cast<int>(WiFi.status()));
    return false;
  }
  Serial.printf(" connected: %s\n", WiFi.localIP().toString().c_str());
  return true;
}

void setupI2S() {
  i2s_config_t config = {
      .mode = static_cast<i2s_mode_t>(I2S_MODE_SLAVE | I2S_MODE_RX | I2S_MODE_TX),
      .sample_rate = RESPEAKER_I2S_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = kI2SFramesPerBlock,
      .use_apll = false,
      .tx_desc_auto_clear = true,
      .fixed_mclk = 0,
      .mclk_multiple = I2S_MCLK_MULTIPLE_DEFAULT,
      .bits_per_chan = I2S_BITS_PER_CHAN_DEFAULT,
  };
  i2s_pin_config_t pins = {
      .mck_io_num = I2S_PIN_NO_CHANGE,
      .bck_io_num = kI2SBclkPin,
      .ws_io_num = kI2SWsPin,
      .data_out_num = kI2SDoutPin,
      .data_in_num = kI2SDinPin,
  };
  esp_err_t result = i2s_driver_install(kI2SPort, &config, 0, nullptr);
  if (result == ESP_OK) {
    result = i2s_set_pin(kI2SPort, &pins);
  }
  if (result != ESP_OK) {
    Serial.printf("I2S setup failed: %s\n", esp_err_to_name(result));
    while (true) {
      delay(1000);
    }
  }
  i2s_zero_dma_buffer(kI2SPort);
  Serial.println("I2S ready: XMOS master, 16 kHz, 32-bit stereo RX/TX");
}

bool xmosRead(uint8_t resource, uint8_t command, uint8_t *value, uint8_t length) {
  if (length == 0 || length > 254) {
    return false;
  }
  Wire.beginTransmission(kXmosAddress);
  Wire.write(resource);
  Wire.write(command);
  Wire.write(static_cast<uint8_t>(length + 1));
  if (Wire.endTransmission() != 0) {
    return false;
  }
  const uint8_t received = Wire.requestFrom(kXmosAddress, static_cast<uint8_t>(length + 1));
  if (received != length + 1 || Wire.available() < length + 1) {
    return false;
  }
  const uint8_t status = Wire.read();
  for (uint8_t index = 0; index < length; ++index) {
    value[index] = Wire.read();
  }
  return status == 0;
}

bool readXmosMuted(bool &muted) {
  uint8_t value = 0;
  if (!xmosRead(0xF1, 0x81, &value, 1)) {
    return false;
  }
  muted = value != 0;
  return true;
}

void pulseAskButtonLine() {
  // MUTE is also wired straight to XMOS. With the D3 jumper fitted, a
  // low/open-drain pulse looks like one more button press and toggles mute
  // back off. Never drive this shared, button-to-ground net push-pull HIGH.
  const bool was_suppressed = suppress_ask_interrupt;
  suppress_ask_interrupt = true;
  digitalWrite(kAskButtonPin, HIGH);
  pinMode(kAskButtonPin, OUTPUT_OPEN_DRAIN);
  digitalWrite(kAskButtonPin, LOW);
  delay(kMuteTogglePulseMs);
  digitalWrite(kAskButtonPin, HIGH);
  pinMode(kAskButtonPin, INPUT_PULLUP);
  suppress_ask_interrupt = was_suppressed;
}

void restoreXmosAfterAskPress() {
  bool muted = false;
  if (!readXmosMuted(muted)) {
    Serial.println("Could not read XMOS mute state; ASK will continue without changing it");
    return;
  }
  if (!muted) {
    Serial.println("XMOS microphone is unmuted");
    return;
  }

  Serial.println("Cancelling the MUTE key's hardware-mute toggle...");
  pulseAskButtonLine();
  const uint32_t started = millis();
  while (millis() - started < 1200) {
    delay(40);
    if (readXmosMuted(muted) && !muted) {
      Serial.println("XMOS microphone restored: unmuted");
      return;
    }
  }
  Serial.println("Warning: XMOS still reports muted; check the MUTE-to-D3 solder bridge");
}

void beginCaptureAskRestorePulse(CaptureAskRestore &restore) {
  // Preserve the physical edge for pollMissedAskPress(). Only suppress the
  // falling edge generated by our own open-drain pulse.
  restore.previous_interrupt_suppression = suppress_ask_interrupt;
  suppress_ask_interrupt = true;
  digitalWrite(kAskButtonPin, HIGH);
  pinMode(kAskButtonPin, OUTPUT_OPEN_DRAIN);
  digitalWrite(kAskButtonPin, LOW);
  restore.pulse_started = millis();
  restore.phase = CaptureAskRestorePhase::PulsingLow;
  Serial.println("Restoring XMOS mute state during capture (nonblocking pulse)...");
}

void releaseCaptureAskRestorePulse(CaptureAskRestore &restore) {
  digitalWrite(kAskButtonPin, HIGH);
  pinMode(kAskButtonPin, INPUT_PULLUP);
  suppress_ask_interrupt = restore.previous_interrupt_suppression;
  restore.verify_started = millis();
  restore.last_check = 0;
  restore.phase = CaptureAskRestorePhase::Verifying;
}

void serviceCaptureAskRestore(CaptureAskRestore &restore) {
  const uint32_t now = millis();
  const uint32_t edge_generation = currentAskEdgeGeneration();
  if (restore.phase == CaptureAskRestorePhase::Idle) {
    if (!ask_edge_pending) {
      return;
    }
    restore.edge_generation = edge_generation;
    restore.phase = CaptureAskRestorePhase::WaitingForRelease;
    Serial.println("ASK tap detected during recording; capture continues while XMOS is restored");
  } else if (restore.phase != CaptureAskRestorePhase::PulsingLow &&
             edge_generation != restore.edge_generation) {
    // Multiple taps still coalesce into one post-recording ASK, but each
    // physical MUTE toggle must be undone or later audio would be muted.
    restore.edge_generation = edge_generation;
    restore.high_since = 0;
    restore.last_check = 0;
    restore.phase = CaptureAskRestorePhase::WaitingForRelease;
    Serial.println("Another ASK tap occurred during recording; restoring XMOS again");
  }

  if (restore.phase == CaptureAskRestorePhase::WaitingForRelease) {
    if (digitalRead(kAskButtonPin) == LOW) {
      restore.high_since = 0;
      return;
    }
    if (restore.high_since == 0) {
      restore.high_since = now;
      return;
    }
    if (now - restore.high_since < kButtonDebounceMs ||
        (restore.last_check != 0 && now - restore.last_check < 40)) {
      return;
    }
    restore.last_check = now;
    bool muted = false;
    if (!readXmosMuted(muted)) {
      return;
    }
    if (!muted) {
      Serial.println("XMOS microphone remained unmuted during capture");
      restore.phase = CaptureAskRestorePhase::Done;
      return;
    }
    beginCaptureAskRestorePulse(restore);
    return;
  }

  if (restore.phase == CaptureAskRestorePhase::PulsingLow) {
    if (now - restore.pulse_started >= kMuteTogglePulseMs) {
      releaseCaptureAskRestorePulse(restore);
    }
    return;
  }

  if (restore.phase == CaptureAskRestorePhase::Verifying) {
    if (restore.last_check != 0 && now - restore.last_check < 40) {
      return;
    }
    restore.last_check = now;
    bool muted = true;
    if (readXmosMuted(muted) && !muted) {
      Serial.println("XMOS microphone restored without stopping capture");
      restore.phase = CaptureAskRestorePhase::Done;
      return;
    }
    if (now - restore.verify_started >= 1200) {
      Serial.println("Warning: XMOS still reports muted after in-capture restore");
      restore.phase = CaptureAskRestorePhase::Done;
    }
  }
}

void finishCaptureAskRestore(CaptureAskRestore &restore) {
  // If a tap arrived at the very end of a recording, keep servicing I2S while
  // completing a pulse. This avoids both RX-DMA starvation and leaving the
  // shared GPIO driven low after the capture function returns.
  const uint32_t started = millis();
  while (millis() - started < kMuteTogglePulseMs + 250) {
    serviceCaptureAskRestore(restore);
    const bool released_wait =
        restore.phase == CaptureAskRestorePhase::WaitingForRelease &&
        digitalRead(kAskButtonPin) == HIGH;
    if (restore.phase == CaptureAskRestorePhase::Idle ||
        restore.phase == CaptureAskRestorePhase::Done ||
        (restore.phase == CaptureAskRestorePhase::WaitingForRelease && !released_wait)) {
      break;
    }
    size_t bytes_read = 0;
    i2s_read(kI2SPort, i2s_stereo, sizeof(i2s_stereo), &bytes_read, pdMS_TO_TICKS(20));
  }
  if (restore.phase == CaptureAskRestorePhase::PulsingLow) {
    Serial.println("Ending an incomplete in-capture mute pulse safely");
    releaseCaptureAskRestorePulse(restore);
  }
}

void printXmosStatus() {
  uint8_t version[3] = {0};
  uint8_t muted = 0;
  const bool version_ok = xmosRead(0xF0, 0xD8, version, sizeof(version));
  const bool mute_ok = xmosRead(0xF1, 0x81, &muted, 1);
  if (version_ok) {
    Serial.printf("XMOS firmware: v%u.%u.%u\n", version[0], version[1], version[2]);
  } else {
    Serial.println("XMOS firmware version: unavailable");
  }
  if (mute_ok) {
    Serial.printf("XMOS mute: %s\n", muted ? "ON" : "off");
  } else {
    Serial.println("XMOS mute status: unavailable");
  }
}

void drainI2SRx() {
  for (int attempt = 0; attempt < 12; ++attempt) {
    size_t bytes_read = 0;
    i2s_read(kI2SPort, i2s_stereo, sizeof(i2s_stereo), &bytes_read, 0);
    if (bytes_read == 0) {
      break;
    }
  }
}

bool allocateCapture(Capture &capture, uint32_t max_seconds) {
  capture.capacity_samples = static_cast<size_t>(max_seconds) * RESPEAKER_I2S_SAMPLE_RATE;
  const size_t bytes = kWavHeaderBytes + capture.capacity_samples * sizeof(int16_t);
  capture.wav = static_cast<uint8_t *>(
      heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (capture.wav == nullptr) {
    Serial.printf("Could not allocate %u capture bytes in PSRAM\n", static_cast<unsigned>(bytes));
    return false;
  }
  memset(capture.wav, 0, kWavHeaderBytes);
  return true;
}

bool captureAudio(Capture &capture, uint32_t fixed_ms) {
  const uint32_t max_seconds = std::max<uint32_t>(1, (fixed_ms + 999) / 1000);
  if (!allocateCapture(capture, max_seconds)) {
    return false;
  }
  drainI2SRx();
  Serial.println("Recording...");
  const uint32_t started = millis();
  uint32_t last_meter = started;

  while (capture.samples < capture.capacity_samples) {
    if (millis() - started >= fixed_ms) {
      break;
    }

    size_t bytes_read = 0;
    const esp_err_t result = i2s_read(kI2SPort, i2s_stereo, sizeof(i2s_stereo),
                                      &bytes_read, pdMS_TO_TICKS(250));
    if (result != ESP_OK) {
      Serial.printf("I2S read failed: %s\n", esp_err_to_name(result));
      capture.release();
      return false;
    }
    const size_t frames = bytes_read / (sizeof(int32_t) * kI2SChannels);
    const size_t remaining = capture.capacity_samples - capture.samples;
    const size_t to_copy = std::min(frames, remaining);
    int16_t *pcm = capture.pcm();
    for (size_t frame = 0; frame < to_copy; ++frame) {
#if RESPEAKER_CAPTURE_CHANNEL == 1
      const int32_t source = i2s_stereo[frame * 2 + 1];
#else
      const int32_t source = i2s_stereo[frame * 2];
#endif
      const int16_t sample = static_cast<int16_t>(source >> (kI2SBitsPerSample - kPcmBitsPerSample));
      pcm[capture.samples++] = sample;
      const uint16_t magnitude = sample == INT16_MIN
                                     ? 32768
                                     : static_cast<uint16_t>(std::abs(static_cast<int>(sample)));
      capture.peak = std::max(capture.peak, magnitude);
    }
    if (millis() - last_meter >= 500) {
      last_meter = millis();
      Serial.printf("  %lu ms, peak %lu%%\n",
                    static_cast<unsigned long>(capture.durationMs()),
                    static_cast<unsigned long>(capture.peakPercent()));
    }
  }

  finalizeWav(capture);
  Serial.printf("Captured %lu ms, %u bytes, peak %lu%%\n",
                static_cast<unsigned long>(capture.durationMs()),
                static_cast<unsigned>(capture.wavBytes()),
                static_cast<unsigned long>(capture.peakPercent()));
  return capture.samples > 0;
}

bool writeI2SFrames(const int32_t *frames, size_t frame_count) {
  // RX and TX share the legacy full-duplex I2S port. If the microphone DMA
  // ring is allowed to stay full during a long reply, the slave TX path can
  // stop making progress even though short writes still work. Discard capture
  // frames while speaking so both DMA directions continue servicing clocks.
  drainI2SRx();
  const size_t wanted = frame_count * kI2SChannels * sizeof(int32_t);
  size_t written = 0;
  const esp_err_t result = i2s_write(kI2SPort, frames, wanted, &written, pdMS_TO_TICKS(2000));
  if (result != ESP_OK || written != wanted) {
    Serial.printf("I2S write failed: %s (%u/%u bytes)\n", esp_err_to_name(result),
                  static_cast<unsigned>(written), static_cast<unsigned>(wanted));
    return false;
  }
  return true;
}

int16_t applySpeakerVolume(int16_t sample) {
  const int32_t scaled =
      static_cast<int32_t>(sample) * static_cast<int32_t>(speaker_volume_percent) / 100;
  return static_cast<int16_t>(scaled);
}

bool playTone(float frequency, uint32_t duration_ms, float amplitude = 0.70f) {
  const size_t total_frames = RESPEAKER_I2S_SAMPLE_RATE * duration_ms / 1000;
  const size_t fade_frames = RESPEAKER_I2S_SAMPLE_RATE * 8 / 1000;
  int32_t output[kI2SFramesPerBlock * 2];
  size_t produced = 0;
  while (produced < total_frames) {
    const size_t frames = std::min(kI2SFramesPerBlock, total_frames - produced);
    for (size_t index = 0; index < frames; ++index) {
      const size_t position = produced + index;
      const size_t remaining = total_frames - position - 1;
      const float fade_in = std::min(1.0f, static_cast<float>(position) / fade_frames);
      const float fade_out = std::min(1.0f, static_cast<float>(remaining) / fade_frames);
      const float envelope = std::min(fade_in, fade_out);
      const float phase = 2.0f * static_cast<float>(M_PI) * frequency *
                          static_cast<float>(position) / RESPEAKER_I2S_SAMPLE_RATE;
      const int16_t source =
          static_cast<int16_t>(sinf(phase) * envelope * amplitude * INT16_MAX);
      const int32_t word = static_cast<int32_t>(applySpeakerVolume(source)) * 65536;
      output[index * 2] = word;
      output[index * 2 + 1] = word;
    }
    if (!writeI2SFrames(output, frames)) {
      return false;
    }
    produced += frames;
  }
  return true;
}

void waitForSpeakerTail(uint32_t extra_decay_ms = 0) {
  // The legacy I2S driver returns once it has copied samples into its eight
  // 256-frame DMA buffers. At 16 kHz that can leave 128 ms yet to play.
  delay(kSpeakerDmaTailMs + extra_decay_ms);
  drainI2SRx();
}

void playChime(uint32_t duration_ms = 180) {
  Serial.printf("Playing %lu ms tone at volume %u%%...\n",
                static_cast<unsigned long>(duration_ms), speaker_volume_percent);
  playTone(660.0f, duration_ms);
  waitForSpeakerTail();
  Serial.println("Chime complete");
}

void playRecordingCue(bool starting) {
  Serial.printf("Recording %s cue (volume %u%%)\n", starting ? "start" : "stop",
                speaker_volume_percent);
  if (starting) {
    playTone(660.0f, 70);
    playTone(880.0f, 90);
    // Wait for queued TX plus room/XMOS decay before captureAudio() drains RX.
    waitForSpeakerTail(kRecordCueDecayMs);
  } else {
    playTone(880.0f, 70);
    playTone(550.0f, 100);
    waitForSpeakerTail();
  }
}

void playRecordingFailureCue() {
  Serial.printf("Recording failure cue (volume %u%%)\n", speaker_volume_percent);
  playTone(330.0f, 110);
  delay(55);
  playTone(245.0f, 130);
  delay(55);
  playTone(165.0f, 180);
  waitForSpeakerTail();
}

struct CollectContext {
  String body;
  size_t limit = 2048;
};

esp_err_t collectHttpEvent(esp_http_client_event_t *event) {
  auto *context = static_cast<CollectContext *>(event->user_data);
  if (context != nullptr && event->event_id == HTTP_EVENT_ON_DATA && event->data_len > 0 &&
      context->body.length() < context->limit) {
    const size_t room = context->limit - context->body.length();
    const size_t count = std::min(room, static_cast<size_t>(event->data_len));
    context->body.concat(static_cast<const char *>(event->data), count);
  }
  return ESP_OK;
}

int performRequest(esp_http_client_method_t method, const String &url,
                   const uint8_t *body, size_t body_length,
                   const char *content_type, CollectContext *response,
                   uint32_t timeout_ms = 30000) {
  esp_http_client_config_t config = {};
  config.url = url.c_str();
  config.event_handler = collectHttpEvent;
  config.user_data = response;
  config.timeout_ms = timeout_ms;
  config.buffer_size = 1024;
  esp_http_client_handle_t client = esp_http_client_init(&config);
  if (client == nullptr) {
    return -1;
  }
  esp_http_client_set_method(client, method);
  if (content_type != nullptr) {
    esp_http_client_set_header(client, "Content-Type", content_type);
  }
  if (body != nullptr || body_length > 0) {
    esp_http_client_set_post_field(client, reinterpret_cast<const char *>(body), body_length);
  }
  const esp_err_t result = esp_http_client_perform(client);
  const int status = result == ESP_OK ? esp_http_client_get_status_code(client) : -1;
  if (result != ESP_OK) {
    Serial.printf("HTTP request failed: %s\n", esp_err_to_name(result));
  }
  esp_http_client_cleanup(client);
  return status;
}

bool checkServer() {
  if (!connectWiFi(true)) {
    return false;
  }
  CollectContext response;
  const int status = performRequest(HTTP_METHOD_GET, server_url + "/v1/projects",
                                    nullptr, 0, nullptr, &response);
  Serial.printf("GET /v1/projects -> %d\n", status);
  if (!response.body.isEmpty()) {
    Serial.println(response.body);
  }
  return status == 200;
}

bool uploadRecordingPart(const PartBuffer &buffer) {
  const Capture &capture = buffer.capture;
  char sha[65];
  sha256Hex(capture.wav, capture.wavBytes(), sha);
  char sample_count[24];
  char peak[12];
  snprintf(sample_count, sizeof(sample_count), "%u", static_cast<unsigned>(capture.samples));
  snprintf(peak, sizeof(peak), "%lu", static_cast<unsigned long>(capture.peakPercent()));
  const String url = buffer.session->api_root + "/recordings/" +
                     buffer.session->recording_id + "/parts/" + String(buffer.sequence);

  CollectContext response;
  esp_http_client_config_t config = {};
  config.url = url.c_str();
  config.event_handler = collectHttpEvent;
  config.user_data = &response;
  config.timeout_ms = 60000;
  config.buffer_size = 1024;
  esp_http_client_handle_t client = esp_http_client_init(&config);
  if (client == nullptr) {
    return false;
  }
  esp_http_client_set_method(client, HTTP_METHOD_PUT);
  esp_http_client_set_header(client, "Content-Type", "audio/wav");
  esp_http_client_set_header(client, "X-Content-SHA256", sha);
  esp_http_client_set_header(client, "X-Sample-Count", sample_count);
  esp_http_client_set_header(client, "X-Peak-Pct", peak);
  esp_http_client_set_post_field(client, reinterpret_cast<const char *>(capture.wav),
                                 capture.wavBytes());
  Serial.printf("Uploading recording %s part %lu (%u samples, %u bytes)...\n",
                buffer.session->recording_id.c_str(),
                static_cast<unsigned long>(buffer.sequence),
                static_cast<unsigned>(capture.samples),
                static_cast<unsigned>(capture.wavBytes()));
  const esp_err_t result = esp_http_client_perform(client);
  const int status = result == ESP_OK ? esp_http_client_get_status_code(client) : -1;
  if (result != ESP_OK) {
    Serial.printf("Recording part upload failed: %s\n", esp_err_to_name(result));
  }
  Serial.printf("PUT recording part %lu -> %d %s\n",
                static_cast<unsigned long>(buffer.sequence), status, response.body.c_str());
  esp_http_client_cleanup(client);
  return status == 200 || status == 201;
}

bool completeRecording(const RecordingSession &session) {
  char json[192];
  snprintf(json, sizeof(json),
           "{\"part_count\":%lu,\"total_samples\":%llu,\"peak_pct\":%lu}",
           static_cast<unsigned long>(session.part_count),
           static_cast<unsigned long long>(session.total_samples),
           static_cast<unsigned long>(
               std::min<uint32_t>(100, (static_cast<uint32_t>(session.peak) * 100U + 16383U) /
                                           32767U)));
  const String url = session.api_root + "/recordings/" + session.recording_id + "/complete";

  for (int attempt = 1; attempt <= 3; ++attempt) {
    CollectContext response;
    int status = -1;
    if (connectWiFi(true)) {
      status = performRequest(HTTP_METHOD_POST, url,
                              reinterpret_cast<const uint8_t *>(json), strlen(json),
                              "application/json", &response, 60000);
    }
    Serial.printf("POST recording complete -> %d %s\n", status, response.body.c_str());
    if (status == 200 || status == 201) {
      return true;
    }
    if (attempt < 3) {
      Serial.printf("Completion attempt %d was not confirmed; retrying recording %s...\n",
                    attempt, session.recording_id.c_str());
      delay(350 * attempt);
    }
  }
  return false;
}

enum class TurnPostResult {
  Accepted,
  NothingPending,
  Retryable,
  PermanentError,
};

TurnPostResult createTurn(const String &turn_id) {
  const String json = String("{\"turn_id\":\"") + turn_id + "\"}";
  CollectContext response;
  const String url = apiRoot() + "/turns";
  const int status = performRequest(HTTP_METHOD_POST, url,
                                    reinterpret_cast<const uint8_t *>(json.c_str()),
                                    json.length(), "application/json", &response, 30000);
  Serial.printf("POST turn -> %d %s\n", status, response.body.c_str());
  if (status == 200 || status == 202) {
    return TurnPostResult::Accepted;
  }
  if (status == 409) {
    return TurnPostResult::NothingPending;
  }
  if (status < 0 || status == 408 || status == 429 || status >= 500) {
    return TurnPostResult::Retryable;
  }
  return TurnPostResult::PermanentError;
}

struct PlaybackContext {
  bool write_ok = true;
  bool have_low_byte = false;
  uint8_t low_byte = 0;
  uint8_t resample_phase = 0;
  int16_t middle_sample = 0;
  int32_t output[kI2SFramesPerBlock * 2];
  size_t output_frames = 0;
  size_t input_samples = 0;
  size_t played_samples = 0;
  int sample_rate = 0;
  String error_body;
};

bool flushPlayback(PlaybackContext &context) {
  if (context.output_frames == 0) {
    return true;
  }
  context.write_ok = writeI2SFrames(context.output, context.output_frames);
  context.output_frames = 0;
  return context.write_ok;
}

void pushPlaybackSample(PlaybackContext &context, int16_t sample) {
  if (!context.write_ok) {
    return;
  }
  const int32_t word = static_cast<int32_t>(applySpeakerVolume(sample)) * 65536;
  context.output[context.output_frames * 2] = word;
  context.output[context.output_frames * 2 + 1] = word;
  ++context.output_frames;
  ++context.played_samples;
  if (context.output_frames == kI2SFramesPerBlock) {
    flushPlayback(context);
  }
}

void resample24kTo16k(PlaybackContext &context, int16_t sample) {
  // Output positions 0 and 1.5 from each group of three input samples.
  if (context.resample_phase == 0) {
    pushPlaybackSample(context, sample);
    context.resample_phase = 1;
  } else if (context.resample_phase == 1) {
    context.middle_sample = sample;
    context.resample_phase = 2;
  } else {
    const int16_t interpolated = static_cast<int16_t>(
        (static_cast<int32_t>(context.middle_sample) + static_cast<int32_t>(sample)) / 2);
    pushPlaybackSample(context, interpolated);
    context.resample_phase = 0;
  }
}

void feedSpeechBytes(PlaybackContext &context, const uint8_t *bytes, size_t length) {
  for (size_t index = 0; index < length; ++index) {
    if (!context.have_low_byte) {
      context.low_byte = bytes[index];
      context.have_low_byte = true;
      continue;
    }
    const uint16_t bits = static_cast<uint16_t>(context.low_byte) |
                          (static_cast<uint16_t>(bytes[index]) << 8);
    context.have_low_byte = false;
    ++context.input_samples;
    resample24kTo16k(context, static_cast<int16_t>(bits));
  }
}

esp_err_t speechHttpEvent(esp_http_client_event_t *event) {
  auto *context = static_cast<PlaybackContext *>(event->user_data);
  if (context == nullptr) {
    return ESP_OK;
  }
  if (event->event_id == HTTP_EVENT_ON_HEADER && event->header_key != nullptr &&
      event->header_value != nullptr &&
      strcasecmp(event->header_key, "X-Audio-Sample-Rate") == 0) {
    context->sample_rate = atoi(event->header_value);
  } else if (event->event_id == HTTP_EVENT_ON_DATA && event->data_len > 0) {
    const int status = esp_http_client_get_status_code(event->client);
    if (status == 200) {
      if (context->sample_rate != 0 && context->sample_rate != 24000) {
        context->error_body = String("unsupported speech rate ") + context->sample_rate;
        context->write_ok = false;
        return ESP_FAIL;
      }
      feedSpeechBytes(*context, static_cast<const uint8_t *>(event->data), event->data_len);
    } else if (context->error_body.length() < 512) {
      const size_t room = 512 - context->error_body.length();
      context->error_body.concat(static_cast<const char *>(event->data),
                                 std::min(room, static_cast<size_t>(event->data_len)));
    }
  }
  return context->write_ok ? ESP_OK : ESP_FAIL;
}

bool playSpeech(const String &turn_id) {
  const uint32_t started = millis();
  while (millis() - started < kSpeechReadyTimeoutMs) {
    PlaybackContext context;
    const String url = apiRoot() + "/turns/" + turn_id + "/speech?from_sample=0";
    esp_http_client_config_t config = {};
    config.url = url.c_str();
    config.event_handler = speechHttpEvent;
    config.user_data = &context;
    config.timeout_ms = kSpeechReadyTimeoutMs;
    config.buffer_size = 2048;
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == nullptr) {
      return false;
    }
    esp_http_client_set_method(client, HTTP_METHOD_GET);
    const esp_err_t result = esp_http_client_perform(client);
    const int status = result == ESP_OK ? esp_http_client_get_status_code(client)
                                        : esp_http_client_get_status_code(client);
    flushPlayback(context);
    esp_http_client_cleanup(client);

    if (status == 200 && result == ESP_OK && context.write_ok) {
      Serial.printf("Speech complete: %u input samples -> %u output samples (rate header %d)\n",
                    static_cast<unsigned>(context.input_samples),
                    static_cast<unsigned>(context.played_samples), context.sample_rate);
      return true;
    }
    if (status == 425 || status == 404) {
      Serial.print('.');
      delay(500);
      continue;
    }
    Serial.printf("\nGET speech -> %d, transport %s: %s\n", status,
                  esp_err_to_name(result), context.error_body.c_str());
    return false;
  }
  Serial.println("\nTimed out waiting for speech");
  return false;
}

const char *askPhaseName() {
  switch (pending_ask.phase) {
    case AskPhase::NeedPost:
      return "waiting to submit";
    case AskPhase::NeedSpeech:
      return "waiting to play reply";
    case AskPhase::Idle:
    default:
      return "idle";
  }
}

bool sessionFailed(RecordingSession &session) {
  portENTER_CRITICAL(&session.mux);
  const bool failed = session.failed;
  portEXIT_CRITICAL(&session.mux);
  return failed;
}

void failSession(RecordingSession &session) {
  portENTER_CRITICAL(&session.mux);
  session.failed = true;
  portEXIT_CRITICAL(&session.mux);
}

uint32_t pendingUploadJobs(RecordingSession &session) {
  portENTER_CRITICAL(&session.mux);
  const uint32_t pending = session.pending_jobs;
  portEXIT_CRITICAL(&session.mux);
  return pending;
}

uint32_t acknowledgedParts(RecordingSession &session) {
  portENTER_CRITICAL(&session.mux);
  const uint32_t acknowledged = session.acknowledged_parts;
  portEXIT_CRITICAL(&session.mux);
  return acknowledged;
}

PartBuffer *acquirePartBuffer(RecordingSession &session) {
  PartBuffer *result = nullptr;
  portENTER_CRITICAL(&session.mux);
  for (auto &buffer : session.buffers) {
    if (buffer.state == PartBufferState::Free) {
      buffer.state = PartBufferState::Capturing;
      result = &buffer;
      break;
    }
  }
  portEXIT_CRITICAL(&session.mux);
  return result;
}

bool initializeRecordingBuffers(RecordingSession &session) {
  for (auto &buffer : session.buffers) {
    if (!allocateCapture(buffer.capture, RESPEAKER_RECORD_PART_SECONDS)) {
      for (auto &allocated : session.buffers) {
        allocated.capture.release();
      }
      return false;
    }
    buffer.capture.reset();
    buffer.session = &session;
    buffer.state = PartBufferState::Free;
  }
  Serial.printf("Recording pipeline ready: %u x %u-second PSRAM buffers (%u bytes free)\n",
                RESPEAKER_RECORD_BUFFER_COUNT, RESPEAKER_RECORD_PART_SECONDS,
                static_cast<unsigned>(ESP.getFreePsram()));
  return true;
}

void releaseRecordingBuffers(RecordingSession &session) {
  for (auto &buffer : session.buffers) {
    buffer.capture.release();
    buffer.session = nullptr;
    buffer.state = PartBufferState::Free;
  }
}

bool enqueueRecordingPart(RecordingSession &session, PartBuffer &buffer) {
  finalizeWav(buffer.capture);
  buffer.sequence = session.part_count;
  const uint32_t sequence = buffer.sequence;
  const size_t sample_count = buffer.capture.samples;
  const uint32_t peak_percent = buffer.capture.peakPercent();

  portENTER_CRITICAL(&session.mux);
  buffer.state = PartBufferState::Queued;
  ++session.pending_jobs;
  portEXIT_CRITICAL(&session.mux);

  // Reserve the sequence before publishing the pointer. The worker may upload
  // and recycle a short final part before this task gets another time slice.
  ++session.part_count;

  PartBuffer *queued = &buffer;
  if (upload_queue == nullptr || xQueueSend(upload_queue, &queued, 0) != pdTRUE) {
    --session.part_count;
    portENTER_CRITICAL(&session.mux);
    --session.pending_jobs;
    session.failed = true;
    buffer.state = PartBufferState::RetainedAfterFailure;
    portEXIT_CRITICAL(&session.mux);
    Serial.println("Recording upload queue overflowed; recording will not be committed");
    return false;
  }

  Serial.printf("Queued part %lu: %u samples, peak %lu%% (%lu upload jobs pending)\n",
                static_cast<unsigned long>(sequence), static_cast<unsigned>(sample_count),
                static_cast<unsigned long>(peak_percent),
                static_cast<unsigned long>(pendingUploadJobs(session)));
  return true;
}

void recordingUploadTask(void *) {
  while (true) {
    PartBuffer *buffer = nullptr;
    if (xQueueReceive(upload_queue, &buffer, portMAX_DELAY) != pdTRUE || buffer == nullptr ||
        buffer->session == nullptr) {
      continue;
    }
    RecordingSession &session = *buffer->session;

    portENTER_CRITICAL(&session.mux);
    buffer->state = PartBufferState::Uploading;
    const bool already_failed = session.failed;
    portEXIT_CRITICAL(&session.mux);

    bool uploaded = false;
    if (!already_failed) {
      for (int attempt = 1; attempt <= 3; ++attempt) {
        if (sessionFailed(session)) {
          break;
        }
        if (connectWiFi(true) && uploadRecordingPart(*buffer)) {
          uploaded = true;
          break;
        }
        if (attempt < 3 && !sessionFailed(session)) {
          Serial.printf("Part %lu attempt %d was not confirmed; retrying identical bytes...\n",
                        static_cast<unsigned long>(buffer->sequence), attempt);
          vTaskDelay(pdMS_TO_TICKS(350 * attempt));
        }
      }
    }

    if (uploaded) {
      buffer->capture.reset();
      portENTER_CRITICAL(&session.mux);
      ++session.acknowledged_parts;
      buffer->state = PartBufferState::Free;
      --session.pending_jobs;
      portEXIT_CRITICAL(&session.mux);
    } else {
      // Keep the stack-owned buffer/session alive until the worker's last log
      // has completed. Once pending_jobs reaches zero, the main task may free
      // these objects immediately.
      const uint32_t failed_sequence = buffer->sequence;
      Serial.printf("Part %lu was not acknowledged; retained in PSRAM and recording aborted\n",
                    static_cast<unsigned long>(failed_sequence));
      portENTER_CRITICAL(&session.mux);
      session.failed = true;
      buffer->state = PartBufferState::RetainedAfterFailure;
      --session.pending_jobs;
      portEXIT_CRITICAL(&session.mux);
    }
  }
}

bool startRecordingUploadTask() {
  upload_queue = xQueueCreate(RESPEAKER_RECORD_BUFFER_COUNT, sizeof(PartBuffer *));
  if (upload_queue == nullptr) {
    Serial.println("Could not create recording upload queue");
    return false;
  }
  const BaseType_t created =
      xTaskCreatePinnedToCore(recordingUploadTask, "kibo-upload", 8192, nullptr, 1,
                              &upload_task_handle, 0);
  if (created != pdPASS) {
    Serial.println("Could not start recording upload task");
    vQueueDelete(upload_queue);
    upload_queue = nullptr;
    return false;
  }
  return true;
}

void copyCaptureFrames(RecordingSession &session, PartBuffer &buffer,
                       size_t source_offset, size_t frame_count) {
  int16_t *pcm = buffer.capture.pcm();
  for (size_t frame = 0; frame < frame_count; ++frame) {
#if RESPEAKER_CAPTURE_CHANNEL == 1
    const int32_t source = i2s_stereo[(source_offset + frame) * 2 + 1];
#else
    const int32_t source = i2s_stereo[(source_offset + frame) * 2];
#endif
    const int16_t sample =
        static_cast<int16_t>(source >> (kI2SBitsPerSample - kPcmBitsPerSample));
    pcm[buffer.capture.samples++] = sample;
    ++session.total_samples;
    const uint16_t magnitude = sample == INT16_MIN
                                   ? 32768
                                   : static_cast<uint16_t>(std::abs(static_cast<int>(sample)));
    buffer.capture.peak = std::max(buffer.capture.peak, magnitude);
    session.peak = std::max(session.peak, magnitude);
  }
}

bool captureRecordingParts(RecordingSession &session, uint32_t fixed_ms,
                           int held_button_pin) {
  const uint64_t target_samples =
      held_button_pin < 0
          ? (static_cast<uint64_t>(fixed_ms) * RESPEAKER_I2S_SAMPLE_RATE) / 1000ULL
          : 0;
  PartBuffer *current = acquirePartBuffer(session);
  if (current == nullptr) {
    failSession(session);
    Serial.println("No recording buffer was available at capture start");
    return false;
  }

  drainI2SRx();
  Serial.println(held_button_pin >= 0 ? "Recording while held..." : "Recording...");
  uint32_t released_since = 0;
  uint32_t last_meter = millis();
  bool capturing = true;
  CaptureAskRestore ask_restore;

  while (capturing) {
    serviceCaptureAskRestore(ask_restore);
    if (sessionFailed(session)) {
      Serial.println("Recording stopped because an upload failed");
      break;
    }
    if (held_button_pin >= 0) {
      if (digitalRead(held_button_pin) == HIGH) {
        if (released_since == 0) {
          released_since = millis();
        } else if (millis() - released_since >= kButtonDebounceMs) {
          break;
        }
      } else {
        released_since = 0;
      }
    } else if (session.total_samples >= target_samples) {
      break;
    }

    size_t bytes_read = 0;
    const esp_err_t result = i2s_read(kI2SPort, i2s_stereo, sizeof(i2s_stereo),
                                      &bytes_read, pdMS_TO_TICKS(250));
    if (result != ESP_OK) {
      Serial.printf("I2S read failed: %s\n", esp_err_to_name(result));
      failSession(session);
      break;
    }

    const size_t frames = bytes_read / (sizeof(int32_t) * kI2SChannels);
    size_t source_offset = 0;
    while (source_offset < frames) {
      if (held_button_pin < 0 && session.total_samples >= target_samples) {
        capturing = false;
        break;
      }
      if (current == nullptr) {
        current = acquirePartBuffer(session);
        if (current == nullptr) {
          Serial.printf(
              "All %u recording buffers are awaiting upload; aborting without commit\n",
              RESPEAKER_RECORD_BUFFER_COUNT);
          failSession(session);
          capturing = false;
          break;
        }
      }

      size_t to_copy = std::min(frames - source_offset,
                                current->capture.capacity_samples - current->capture.samples);
      if (held_button_pin < 0) {
        const uint64_t target_remaining = target_samples - session.total_samples;
        to_copy = std::min<uint64_t>(to_copy, target_remaining);
      }
      copyCaptureFrames(session, *current, source_offset, to_copy);
      source_offset += to_copy;

      if (current->capture.samples == current->capture.capacity_samples) {
        if (!enqueueRecordingPart(session, *current)) {
          capturing = false;
          break;
        }
        current = nullptr;
      }
    }

    if (millis() - last_meter >= 500) {
      last_meter = millis();
      const uint32_t peak_percent = std::min<uint32_t>(
          100, (static_cast<uint32_t>(session.peak) * 100U + 16383U) / 32767U);
      Serial.printf("  %llu ms, peak %lu%%, %lu upload jobs pending\n",
                    static_cast<unsigned long long>(
                        session.total_samples * 1000ULL / RESPEAKER_I2S_SAMPLE_RATE),
                    static_cast<unsigned long>(peak_percent),
                    static_cast<unsigned long>(pendingUploadJobs(session)));
    }
  }

  finishCaptureAskRestore(ask_restore);

  if (session.total_samples < RESPEAKER_I2S_SAMPLE_RATE / 2) {
    Serial.println("Discarding recording shorter than 500 ms");
    return false;
  }
  if (session.peak == 0) {
    Serial.println("Discarding silent recording; any staged parts will remain uncommitted");
    return false;
  }
  if (sessionFailed(session)) {
    return false;
  }
  if (current != nullptr && current->capture.samples > 0 &&
      !enqueueRecordingPart(session, *current)) {
    return false;
  }
  Serial.printf("Capture ended at %llu samples (%llu ms) across %lu parts\n",
                static_cast<unsigned long long>(session.total_samples),
                static_cast<unsigned long long>(
                    session.total_samples * 1000ULL / RESPEAKER_I2S_SAMPLE_RATE),
                static_cast<unsigned long>(session.part_count));
  return true;
}

void waitForRecordingUploads(RecordingSession &session) {
  uint32_t last_report = millis();
  while (pendingUploadJobs(session) > 0) {
    if (millis() - last_report >= 2000) {
      last_report = millis();
      Serial.printf("Waiting for recording uploads: %lu pending, %lu/%lu acknowledged\n",
                    static_cast<unsigned long>(pendingUploadJobs(session)),
                    static_cast<unsigned long>(acknowledgedParts(session)),
                    static_cast<unsigned long>(session.part_count));
    }
    delay(20);
  }
}

bool recordAndQueue(uint32_t fixed_ms, int held_button_pin = -1) {
  if (upload_queue == nullptr) {
    Serial.println("Recording uploader is unavailable");
    return false;
  }
  if (!connectWiFi(true)) {
    Serial.println("Recording did not start because Wi-Fi is unavailable");
    return false;
  }

  RecordingSession session;
  session.recording_id = makeId("recording");
  session.api_root = apiRoot();
  if (!initializeRecordingBuffers(session)) {
    return false;
  }

  playRecordingCue(true);
  const bool captured = captureRecordingParts(session, fixed_ms, held_button_pin);
  playRecordingCue(false);
  bool played_failure_cue = false;
  if (sessionFailed(session)) {
    playRecordingFailureCue();
    played_failure_cue = true;
  }
  waitForRecordingUploads(session);

  bool completed = false;
  if (captured && !sessionFailed(session) &&
      acknowledgedParts(session) == session.part_count) {
    completed = completeRecording(session);
    if (completed) {
      Serial.printf("Recording queued for Kibo: %s (%llu samples in %lu parts)\n",
                    session.recording_id.c_str(),
                    static_cast<unsigned long long>(session.total_samples),
                    static_cast<unsigned long>(session.part_count));
      Serial.println("Record again, or press ASK when ready for a reply.");
    } else {
      Serial.printf(
          "Recording %s completion was not confirmed; the server may have committed it, "
          "otherwise its parts remain staged\n",
          session.recording_id.c_str());
      playRecordingFailureCue();
      played_failure_cue = true;
    }
  } else if (sessionFailed(session)) {
    Serial.printf(
        "Recording %s was NOT committed: upload could not keep up or was not acknowledged\n",
        session.recording_id.c_str());
    if (!played_failure_cue) {
      playRecordingFailureCue();
      played_failure_cue = true;
    }
  }

  releaseRecordingBuffers(session);
  return completed;
}

void askKibo() {
  if (pending_ask.phase == AskPhase::Idle) {
    pending_ask.turn_id = makeId("turn");
    pending_ask.phase = AskPhase::NeedPost;
  } else {
    Serial.printf("Retrying Kibo turn %s (%s)\n", pending_ask.turn_id.c_str(), askPhaseName());
  }

  if (!connectWiFi(true)) {
    Serial.println("ASK is retained in RAM; press ASK again when Wi-Fi is available");
    return;
  }

  if (pending_ask.phase == AskPhase::NeedPost) {
    const TurnPostResult result = createTurn(pending_ask.turn_id);
    if (result == TurnPostResult::NothingPending) {
      Serial.println("No recordings are waiting for Kibo.");
      pending_ask.clear();
      return;
    }
    if (result == TurnPostResult::Retryable) {
      Serial.println("ASK was not confirmed; press ASK again to retry the same turn safely");
      return;
    }
    if (result == TurnPostResult::PermanentError) {
      Serial.println("ASK was rejected; abandoning this turn ID");
      pending_ask.clear();
      return;
    }
    pending_ask.phase = AskPhase::NeedSpeech;
  }

  Serial.print("Waiting for Kibo speech");
  if (playSpeech(pending_ask.turn_id)) {
    pending_ask.clear();
  } else {
    Serial.printf("Reply not played; press ASK to retry turn %s, or type forget\n",
                  pending_ask.turn_id.c_str());
  }
  Serial.println();
  drainI2SRx();
}

void printHelp() {
  Serial.println(
      "Commands:\n"
      "  status                         hardware, Wi-Fi, and kibod check\n"
      "  xmos                           XMOS firmware and mute state\n"
      "  wifi <ssid> <password>         save credentials in ESP32 NVS\n"
      "  clearwifi                      erase saved Wi-Fi credentials\n"
      "  server <http://host:port>      save kibod base URL\n"
      "  target <project> <conversation> save Kibo destination\n"
      "  volume [0-100]                 show or save speaker volume\n"
      "  mic                            capture 3 s; report peak only\n"
      "  record [seconds]               capture (default 4 s); queue recording only\n"
      "  ask                            submit queued recordings; play reply\n"
      "  forget                         abandon a retained ASK retry\n"
      "  chime                          speaker-volume test\n"
      "  tone                           six-second I2S speaker test\n"
      "  play <turn-id>                 play an existing Kibo reply\n"
      "  test                           record, then ask, then play reply\n"
      "Hold USR to record (USR->D2/GPIO3). Tap MUTE to ASK (MUTE->D3/GPIO4).\n"
      "BOOT remains a no-solder hold-to-record fallback.");
}

void printStatus() {
  Serial.printf("PSRAM: %u bytes total, %u free\n", static_cast<unsigned>(ESP.getPsramSize()),
                static_cast<unsigned>(ESP.getFreePsram()));
  Serial.printf("Target: %s  project=%s conversation=%s\n", server_url.c_str(),
                project_id.c_str(), conversation_id.c_str());
  Serial.printf("Speaker volume: %u%%\n", speaker_volume_percent);
  Serial.printf("Wi-Fi: %s", WiFi.status() == WL_CONNECTED ? "connected" : "disconnected");
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf(" (%s, RSSI %d dBm)", WiFi.localIP().toString().c_str(), WiFi.RSSI());
  }
  Serial.println();
  Serial.printf("ASK state: %s", askPhaseName());
  if (pending_ask.phase != AskPhase::Idle) {
    Serial.printf(" (%s)", pending_ask.turn_id.c_str());
  }
  Serial.println();
  printXmosStatus();
  if (!wifi_ssid.isEmpty()) {
    checkServer();
  }
}

void runMicTest() {
  Capture capture;
  captureAudio(capture, RESPEAKER_MIC_TEST_SECONDS * 1000UL);
  capture.release();
}

void runSerialTest() {
  if (pending_ask.phase != AskPhase::Idle) {
    Serial.println("Cannot start test while an ASK is retained; retry it or type forget");
    return;
  }
  if (recordAndQueue(RESPEAKER_SERIAL_TEST_SECONDS * 1000UL)) {
    askKibo();
  }
}

void runSerialRecord(uint32_t seconds = RESPEAKER_SERIAL_TEST_SECONDS) {
  recordAndQueue(seconds * 1000UL);
}

void handleCommand(String command) {
  command.trim();
  if (command.isEmpty()) {
    return;
  }
  if (command == "help" || command == "?") {
    printHelp();
  } else if (command == "status") {
    printStatus();
  } else if (command == "xmos") {
    printXmosStatus();
  } else if (command == "volume") {
    Serial.printf("Speaker volume: %u%%\n", speaker_volume_percent);
  } else if (command.startsWith("volume ")) {
    String value = command.substring(7);
    value.trim();
    bool valid = !value.isEmpty();
    for (size_t index = 0; valid && index < value.length(); ++index) {
      valid = value[index] >= '0' && value[index] <= '9';
    }
    const long percent = valid ? value.toInt() : -1;
    if (percent < 0 || percent > 100) {
      Serial.println("Usage: volume <0-100>");
      return;
    }
    speaker_volume_percent = static_cast<uint8_t>(percent);
    preferences.putUChar("volume", speaker_volume_percent);
    Serial.printf("Speaker volume saved: %u%%\n", speaker_volume_percent);
  } else if (command == "mic") {
    runMicTest();
  } else if (command == "record") {
    runSerialRecord();
  } else if (command.startsWith("record ")) {
    String value = command.substring(7);
    value.trim();
    bool valid = !value.isEmpty();
    for (size_t index = 0; valid && index < value.length(); ++index) {
      valid = value[index] >= '0' && value[index] <= '9';
    }
    const unsigned long seconds = valid ? strtoul(value.c_str(), nullptr, 10) : 0;
    if (seconds == 0 || seconds > 86400) {
      Serial.println("Usage: record <seconds>, from 1 through 86400");
      return;
    }
    runSerialRecord(static_cast<uint32_t>(seconds));
  } else if (command == "ask") {
    askKibo();
  } else if (command == "forget") {
    if (pending_ask.phase == AskPhase::Idle) {
      Serial.println("There is no retained ASK to forget");
    } else {
      Serial.printf("Forgot retained Kibo turn %s\n", pending_ask.turn_id.c_str());
      pending_ask.clear();
    }
  } else if (command == "chime") {
    playChime();
  } else if (command == "tone") {
    playChime(6000);
  } else if (command.startsWith("play ")) {
    const String turn_id = command.substring(5);
    if (!connectWiFi(true)) {
      return;
    }
    Serial.printf("Playing Kibo turn %s...\n", turn_id.c_str());
    playSpeech(turn_id);
  } else if (command == "test") {
    runSerialTest();
  } else if (command == "clearwifi") {
    preferences.remove("wifi_ssid");
    preferences.remove("wifi_pass");
    wifi_ssid = "";
    wifi_password = "";
    WiFi.disconnect(true, true);
    Serial.println("Saved Wi-Fi credentials erased");
  } else if (command.startsWith("wifi ")) {
    const String rest = command.substring(5);
    const int separator = rest.indexOf(' ');
    if (separator <= 0 || separator == static_cast<int>(rest.length()) - 1) {
      Serial.println("Usage: wifi <ssid> <password>");
      return;
    }
    wifi_ssid = rest.substring(0, separator);
    wifi_password = rest.substring(separator + 1);
    preferences.putString("wifi_ssid", wifi_ssid);
    preferences.putString("wifi_pass", wifi_password);
    Serial.printf("Saved Wi-Fi credentials for '%s' (password not echoed)\n", wifi_ssid.c_str());
    WiFi.disconnect(true, true);
    delay(250);
    connectWiFi(true);
  } else if (command.startsWith("server ")) {
    if (pending_ask.phase != AskPhase::Idle) {
      Serial.println("Cannot change server while an ASK is retained; retry it or type forget");
      return;
    }
    const String value = cleanServerUrl(command.substring(7));
    if (!value.startsWith("http://")) {
      Serial.println("Prototype server URL must start with http://");
      return;
    }
    server_url = value;
    preferences.putString("server", server_url);
    Serial.printf("Server saved: %s\n", server_url.c_str());
    Serial.println("Pending recordings, if any, remain on the previous server/target");
  } else if (command.startsWith("target ")) {
    if (pending_ask.phase != AskPhase::Idle) {
      Serial.println("Cannot change target while an ASK is retained; retry it or type forget");
      return;
    }
    const String rest = command.substring(7);
    const int separator = rest.indexOf(' ');
    if (separator <= 0 || separator == static_cast<int>(rest.length()) - 1) {
      Serial.println("Usage: target <project> <conversation>");
      return;
    }
    project_id = rest.substring(0, separator);
    conversation_id = rest.substring(separator + 1);
    project_id.trim();
    conversation_id.trim();
    preferences.putString("project", project_id);
    preferences.putString("conversation", conversation_id);
    Serial.printf("Target saved: %s/%s\n", project_id.c_str(), conversation_id.c_str());
    Serial.println("Pending recordings, if any, remain in the previous conversation");
  } else {
    Serial.println("Unknown command. Type help.");
  }
}

void pollSerial() {
  while (Serial.available() > 0) {
    const char character = static_cast<char>(Serial.read());
    if (character == '\r' || character == '\n') {
      if (!serial_line.isEmpty()) {
        const String command = serial_line;
        serial_line = "";
        handleCommand(command);
      }
    } else if (serial_line.length() < 192) {
      serial_line += character;
    }
  }
}

int pressedRecordButton() {
  if (digitalRead(kBootButtonPin) == LOW) {
    return kBootButtonPin;
  }
  if (digitalRead(kUserButtonPin) == LOW) {
    return kUserButtonPin;
  }
  return -1;
}

bool waitForStableRelease(int pin) {
  const uint32_t started = millis();
  uint32_t released_since = 0;
  while (millis() - started < kAskHoldTimeoutMs) {
    if (digitalRead(pin) == HIGH) {
      if (released_since == 0) {
        released_since = millis();
      } else if (millis() - released_since >= kButtonDebounceMs) {
        return true;
      }
    } else {
      released_since = 0;
    }
    delay(5);
  }
  return false;
}

void pollButtons() {
  const int pin = pressedRecordButton();
  if (pin < 0) {
    record_button_was_down = false;
  } else if (!record_button_was_down) {
    delay(kButtonDebounceMs);
    if (digitalRead(pin) == LOW) {
      record_button_was_down = true;
      recordAndQueue(0, pin);
      return;
    }
  } else {
    return;
  }

  if (digitalRead(kAskButtonPin) == HIGH) {
    if (ask_button_was_down && suppress_timed_out_ask) {
      delay(kButtonDebounceMs);
      if (digitalRead(kAskButtonPin) == LOW) {
        return;
      }
      // A very long hold is treated as a stuck key, not an ASK. Restore the
      // XMOS mute side effect after release, then resume normal edge capture.
      suppress_timed_out_ask = false;
      clearAskButtonEdge();
      suppress_ask_interrupt = false;
      restoreXmosAfterAskPress();
    }
    ask_button_was_down = false;
    return;
  }
  if (ask_button_was_down) {
    return;
  }
  delay(kButtonDebounceMs);
  if (digitalRead(kAskButtonPin) != LOW) {
    return;
  }
  ask_button_was_down = true;
  suppress_ask_interrupt = true;
  clearAskButtonEdge();
  Serial.println("ASK pressed; release the button...");
  if (!waitForStableRelease(kAskButtonPin)) {
    Serial.println("ASK button stayed low for 15 seconds; waiting for release without submitting");
    suppress_timed_out_ask = true;
    return;
  }
  clearAskButtonEdge();
  suppress_ask_interrupt = false;
  restoreXmosAfterAskPress();
  askKibo();
}

void pollMissedAskPress() {
  if (!ask_edge_pending || ask_button_was_down || suppress_timed_out_ask ||
      digitalRead(kAskButtonPin) == LOW) {
    return;
  }
  // Only recover an interrupt after the shared button line has been HIGH for
  // a full debounce window. That prevents pulsing it while a physical press
  // which began during the I2C/network path is still held to ground.
  delay(kButtonDebounceMs);
  if (digitalRead(kAskButtonPin) == LOW || !takeAskButtonEdge()) {
    return;
  }

  // The GPIO interrupt latches a quick tap while capture, upload, or playback
  // blocks ordinary polling. Multiple impatient taps coalesce into one ASK.
  Serial.println("Detected an ASK tap that occurred during another operation");
  restoreXmosAfterAskPress();
  askKibo();
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(800);
  Serial.println("\nKibo ReSpeaker Lite client (RAM-only prototype)");
  loadSettings();
  pinMode(kBootButtonPin, INPUT_PULLUP);
  pinMode(kUserButtonPin, INPUT_PULLUP);
  pinMode(kAskButtonPin, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(kAskButtonPin), noteAskButtonEdge, FALLING);
  Wire.begin(5, 6);
  setupI2S();
  startRecordingUploadTask();
  Serial.printf("PSRAM available: %u bytes\n", static_cast<unsigned>(ESP.getPsramSize()));
  Serial.printf("Speaker volume: %u%%\n", speaker_volume_percent);
  printXmosStatus();
  bool muted_at_boot = false;
  if (readXmosMuted(muted_at_boot)) {
    if (muted_at_boot) {
      Serial.println("XMOS started muted; attempting to restore the ASK-key unmuted state");
      restoreXmosAfterAskPress();
    }
  }
  if (!wifi_ssid.isEmpty()) {
    connectWiFi(true);
  }
  printHelp();
}

void loop() {
  pollSerial();
  pollButtons();
  pollMissedAskPress();
  if (!wifi_ssid.isEmpty() && WiFi.status() != WL_CONNECTED) {
    connectWiFi(false);
  }
  delay(5);
}
