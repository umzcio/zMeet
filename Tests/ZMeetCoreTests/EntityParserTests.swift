import Testing
@testable import ZMeetCore

@Test func entityParserParsesLabeledLines() {
    let e = EntityParser.parse("PEOPLE: Jonathan, Keiko\nPROJECTS: Japan Trip\nTOPICS: flights, budget")
    #expect(e.people == ["Jonathan", "Keiko"])
    #expect(e.projects == ["Japan Trip"])
    #expect(e.topics == ["flights", "budget"])
}

@Test func entityParserIgnoresNoneEmptiesDupesAndProse() {
    let e = EntityParser.parse("blah blah\nPeople: Sam, sam, , None\nTopics: none\nProjects:")
    #expect(e.people == ["Sam"])        // case-insensitive dedupe, drops blank + "none"
    #expect(e.topics == [])
    #expect(e.projects == [])
    #expect(e.isEmpty == false)
}

@Test func entityParserEmptyForNoLabels() {
    #expect(EntityParser.parse("nothing structured here").isEmpty)
}
