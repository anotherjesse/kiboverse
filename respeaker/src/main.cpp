#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <Wire.h>
#include <driver/i2s.h>
#include <esp_heap_caps.h>
#include <esp_http_client.h>
#include <esp_system.h>
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
volatile bool suppress_ask_interrupt = false;

enum class AskPhase {
  Idle,
  NeedPost,
  NeedSpeech,
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
    ask_edge_pending = true;
  }
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

bool captureAudio(Capture &capture, uint32_t fixed_ms, int held_button_pin = -1) {
  const uint32_t max_seconds = held_button_pin >= 0
                                   ? RESPEAKER_MAX_RECORD_SECONDS
                                   : std::max<uint32_t>(1, (fixed_ms + 999) / 1000);
  if (!allocateCapture(capture, max_seconds)) {
    return false;
  }
  drainI2SRx();
  Serial.println(held_button_pin >= 0 ? "Recording while held..." : "Recording...");
  const uint32_t started = millis();
  uint32_t last_meter = started;
  uint32_t released_since = 0;

  while (capture.samples < capture.capacity_samples) {
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
    }
    if (held_button_pin < 0 && millis() - started >= fixed_ms) {
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

bool uploadClip(const Capture &capture, const String &clip_id) {
  char sha[65];
  sha256Hex(capture.wav, capture.wavBytes(), sha);
  char duration[24];
  char peak[12];
  snprintf(duration, sizeof(duration), "%lu", static_cast<unsigned long>(capture.durationMs()));
  snprintf(peak, sizeof(peak), "%lu", static_cast<unsigned long>(capture.peakPercent()));
  const String url = apiRoot() + "/clips/" + clip_id;

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
  esp_http_client_set_header(client, "X-Duration-Ms", duration);
  esp_http_client_set_header(client, "X-Peak-Pct", peak);
  esp_http_client_set_post_field(client, reinterpret_cast<const char *>(capture.wav),
                                 capture.wavBytes());
  Serial.printf("Uploading clip %s (%u bytes)...\n", clip_id.c_str(),
                static_cast<unsigned>(capture.wavBytes()));
  const esp_err_t result = esp_http_client_perform(client);
  const int status = result == ESP_OK ? esp_http_client_get_status_code(client) : -1;
  if (result != ESP_OK) {
    Serial.printf("Clip upload failed: %s\n", esp_err_to_name(result));
  }
  Serial.printf("PUT clip -> %d %s\n", status, response.body.c_str());
  esp_http_client_cleanup(client);
  return status == 200 || status == 201;
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

bool queueCapture(Capture &capture) {
  if (capture.samples < RESPEAKER_I2S_SAMPLE_RATE / 2) {
    Serial.println("Discarding clip shorter than 500 ms");
    return false;
  }
  if (capture.peak == 0) {
    Serial.println("Discarding silent clip");
    return false;
  }

  const String clip_id = makeId("clip");
  for (int attempt = 1; attempt <= 3; ++attempt) {
    if (connectWiFi(true) && uploadClip(capture, clip_id)) {
      Serial.printf("Recording queued for Kibo: %s\n", clip_id.c_str());
      Serial.println("Record again, or press ASK when ready for a reply.");
      return true;
    }
    if (attempt < 3) {
      Serial.printf("Upload attempt %d failed; retrying the same clip ID...\n", attempt);
      delay(350 * attempt);
    }
  }

  Serial.println(
      "Upload was not confirmed; the RAM buffer will be released. The server may still have "
      "received an ambiguous attempt.");
  return false;
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
      "  record                         capture 4 s; queue recording only\n"
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
  Capture capture;
  playRecordingCue(true);
  const bool captured = captureAudio(capture, RESPEAKER_SERIAL_TEST_SECONDS * 1000UL);
  playRecordingCue(false);
  if (captured) {
    if (queueCapture(capture)) {
      capture.release();
      askKibo();
      return;
    }
  }
  capture.release();
}

void runSerialRecord() {
  Capture capture;
  playRecordingCue(true);
  const bool captured = captureAudio(capture, RESPEAKER_SERIAL_TEST_SECONDS * 1000UL);
  playRecordingCue(false);
  if (captured) {
    queueCapture(capture);
  }
  capture.release();
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
      Capture capture;
      playRecordingCue(true);
      const bool captured = captureAudio(capture, 0, pin);
      playRecordingCue(false);
      if (captured) {
        queueCapture(capture);
      }
      capture.release();
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
