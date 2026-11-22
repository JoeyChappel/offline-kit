import Foundation
import Testing

@Suite("Answer grounding")
struct AnswerGroundingTests {
    @Test("An answer that prints the instructions back is caught where the echo starts")
    func echoAtStart() {
        let answer = String(AskModel.instructions.prefix(400))
        #expect(AskModel.echoesInstructions(answer))
        #expect(AskModel.echoStart(answer) == answer.startIndex)
    }

    @Test("An echo after a real answer cuts at the start of its line")
    func echoLater() throws {
        let kept = "Bring clear water to a rolling boil for 1 minute [1].\nAbove 5,000 feet, boil it for 3 minutes [1]."
        let answer = kept + "\n- Stick to facts. Never guess at doses, wiring, gas or structural safety."
        let start = try #require(AskModel.echoStart(answer))
        #expect(String(answer[..<start]).trimmingCharacters(in: .whitespacesAndNewlines) == kept)
    }

    @Test("Sentences answers are told to write, and ordinary answers, aren't echoes")
    func allowed() {
        #expect(!AskModel.echoesInstructions("I couldn't find this in your offline library.\n\nNot from the library:\nBoil it for a minute."))
        #expect(!AskModel.echoesInstructions("I couldn’t find this in your offline library. Not from the library: rest."))
        #expect(!AskModel.echoesInstructions("1. Cool the burn [1].\n\nDouble-check the cited article and get professional help when it's available."))
        #expect(!AskModel.echoesInstructions("Double-check the cited article and get professional help when it is available."))
        #expect(!AskModel.echoesInstructions("Calm down, cool the burn under running water for twenty minutes and cover it [1]."))
        #expect(!AskModel.echoesInstructions(""))
    }

    @Test("The instructions give the safety line and the \"not in the library\" sentence word for word")
    func instructionsQuoteTheirSentences() {
        #expect(AskModel.instructions.contains("\"Double-check the cited article and get professional help when it's available.\""))
        #expect(AskModel.instructions.contains("\"I couldn't find this in your offline library.\""))
        #expect(AskModel.instructions.contains("Nothing under that heading carries a citation."))
    }
}
