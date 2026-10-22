// zMeet-owned C facade over WebRTC APM (not vendored).
// C facade over webrtc::AudioProcessing. Compiles against both
// webrtc-audio-processing 1.3 (Create() returns a raw pointer) and 2.x
// (Create() returns rtc::scoped_refptr): direct-initializing a scoped_refptr
// works for both.
#include "zm_apm.h"

#include <new>
#include <vector>

#include "api/scoped_refptr.h"
#include "modules/audio_processing/include/audio_processing.h"

// Planar 10 ms buffer: `ptr[c]` points at channel c inside `data`.
struct Planar {
  int frames, channels;
  std::vector<float> data;
  std::vector<float*> ptr;
  Planar(int f, int ch)
      : frames(f), channels(ch), data(static_cast<size_t>(f * ch)),
        ptr(static_cast<size_t>(ch)) {
    for (int c = 0; c < ch; ++c) ptr[c] = data.data() + c * f;
  }
  void From(const float* in) {
    for (int i = 0; i < frames; ++i)
      for (int c = 0; c < channels; ++c) ptr[c][i] = in[i * channels + c];
  }
  void To(float* out) const {
    for (int i = 0; i < frames; ++i)
      for (int c = 0; c < channels; ++c) out[i * channels + c] = ptr[c][i];
  }
};

// Render and capture use separate buffers, so one render thread and one
// capture thread may call in concurrently (APM locks internally).
struct ZMApm {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  int frames;  // samples per channel per 10 ms
  Planar capture, render_in, render_out;
  ZMApm(int rate, int ch)
      : stream(rate, static_cast<size_t>(ch)), frames(rate / 100),
        capture(rate / 100, ch), render_in(rate / 100, ch),
        render_out(rate / 100, ch) {}
};

extern "C" {

ZMApm* zm_apm_create(int sample_rate_hz, int num_channels, int noise_suppression) {
  if (sample_rate_hz != 16000 && sample_rate_hz != 32000 && sample_rate_hz != 48000)
    return nullptr;
  if (num_channels < 1 || num_channels > 2) return nullptr;
  if (noise_suppression < 0 || noise_suppression > 4) return nullptr;

  ZMApm* z = new (std::nothrow) ZMApm(sample_rate_hz, num_channels);
  if (!z) return nullptr;
  z->apm = rtc::scoped_refptr<webrtc::AudioProcessing>(
      webrtc::AudioProcessingBuilder().Create());
  if (!z->apm) {
    delete z;
    return nullptr;
  }

  webrtc::AudioProcessing::Config cfg;
  cfg.echo_canceller.enabled = true;     // AEC3 (full-band, desktop)
  cfg.echo_canceller.mobile_mode = false;
  cfg.high_pass_filter.enabled = true;   // AEC3 enforces it anyway
  cfg.noise_suppression.enabled = noise_suppression > 0;
  if (noise_suppression > 0) {
    cfg.noise_suppression.level =
        static_cast<webrtc::AudioProcessing::Config::NoiseSuppression::Level>(
            noise_suppression - 1);
  }
  cfg.gain_controller1.enabled = false;  // leave levels alone
  cfg.gain_controller2.enabled = false;
  z->apm->ApplyConfig(cfg);
  return z;
}

void zm_apm_destroy(ZMApm* z) { delete z; }

int zm_apm_frame_samples(const ZMApm* z) { return z ? z->frames : 0; }

int zm_apm_process_reverse(ZMApm* z, const float* frame) {
  if (!z || !frame) return -1;
  z->render_in.From(frame);
  return z->apm->ProcessReverseStream(z->render_in.ptr.data(), z->stream,
                                      z->stream, z->render_out.ptr.data());
}

int zm_apm_process_capture(ZMApm* z, float* frame) {
  if (!z || !frame) return -1;
  z->capture.From(frame);
  int err = z->apm->ProcessStream(z->capture.ptr.data(), z->stream, z->stream,
                                  z->capture.ptr.data());
  z->capture.To(frame);
  return err;
}

int zm_apm_set_stream_delay_ms(ZMApm* z, int delay_ms) {
  if (!z) return -1;
  return z->apm->set_stream_delay_ms(delay_ms);
}

int zm_apm_get_stats(ZMApm* z, ZMApmStats* out) {
  if (!z || !out) return -1;
  webrtc::AudioProcessingStats s = z->apm->GetStatistics();
  *out = ZMApmStats{};
  if (s.echo_return_loss) {
    out->has_echo_return_loss = 1;
    out->echo_return_loss = *s.echo_return_loss;
  }
  if (s.echo_return_loss_enhancement) {
    out->has_echo_return_loss_enhancement = 1;
    out->echo_return_loss_enhancement = *s.echo_return_loss_enhancement;
  }
  if (s.divergent_filter_fraction) {
    out->has_divergent_filter_fraction = 1;
    out->divergent_filter_fraction = *s.divergent_filter_fraction;
  }
  if (s.delay_ms) {
    out->has_delay_ms = 1;
    out->delay_ms = *s.delay_ms;
  }
  return 0;
}

}  // extern "C"
