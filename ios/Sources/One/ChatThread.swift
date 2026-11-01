#if os(iOS)
  import TodayCore
  import TodayShared
  import TodayData
  import TodayPlatform
  import Foundation
  import SwiftData

  /// A saved conversation with the AI: role + text per message, and the preview cards that were decided (added, dropped,
  /// undone; see `StoredCard`) under the message they belong to. A card still waiting for Add is not restored; plan and
  /// change cards are not kept. Reopening a chat shows what was said and lets you continue it.
  @Model
  package final class ChatThread {
    package var id: UUID = UUID()
    /// The first user message, tidied (see `ConversationHistory.title`).
    package var title: String = ""
    package var createdAt: Date = Date.now
    /// When the last message was added; the sidebar sorts and groups by this.
    package var updatedAt: Date = Date.now
    /// JSON of `[ChatMessage]`. Kept as plain data so the stored shape never depends on a Swift type.
    package var messagesData: Data = Data()
    /// Archived conversations leave the main list and wait under "Archived" in the sidebar.
    package var archived: Bool = false
    /// The reminders, events and alarms this conversation added (JSON of their ids), so it can archive itself once they
    /// are all done (see `ChatAutoArchive`). Additive field: older stores get none.
    package var itemsData: Data = Data()

    /// JSON of `[StoredCard]`: the decided cards. Additive field: older conversations have none and show none.
    package var cardsData: Data = Data()

    /// The item attached to this conversation, independently of preview cards.
    package var subjectData: Data = Data()

    /// JSON of `AgentHistory`: the agent's replayable items with their `{model, tools_version, created}`
    /// metadata and short ids (docs/engineering/ai-agent-architecture.md §1.5). Additive field: older
    /// conversations have none, and the agent starts their history from the chat text.
    @Attribute(.externalStorage) package var agentItemsData: Data = Data()

    package var subject: AskSubject? {
      get { try? JSONDecoder().decode(AskSubject.self, from: subjectData) }
      set { subjectData = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data() }
    }

    package var cards: [StoredCard] {
      get { StoredCard.restore(cardsData) }
      set { cardsData = StoredCard.encode(newValue) }
    }

    package var items: [PersistentIdentifier] {
      get { (try? JSONDecoder().decode([PersistentIdentifier].self, from: itemsData)) ?? [] }
      set { itemsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    package init(
      title: String, messages: [ChatMessage], createdAt: Date = .now, updatedAt: Date = .now,
      id: UUID = UUID()
    ) {
      self.id = id
      self.title = title
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.messagesData = Self.encode(messages)
    }

    package var messages: [ChatMessage] {
      get {
        var restored = (try? JSONDecoder().decode([ChatMessage].self, from: messagesData)) ?? []
        // Legacy chats have no per-turn clock. Only the first request has a reliable
        // thread-creation anchor; never assign the reopening time to older messages.
        if let first = restored.firstIndex(where: { $0.role == .user }),
          restored[first].timestamp == nil
        {
          restored[first].timestamp = createdAt
        }
        return restored
      }
      set { messagesData = Self.encode(newValue) }
    }

    private static func encode(_ messages: [ChatMessage]) -> Data {
      (try? JSONEncoder().encode(messages)) ?? Data()
    }

    /// An unsaved copy with the same content, used to put a deleted conversation back (Undo).
    package func copy() -> ChatThread {
      let c = ChatThread(
        title: title, messages: [], createdAt: createdAt, updatedAt: updatedAt, id: id)
      c.messagesData = messagesData
      c.archived = archived
      c.itemsData = itemsData
      c.cardsData = cardsData
      c.subjectData = subjectData
      c.agentItemsData = agentItemsData
      return c
    }
  }
#endif
