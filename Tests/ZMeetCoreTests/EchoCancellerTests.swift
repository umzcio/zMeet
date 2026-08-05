import Testing
import Foundation
@testable import ZMeetCore

@Test func cancelsASyntheticEcho() {
    let frame = 160, tail = 1600
    let aec = EchoCanceller(frameSize: frame, filterLength: tail)
    let delay = 320  // 20 ms echo delay
    var farHistory = [Int16](repeating: 0, count: delay)
    var phase = 0.0
    var echoEnergy = 0.0, residual = 0.0
    let frames = 300
    for fi in 0..<frames {
        var far = [Int16](repeating: 0, count: frame)
        var near = [Int16](repeating: 0, count: frame)
        for i in 0..<frame {
            phase += 0.06
            let s = Int16(8000 * sin(phase))                 // "remote" far-end audio
            far[i] = s
            farHistory.append(s)
            near[i] = Int16(Double(farHistory[farHistory.count - 1 - delay]) * 0.5)  // delayed echo only
        }
        let out = aec.cancel(near: near, far: far)
        // Measure only the final second (after the adaptive filter has converged).
        if fi >= frames - 100 {
            for i in 0..<frame {
                echoEnergy += Double(near[i]) * Double(near[i])
                residual += Double(out[i]) * Double(out[i])
            }
        }
    }
    // Converged residual echo should be far below the input echo (well over 6 dB).
    #expect(residual < echoEnergy * 0.25)
}

@Test func preservesLocalSpeechWhenNoFarEnd() {
    let aec = EchoCanceller(frameSize: 160, filterLength: 1600)
    var kept = 0.0, total = 0.0
    var phase = 0.0
    for _ in 0..<60 {
        var near = [Int16](repeating: 0, count: 160)
        let far = [Int16](repeating: 0, count: 160)   // silent far-end → nothing to cancel
        for i in 0..<160 { phase += 0.1; near[i] = Int16(6000 * sin(phase)) }
        let out = aec.cancel(near: near, far: far)
        for i in 0..<160 { total += Double(near[i]) * Double(near[i]); kept += Double(out[i]) * Double(out[i]) }
    }
    #expect(kept > total * 0.4)   // your voice survives (preprocessor may apply some gain)
}
