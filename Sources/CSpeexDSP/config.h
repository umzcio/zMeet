#ifndef ZMEET_SPEEX_CONFIG_H
#define ZMEET_SPEEX_CONFIG_H
/* Built outside the speex source tree: we must provide the spx integer types
   (arch.h skips speexdsp_types.h when OUTSIDE_SPEEX is set). */
#include <stdint.h>
typedef int16_t  spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t  spx_int32_t;
typedef uint32_t spx_uint32_t;
#define OUTSIDE_SPEEX 1
#define FLOATING_POINT 1
#define USE_KISS_FFT 1
#define EXPORT
#endif
