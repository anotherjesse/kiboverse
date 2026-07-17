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

// RAM-only prototype limits.
#define RESPEAKER_MAX_RECORD_SECONDS 20
#define RESPEAKER_SERIAL_TEST_SECONDS 4
#define RESPEAKER_MIC_TEST_SECONDS 3
