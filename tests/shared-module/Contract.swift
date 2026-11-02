import Foundation
#if SHARED_MODULE_CLIENT
import TodayShared
#endif

// Compile this same client with baseline sources, then against the real public module.
// The baseline writes disk artifacts; the module must read and re-encode their format unchanged.
@main
struct Contract {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_792_152_000)
        let id = UUID(uuidString: "EC4127A0-103C-4FCB-AB50-AFB72623C593")!
        let reminder = SharedReminder(id: id, title: "Shared title", note: "Line 1\nLine 2", due: date, sharedAt: date)
        let item = WidgetItem(id: "event#1792152000", title: "Meeting", start: date, end: date.addingTimeInterval(3600),
                              kind: .event, externalID: "EK:original", travelMinutes: 18, leaveBy: date.addingTimeInterval(-1080))
        let snapshot = WidgetSnapshot(generatedAt: date, items: [item],
                                      calendar: .init(isOn: true, hiddenCalendarIDs: ["hidden-original"]))
        let shareURL = folder.appendingPathComponent(ShareInbox.fileName)
        let widgetURL = folder.appendingPathComponent(WidgetSnapshot.fileName)
        let outbox = folder.appendingPathComponent(ActivityOutbox.folderName, isDirectory: true)
        if mode == "write" {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try require(ShareInbox.append(reminder, at: shareURL), "baseline inbox append")
            try snapshot.encoded().write(to: widgetURL)
            try require(ActivityOutbox.append(kind: "share.add", actor: "share", channel: "share", props: ["count": 1],
                                              at: date, in: outbox), "baseline outbox append")
            print("PASS baseline disk writer")
            return
        }
        try require(WidgetSnapshot.appGroup == "group.com.luworks.today", "App Group identity")
        try require(WidgetSnapshot.days == 3 && ActivityOutbox.maxFiles == 500, "format limits")
        let shareData = try Data(contentsOf: shareURL)
        let read = try ShareInbox.read(at: shareURL)
        try require(read == [reminder], "share UUID, fields and dates")
        let reencoded = ShareInbox.encode(read)!
        // Inbox JSON has no sorted-key guarantee; compare its JSON value rather than key ordering.
        let oldJSON = try JSONSerialization.jsonObject(with: shareData) as! NSArray
        let newJSON = try JSONSerialization.jsonObject(with: reencoded) as! NSArray
        try require(oldJSON == newJSON, "share Codable keys")
        let widgetData = try Data(contentsOf: widgetURL)
        let decoded = WidgetSnapshot.decode(widgetData)!
        try require(decoded == snapshot, "widget fields, IDs and dates")
        try require(try decoded.encoded() == widgetData, "sorted widget bytes")
        let oldWidget = Data("{\"generatedAt\":\"2026-10-16T12:00:00Z\",\"items\":[{\"id\":\"legacy\",\"title\":\"Old\",\"start\":\"2026-10-16T12:00:00Z\",\"isAllDay\":false,\"kind\":\"reminder\"}]}".utf8)
        let legacy = WidgetSnapshot.decode(oldWidget)
        try require(legacy != nil && legacy?.items.first?.id == "legacy", "legacy snapshot decodes")
        try require(legacy?.items.first?.externalID == nil, "legacy optional keys")
        try require(legacy?.calendar == nil, "legacy calendar key")
        let files = ActivityOutbox.pendingFiles(in: outbox)
        try require(files.count == 1 && files[0].lastPathComponent.hasPrefix("1792152000000-"), "outbox path")
        let line = try Data(contentsOf: files[0])
        let event = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        try require(line.last == 10, "JSONL newline")
        try require(Set(event.keys) == Set(["uid", "ts", "tz", "day", "tier", "kind", "actor", "v", "props", "channel"]), "JSONL keys")
        try require(UUID(uuidString: event["uid"] as! String) != nil && event["ts"] as? Int64 == 1_792_152_000_000, "outbox ID and timestamp")
        try require(event["kind"] as? String == "share.add", "outbox kind")

        // These calls intentionally use no @testable import: integration consumers need these constructors/members.
        var next = NextUp(today: [item], remainingToday: 1, tomorrow: nil)
        next.today[0].travelMinutes = 20
        _ = NextUpSpeech.line(next, now: date)
        _ = LockScreenNext.make(items: decoded.items, now: date, time: { _ in "12:00" })
        var lock = LockScreenNext(headline: "Now", showsAlarmSymbol: false, lead: .text("until 13:00"),
                                  title: "Meeting", more: nil, isEmpty: false, accessibilityLabel: "Meeting")
        lock.lead = .countdown(to: date)
        _ = lock.accessibilityLabel
        _ = TravelPlace(address: "Office", latitude: 1, longitude: 2)
        _ = TravelTime.usable(TravelEstimate(seconds: 1080, computedAt: date))
        _ = ShareInbox.Day.today.id
        _ = SharedReminder(title: "Default values")
        _ = ShareImport.Result(added: [id], acknowledged: false).acknowledged
        _ = WidgetLink.day(from: WidgetLink.url(day: date), now: date)
        try require(NextItems.select(from: decoded.items, now: date).remainingToday == 1, "widget selection")
        print("PASS public module reader: legacy Codable, paths, IDs, JSONL and consumer constructors")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: message, code: 1) }
    }
}
