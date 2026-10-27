import Foundation
import Testing
@testable import ZMeetCore

/// Feeds SSE text to a fresh accumulator, one line at a time.
private func accumulate(_ sse: String) throws -> AnthropicStream {
    var stream = AnthropicStream()
    for line in sse.components(separatedBy: "\n") { try stream.consume(line: line) }
    return stream
}

private let thinkingThenText = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","usage":{"input_tokens":10,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"## Summary\\n"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Shipped."}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5100}}

event: message_stop
data: {"type":"message_stop"}
"""

@Test func streamJoinsTextAndSkipsThinking() throws {
    let stream = try accumulate(thinkingThenText)
    #expect(try stream.result() == "## Summary\nShipped.")
    #expect(stream.stopReason == "end_turn")
    #expect(stream.outputTokens == 5100)
}

@Test func streamCutOffAtTheTokenLimitIsAnError() throws {
    // A fact list cut off at max_tokens would silently drop the end of the
    // meeting; failing lets the policy retry and then fall back honestly.
    let stream = try accumulate("""
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"FACT [0:05] a"}}
    data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":64000}}
    """)
    #expect(throws: AIProviderError.decode) { try stream.result() }
}

@Test func streamWithNoTextIsADecodeError() throws {
    let stream = try accumulate("""
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}
    data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":64000}}
    """)
    #expect(stream.stopReason == "max_tokens")
    #expect(throws: AIProviderError.decode) { try stream.result() }
}

@Test func streamErrorEventThrows() {
    #expect(throws: AIProviderError.http(status: 529)) {
        _ = try accumulate(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
    }
    #expect(throws: AIProviderError.http(status: 500)) {
        _ = try accumulate(#"data: {"type":"error","error":{"type":"api_error","message":"boom"}}"#)
    }
}

@Test func streamIgnoresMalformedAndNonDataLines() throws {
    let stream = try accumulate("""
    : comment
    event: content_block_delta
    data: not json
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}
    """)
    #expect(try stream.result() == "ok")
}
