import Foundation
import Testing

@Suite("Regressions")
struct RegressionTests {
    @Test("Stop while a question waits for its early keyword search stops that search too")
    func earlyKeywordsStopWithTheQuestion() async {
        let started = Flag()
        // Stands in for the keyword search: runs until cancelled (or gives up after 5 seconds and says so).
        let keywords = Task<Bool, Never> {
            started.set()
            let deadline = Date().addingTimeInterval(5)
            while !Task.isCancelled && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            return Task.isCancelled
        }
        let question = Task { await keywords.valueStoppingWithCaller }
        _ = await eventually { started.isSet }
        try? await Task.sleep(for: .milliseconds(20))   // the question is waiting on it now
        let stopped = Date()
        question.cancel()
        let cancelled = await question.value
        #expect(cancelled, "the keyword search ran on after Stop")
        #expect(Date().timeIntervalSince(stopped) < 2)
    }
}

@Suite("Update failure messages")
struct UpdateFailureMessageTests {
    @Test("A different app or build and a bad signature read differently and carry their details")
    func distinctMessages() {
        let wrong = AppUpdater.describe(AppUpdater.UpdateError.wrongApp("expected com.example build 14, the download is com.example build 13"), checking: false)
        let unsigned = AppUpdater.describe(AppUpdater.UpdateError.unsigned("error -67050: requirement failed"), checking: false)
        #expect(wrong != unsigned)
        #expect(wrong.contains("build 13"))
        #expect(unsigned.contains("-67050"))
        #expect(!wrong.contains("signature"))
    }
}
