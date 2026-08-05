# Third-Party Notices

zMeet vendors the following third-party code, compiled into the app. Each
component's license requires reproduction of its copyright notice and
conditions in binary distributions; the canonical license text is retained in
the header of every vendored source file under `Sources/CSpeexDSP/`.

## SpeexDSP (echo canceller / preprocessor)

- Upstream: https://gitlab.xiph.org/xiph/speexdsp
- Files: `Sources/CSpeexDSP/` (mdf.c, preprocess.c, fftwrap.c, filterbank.c,
  and associated headers)
- Copyright (C) 2003-2008 Jean-Marc Valin / Xiph.Org Foundation

## KISS FFT (bundled within SpeexDSP)

- Files: `Sources/CSpeexDSP/kiss_fft.c`, `kiss_fftr.c`, `_kiss_fft_guts.h`,
  and associated headers
- Copyright (c) 2003-2004 Mark Borgerding; Copyright (c) 2005-2007 Jean-Marc Valin

## License (BSD 3-Clause, applies to both components above)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. The name of the author may not be used to endorse or promote products
   derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
