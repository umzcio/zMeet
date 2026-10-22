#ifndef ZM_APM_H
#define ZM_APM_H

// Plain-C facade over WebRTC's AudioProcessing module (AEC3 echo canceller).
// Swift imports this header only; no C++ crosses the module boundary.
//
// Frames are exactly 10 ms: sample_rate_hz / 100 samples per channel,
// float in [-1, 1], interleaved when num_channels > 1.
// One instance per recording. Render and capture keep separate buffers, so
// one render thread + one capture thread is allowed by APM's contract, but
// only single-queue use has been tested. Call zm_apm_get_stats on the capture
// thread.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZMApm ZMApm;

typedef struct ZMApmStats {
  int has_echo_return_loss;
  double echo_return_loss;              // dB, input echo vs far-end
  int has_echo_return_loss_enhancement;
  double echo_return_loss_enhancement;  // dB, AEC3's own ERLE estimate
  int has_divergent_filter_fraction;
  double divergent_filter_fraction;
  int has_delay_ms;
  int delay_ms;                         // AEC3's estimated render->capture delay
} ZMApmStats;

// sample_rate_hz: 16000, 32000 or 48000. num_channels: 1 or 2.
// noise_suppression: 0 = off, 1..4 = low/moderate/high/very high.
// Returns NULL on invalid arguments.
ZMApm *zm_apm_create(int sample_rate_hz, int num_channels, int noise_suppression);
void zm_apm_destroy(ZMApm *apm);

int zm_apm_frame_samples(const ZMApm *apm);  // per channel per 10 ms

// Far end (what is played to the speaker / the system-audio reference).
// Returns 0 (kNoError) or a negative AudioProcessing error code.
int zm_apm_process_reverse(ZMApm *apm, const float *frame);

// Near end (microphone). Processed in place.
int zm_apm_process_capture(ZMApm *apm, float *frame);

// Optional hint: render->capture delay in ms (AEC3 estimates it anyway).
int zm_apm_set_stream_delay_ms(ZMApm *apm, int delay_ms);

// APM's statistics as of the latest zm_apm_process_capture call, however
// long ago the previous read was; every has_* is 0 before the first call.
// Reads what zm_apm_process_capture stored, so call it on the capture thread.
// Returns 0, or -1 on NULL arguments.
int zm_apm_get_stats(const ZMApm *apm, ZMApmStats *out);

#ifdef __cplusplus
}
#endif

#endif  // ZM_APM_H
