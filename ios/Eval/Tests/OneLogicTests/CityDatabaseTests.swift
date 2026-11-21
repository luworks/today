import TodayTestSupport
import XCTest

@testable import TodayCore
@testable import TodayData

/// The bundled city list (ios/One/cities.json) and the pure logic around it: search, time zone to city, migration,
/// card colors, the sentence and the waves behind the graph.
final class CityDatabaseTests: XCTestCase {
  /// The real file, found from this test file's place in the repo (ios/Eval/Tests/OneLogicTests/).
  private static let db: CityDatabase = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "One/cities.json")
    return try! CityDatabase.decode(Data(contentsOf: url))
  }()
  private var db: CityDatabase { Self.db }

  private func first(_ query: String) -> CityRecord? { db.search(query).first }

  // MARK: The data

  func testEveryCityHasATimeZoneThisSystemKnows() {
    let bad = db.cities.filter { TimeZone(identifier: $0.tz) == nil }.map { "\($0.name) \($0.tz)" }
    XCTAssertEqual(bad, [])
  }

  // MARK: Search

  func testSearchFindsBeijingInEnglishAndChinese() {
    XCTAssertEqual(first("Beijing")?.name, "Beijing")
    XCTAssertEqual(first("beijing")?.tz, "Asia/Shanghai")
    XCTAssertEqual(first("北京")?.name, "Beijing")
    XCTAssertEqual(first("上海")?.name, "Shanghai")
    XCTAssertEqual(first("东京")?.name, "Tokyo", "simplified")
    XCTAssertEqual(first("東京")?.name, "Tokyo", "traditional")
    XCTAssertEqual(first("紐約")?.name, "New York")
    XCTAssertEqual(
      first("纽约")?.name, "New York", "a traditional-only name is found by its simplified form")
  }

  func testSearchByCountryListsItsCities() {
    let china = db.search("china")
    XCTAssertGreaterThan(china.filter { $0.cc == "CN" }.count, 30)
    XCTAssertEqual(china.first?.name, "Beijing", "the capital first, then the biggest cities")
    XCTAssertTrue(china.prefix(5).contains { $0.name == "Shanghai" })
    let zh = db.search("中国")
    XCTAssertGreaterThan(zh.filter { $0.cc == "CN" }.count, 30)
    XCTAssertTrue(zh.prefix(10).contains { $0.name == "Beijing" })
    let japan = db.search("japan")
    XCTAssertTrue(
      japan.allSatisfy {
        $0.cc == "JP" || $0.name.lowercased().contains("japan")
          || $0.tz.lowercased().contains("japan")
      })
    XCTAssertEqual(japan.first?.name, "Tokyo")
  }

  func testSearchIgnoresCaseAndDiacritics() {
    XCTAssertEqual(first("SAO PAULO")?.name, "Sao Paulo")
    XCTAssertEqual(first("zurich")?.name, "Zurich")
    XCTAssertEqual(first("xian")?.name, "Xi’an", "apostrophes don't matter")
    XCTAssertEqual(first("Xi'an")?.name, "Xi’an")
    XCTAssertEqual(first("istanbul")?.name, "Istanbul")
    XCTAssertEqual(first("izmir")?.name, "İzmir")
    XCTAssertEqual(first("  new  york ")?.name, "New York", "spaces are trimmed and collapsed")
  }

  func testSearchRanksExactThenPrefixThenBiggerOrCapital() {
    XCTAssertEqual(first("london")?.cc, "GB", "London UK before London Canada")
    XCTAssertEqual(first("san jose")?.cc, "US")
    XCTAssertEqual(first("paris")?.name, "Paris")
    let par = db.search("par")
    XCTAssertTrue(
      par.first?.name.lowercased().hasPrefix("par") == true,
      "names starting with the query come first")
    XCTAssertTrue(par.prefix(5).contains { $0.name == "Paris" })
    let tokyo = db.search("tok")
    XCTAssertEqual(tokyo.first?.name, "Tokyo")
    XCTAssertEqual(db.search("Aba").first?.name, "Aba")
  }

  func testEmptySearchListsEverythingMostImportantFirst() {
    let all = db.search("  ")
    XCTAssertEqual(all.count, db.cities.count)
    XCTAssertTrue(all.prefix(40).contains { $0.name == "Beijing" })
    XCTAssertEqual(db.search("zzzz-nothing").count, 0)
  }

  func testSearchLimit() {
    XCTAssertEqual(db.search("a", limit: 5).count, 5)
  }

  func testDisplayNameFollowsTheInterfaceLanguage() throws {
    let beijing = try XCTUnwrap(db.cities.first { $0.name == "Beijing" })
    XCTAssertEqual(db.displayName(beijing, locale: Locale(identifier: "en_US")), "Beijing")
    XCTAssertEqual(db.displayName(beijing, locale: Locale(identifier: "zh_Hans_CN")), "北京")
    let ny = try XCTUnwrap(db.cities.first { $0.name == "New York" })
    XCTAssertEqual(db.displayName(ny, locale: Locale(identifier: "zh_Hans_CN")), "纽约")
    XCTAssertEqual(db.displayName(ny, locale: Locale(identifier: "zh_Hant_TW")), "紐約")
    XCTAssertEqual(
      CityDatabase.countryName("CN", locale: Locale(identifier: "en_US")).contains("China"), true)
  }

  // MARK: Time zone to city, saved list

  func testTheDeviceTimeZoneBecomesANamedCity() {
    XCTAssertEqual(db.city(forTimeZone: "America/Los_Angeles")?.name, "Los Angeles")
    XCTAssertEqual(
      db.city(forTimeZone: "Asia/Shanghai")?.name, "Shanghai",
      "named like the zone, or else the biggest")
    XCTAssertEqual(db.city(forTimeZone: "Europe/London")?.name, "London")
    XCTAssertEqual(db.city(forTimeZone: "Asia/Kolkata")?.name, "Kolkata")
    XCTAssertEqual(db.city(forTimeZone: "America/Chicago")?.tz, "America/Chicago")
    let chatham = db.city(forTimeZone: "Pacific/Chatham")
    XCTAssertEqual(chatham?.name, "Chatham", "a zone no listed city uses still gets a city")
    XCTAssertEqual(chatham?.key, "Pacific/Chatham")
    XCTAssertNil(db.city(forTimeZone: "Mars/Olympus_Mons"))
    XCTAssertNil(db.city(forTimeZone: "UTC"))
  }

  func testSavedListMigratesFromTimeZoneIdentifiers() throws {
    let tokyo = try XCTUnwrap(db.cities.first { $0.name == "Tokyo" })
    let migrated = db.migrate([
      "Europe/London", "Asia/Tokyo", "Mars/Olympus_Mons", "Europe/London", tokyo.key, "g99999999",
    ])
    XCTAssertEqual(migrated.count, 2, "unknown entries and duplicates are dropped")
    XCTAssertEqual(db.city(forKey: migrated[0])?.name, "London")
    XCTAssertEqual(migrated[1], tokyo.key, "Asia/Tokyo became the Tokyo card")
    XCTAssertEqual(db.migrate(nil), [])
    XCTAssertEqual(db.migrate([tokyo.key]), [tokyo.key], "already migrated: unchanged")
    let beijing = try XCTUnwrap(db.cities.first { $0.name == "Beijing" })
    XCTAssertEqual(
      db.migrate([beijing.key, "Asia/Shanghai"]),
      [beijing.key, db.city(forTimeZone: "Asia/Shanghai")!.key],
      "Beijing and Shanghai are two different cards in the same zone")
  }

  func testKeysResolveBack() throws {
    let beijing = try XCTUnwrap(db.cities.first { $0.name == "Beijing" })
    XCTAssertEqual(db.city(forKey: beijing.key), beijing)
    XCTAssertEqual(
      db.city(forKey: "Europe/London")?.name, "London", "an old identifier still opens a card")
    XCTAssertNil(db.city(forKey: "nonsense"))
  }
}

final class WorldClockLookTests: XCTestCase {
  private typealias Look = WorldClock.Look

  private func close(
    _ c: WorldClock.RGB, _ r: Double, _ g: Double, _ b: Double, _ tolerance: Double = 3,
    _ message: String = ""
  ) {
    XCTAssertEqual(c.r, r, accuracy: tolerance, "red " + message)
    XCTAssertEqual(c.g, g, accuracy: tolerance, "green " + message)
    XCTAssertEqual(c.b, b, accuracy: tolerance, "blue " + message)
  }

  func testWorkingHoursAreOneFlatGreen() {
    for (h, m) in [(9, 0), (9, 20), (11, 50), (17, 59)] {
      let c = Look.card(hour: h, minute: m)
      XCTAssertTrue(c.isGood, "\(h):\(m)")
      XCTAssertEqual(c.leading, Look.green)
      XCTAssertEqual(c.trailing, Look.green)
    }
    close(Look.green, 73, 162, 125)
    XCTAssertFalse(Look.card(hour: 8, minute: 59).isGood)
    XCTAssertFalse(Look.card(hour: 18, minute: 0).isGood)
  }

  func testMorningBrightensAndEveningDims() {
    XCTAssertLessThan(
      Look.card(hour: 4, minute: 0).leading.g, Look.card(hour: 6, minute: 0).leading.g)
    XCTAssertGreaterThan(
      Look.card(hour: 18, minute: 10).leading.g, Look.card(hour: 20, minute: 0).leading.g)
    let morning = Look.card(hour: 6, minute: 0)
    XCTAssertLessThan(morning.leading.g, morning.trailing.g, "morning: brighter to the right")
    let evening = Look.card(hour: 19, minute: 0)
    XCTAssertGreaterThan(evening.leading.g, evening.trailing.g, "evening: darker to the right")
  }

  func testColorIsDefinedAroundMidnight() {
    close(Look.card(hour: 0, minute: 0).leading, 26, 16, 59, 0.5)
    close(Look.card(hour: 23, minute: 59).trailing, 26, 16, 59, 0.5)
  }

  func testSentence() {
    let five = WorldClock.overlapSegments(
      cities: ["Dallas", "Boston", "Aba", "Beijing"], home: "San Jose", time: "04:50", offset: -300)
    XCTAssertEqual(
      five.map(\.text).joined(),
      "Overlap for Dallas, Boston, Aba and 1 more, when it was 04:50 in San Jose")
    XCTAssertEqual(
      five.filter(\.bold).map(\.text), ["Overlap", "Dallas, Boston, Aba", "04:50", "San Jose"],
      "names and time are bold")
    let now = WorldClock.overlapSegments(
      cities: ["Dallas"], home: "San Jose", time: "18:20", offset: 0)
    XCTAssertEqual(now.map(\.text).joined(), "Overlap for Dallas, when it is 18:20 in San Jose")
    let later = WorldClock.overlapSegments(
      cities: ["Dallas", "Boston"], home: "San Jose", time: "20:00", offset: 60)
    XCTAssertEqual(
      later.map(\.text).joined(), "Overlap for Dallas and Boston, when it will be 20:00 in San Jose"
    )
    let three = WorldClock.overlapSegments(
      cities: ["A", "B", "C"], home: "H", time: "1:00", offset: 0)
    XCTAssertEqual(three.map(\.text).joined(), "Overlap for A, B and C, when it is 1:00 in H")
    let none = WorldClock.overlapSegments(cities: [], home: "H", time: "1:00", offset: 0)
    XCTAssertEqual(none.count, 1)
  }

  func testWavesCountWhoIsWorking() throws {
    let tz = { TimeZone(identifier: $0)! }
    // 04:50 in Los Angeles on 2026-10-17 (PDT) = 11:50 UTC. Chicago, New York, Lagos, Shanghai, home Los Angeles.
    let start = Date(timeIntervalSince1970: 1_792_238_400 - 10 * 60)
    let zones = [
      tz("America/Los_Angeles"), tz("America/Chicago"), tz("America/New_York"), tz("Africa/Lagos"),
      tz("Asia/Shanghai"),
    ]
    let waves = WorldClock.waves(zones: zones, start: start, hours: 5, samples: 61)
    XCTAssertEqual(waves.count, 3)
    XCTAssertTrue(waves.allSatisfy { $0.count == 61 })
    let front = waves[0]
    XCTAssertEqual(front[0], 0.2, accuracy: 0.05, "only Lagos (12:50) works at the start")
    XCTAssertGreaterThan(
      front.last!, front[0],
      "New York (8:50 at the start), Chicago and Los Angeles join within five hours")
    XCTAssertTrue(waves.allSatisfy { $0.allSatisfy { (0...1).contains($0) } })
    for i in 0..<61 {
      XCTAssertGreaterThanOrEqual(waves[1][i], waves[0][i])
      XCTAssertGreaterThanOrEqual(waves[2][i], waves[1][i])
    }
    XCTAssertEqual(WorldClock.waves(zones: [], start: start)[0].count, 0)
  }

  func testWavesRollInsteadOfStepping() {
    let zones = [
      TimeZone(identifier: "America/Los_Angeles")!, TimeZone(identifier: "Europe/London")!,
    ]
    let waves = WorldClock.waves(
      zones: zones, start: Date(timeIntervalSince1970: 1_792_238_400), hours: 5, samples: 61)
    let steps = zip(waves[0], waves[0].dropFirst()).map { abs($1 - $0) }
    XCTAssertLessThan(
      steps.max() ?? 0, 0.15, "no jump bigger than a fraction of one city between samples")
  }
}
