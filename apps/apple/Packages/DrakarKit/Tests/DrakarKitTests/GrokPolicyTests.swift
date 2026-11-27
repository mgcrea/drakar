import DrakarKit
import Testing

@Suite("Grok permission policy")
struct GrokPolicyTests {
  @Test func offersAskPlanAndBypassWhenAllowed() {
    #expect(GrokPolicy.offeredModes(allowsBypass: false) == [.ask, .plan])
    #expect(GrokPolicy.offeredModes(allowsBypass: true) == [.ask, .plan, .bypass])
  }

  @Test func mapsBetweenDrakarAndGrokWireModes() {
    #expect(GrokPolicy.modeID(.ask) == "default")
    #expect(GrokPolicy.modeID(.plan) == "plan")
    #expect(GrokPolicy.modeID(.bypass) == "default")

    #expect(GrokPolicy.permissionMode(from: "default") == .ask)
    #expect(GrokPolicy.permissionMode(from: "ask") == .ask)
    #expect(GrokPolicy.permissionMode(from: "agent") == .ask)
    #expect(GrokPolicy.permissionMode(from: "plan") == .plan)
    #expect(GrokPolicy.permissionMode(from: "auto") == nil)
    #expect(GrokPolicy.permissionMode(from: "unknown") == nil)
  }
}
