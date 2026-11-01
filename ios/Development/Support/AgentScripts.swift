#if TODAY_MOCK
  import FeatureAsk
  import TodayCore

  /// Scripted agent runs for TodayMock and UI tests (`-uiTestingAgentScript <name>`), in place of the
  /// Luna Worker. Without the argument TodayMock is "not signed in": Ask uses FastLane alone (§4.7 #3).
  /// Each script plays its steps in order across the app's runs; a run with no step left fails as
  /// `incomplete`, which Ask treats like any other failure (rules, else "AI 暂时不可用").
  enum AgentScripts {
    typealias Call = ScriptedModelClient.Call

    static func model(_ name: String?) -> AgentModel {
      guard let name, let steps = steps(name) else { return .unavailable }
      return .scripted(steps)
    }

    static func steps(_ name: String) -> [ScriptedModelClient.Step]? {
      switch name {
      // A plain answer, no cards.
      case "reply":
        return [ScriptedModelClient.reply("This is a scripted answer. Nothing was changed.")]
      // Signed in, but the request fails: the rules take over.
      case "offline":
        return [.fail(.network), .fail(.network), .fail(.network)]
      // "Move the dentist to 5pm" on the sample data: look it up, then one change card.
      case "move-dentist":
        return [
          ScriptedModelClient.calls([Call("find_items", ["query": "Dentist"], id: "c1")]),
          ScriptedModelClient.calls([
            Call("propose_edit", ["id": "t1", "when_text": "5pm"], id: "c2")
          ]),
          ScriptedModelClient.reply("Here's the change. Nothing changes until you apply it."),
        ]
      default:
        return nil
      }
    }
  }
#endif
