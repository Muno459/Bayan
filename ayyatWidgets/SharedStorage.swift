import Foundation

/// Shared App Group container — both the app and the widgets read/write here.
/// The app populates these keys when the data is fresh (Daily Ayah fetch,
/// streak update, session end); the widget timeline simply reads them.
enum AyyatSharedStorage {
    static let appGroup = "group.com.mostafamahdi.ayyat"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    // MARK: - Keys

    enum Key {
        static let dailyAyahVerseKey = "shared.daily.verseKey"
        static let dailyAyahArabic   = "shared.daily.arabic"
        static let dailyAyahEnglish  = "shared.daily.english"
        static let dailyAyahDate     = "shared.daily.date"

        static let streakDays         = "shared.streak.days"
        static let streakLastDate     = "shared.streak.lastDate"

        static let goalTarget        = "shared.goal.target"
        static let goalVersesToday   = "shared.goal.versesToday"
    }

    // MARK: - Daily ayah

    struct DailyAyah {
        let verseKey: String
        let arabic: String
        let english: String
    }

    static func writeDailyAyah(verseKey: String, arabic: String, english: String) {
        let d = defaults
        d.set(verseKey, forKey: Key.dailyAyahVerseKey)
        d.set(arabic, forKey: Key.dailyAyahArabic)
        d.set(english, forKey: Key.dailyAyahEnglish)
        d.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: Key.dailyAyahDate)
    }

    static func readDailyAyah() -> DailyAyah? {
        let d = defaults
        guard let key = d.string(forKey: Key.dailyAyahVerseKey),
              let ar  = d.string(forKey: Key.dailyAyahArabic)
        else { return nil }
        return DailyAyah(
            verseKey: key,
            arabic: ar,
            english: d.string(forKey: Key.dailyAyahEnglish) ?? ""
        )
    }

    // MARK: - Streak

    static func writeStreak(days: Int, lastDate: Date?) {
        let d = defaults
        d.set(days, forKey: Key.streakDays)
        if let lastDate { d.set(lastDate.timeIntervalSince1970, forKey: Key.streakLastDate) }
    }

    static func readStreakDays() -> Int {
        defaults.integer(forKey: Key.streakDays)
    }

    // MARK: - Goal

    static func writeGoal(target: Int, versesToday: Int) {
        let d = defaults
        d.set(target, forKey: Key.goalTarget)
        d.set(versesToday, forKey: Key.goalVersesToday)
    }

    static func readGoal() -> (target: Int, versesToday: Int) {
        let d = defaults
        return (d.integer(forKey: Key.goalTarget), d.integer(forKey: Key.goalVersesToday))
    }
}
