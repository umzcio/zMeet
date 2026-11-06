import Foundation
import Testing
@testable import ZMeetCore

// (An angle-bracket destination like [a](<https://…>) loses its link: the HTML
// tag rule escapes its "<" first. Inert is the safe direction.)
// A model can be steered (by speech or the meeting title) into writing links.
// Only web and mail links may stay live in a note; anything else would hand a
// click to whatever app owns the scheme (smb mounts, Terminal via ssh, deep links).

@Test func webAndMailLinksStayLive() {
    for link in ["[site](https://e.com/a?b=1&c=2)", "[x](http://e.com)", "[X](HTTPS://E.COM)",
                 "[mail](mailto:a@b.com)", "[w](https://en.wikipedia.org/wiki/Foo_(bar))"] {
        #expect(ZMeetText.sanitizeNoteMarkdown(link) == link, "changed: \(link)")
    }
}

@Test func otherSchemesBecomePlainText() {
    let cases = [
        "[Slides](smb://attacker/share)": "Slides",
        "[Open](file:///Applications/Utilities/Terminal.app)": "Open",
        "[Join](zoommtg://zoom.us/join?confno=1)": "Join",
        "[Login](ssh://x@h)": "Login",
        "[Code](vscode://file/etc/passwd)": "Code",
        "[Run](javascript:alert(1))": "Run)",
        "[Rel](notes.md)": "Rel",
        "[Angle](<smb://h/s>)": "Angle",
        "[Entity](&#115;mb://h/s)": "Entity",
        "[Escaped](\\smb://h/s)": "Escaped",
        "[Titled](smb://h/s \"Slides\")": "Titled",
        "[Spaced]( smb://h/s )": "Spaced",
    ]
    for (input, expected) in cases {
        #expect(ZMeetText.sanitizeNoteMarkdown(input) == expected, "\(input)")
    }
}

@Test func unsafeReferenceDefinitionsAreDefanged() {
    let md = "See [the slides][s] and [the site][w].\n\n[s]: smb://attacker/share\n  [w]: https://e.com"
    let out = ZMeetText.sanitizeNoteMarkdown(md)
    #expect(!out.contains("\n[s]: smb"))
    #expect(out.contains("\\[s]: smb://attacker/share"))
    #expect(out.contains("  [w]: https://e.com"))
}

@Test func linksInsideProseAreHandledInPlace() {
    #expect(ZMeetText.sanitizeNoteMarkdown("- Deck: [Slides](smb://h/s), site: [E](https://e.com).")
            == "- Deck: Slides, site: [E](https://e.com).")
}

@Test func titlesCannotCarryLiveLinksEither() {
    #expect(ZMeetText.sanitizeTitle("Weekly Call [join](zoommtg://x)") == "Weekly Call join")
}

@Test func onlyWebAndMailLinksAreOpenable() {
    for s in ["https://e.com", "http://e.com", "mailto:a@b.com", "HTTPS://E.COM"] {
        #expect(ZMeetText.isOpenableNoteLink(URL(string: s)!), "\(s)")
    }
    for s in ["smb://h/s", "file:///etc/passwd", "zoommtg://x", "ssh://h", "vscode://x", "notes.md", "x-apple.systempreferences:x"] {
        #expect(!ZMeetText.isOpenableNoteLink(URL(string: s)!), "\(s)")
    }
}
