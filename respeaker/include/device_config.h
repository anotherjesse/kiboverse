#pragma once

// Bench defaults. These can be changed at runtime with the `server`, `target`,
// and `volume` serial commands and are then kept in NVS.
#define KIBO_DEFAULT_SERVER "http://192.168.86.27:3003"
#define KIBO_DEFAULT_PROJECT "kibo"
#define KIBO_DEFAULT_CONVERSATION "general"
#define KIBO_DEFAULT_VOLUME_PERCENT 25

// The XU316 on this particular board is already running the proven 16 kHz I2S
// image. It is the clock master; the XIAO is a 32-bit-stereo I2S slave.
#define RESPEAKER_I2S_SAMPLE_RATE 16000
#define RESPEAKER_CAPTURE_CHANNEL 0

// Recording is divided into independently acknowledged WAV parts. Four
// 20-second PSRAM buffers allow capture to continue while earlier parts upload;
// the total recording duration is not capped by RAM.
#define RESPEAKER_RECORD_PART_SECONDS 20
#define RESPEAKER_RECORD_BUFFER_COUNT 4
#define RESPEAKER_SERIAL_TEST_SECONDS 4
#define RESPEAKER_MIC_TEST_SECONDS 3
