import Foundation

/// The Cursor plan's usage, beside Claude's limits in the sidebar footer.
///
/// Cursor counts two things: the weekly pool the plan includes, which a few
/// of its models draw on, and every other model, which does not.
/// The editor buries both in its settings. This asks the same dashboard
/// service the editor asks, signed in as the editor is, and the answer costs
/// nothing — so unlike Claude's API reading it simply runs every two minutes.
final class CursorUsageStore: ObservableObject {
    @Published private(set) var planName: String?
    /// The weekly pool the plan includes.
    @Published private(set) var included: UsageWindow?
    /// Everything outside it.
    @Published private(set) var other: UsageWindow?
    @Published private(set) var updated: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var problem: String?

    /// Whether this Mac has Cursor at all. Without it the footer stays
    /// Claude's alone.
    let isAvailable = CursorAgent.isInstalled
        || FileManager.default.fileExists(atPath: CursorAgent.stateDatabase.path)

    /// The models the weekly pool covers. Cursor's `/model` lists every model
    /// it has, so the footer says which of them cost nothing extra.
    static let includedModels = "Grok 4.7 · 4.6 · 4.5 · Composer 2.5"

    private var timer: Timer?
    private let interval: TimeInterval = 120

    func start() {
        guard isAvailable, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// Also reads the editor's token again, which is what a Cursor chat
    /// starts with — so it stays as fresh as the editor keeps it.
    func refresh() {
        guard isAvailable, !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .utility).async {
            let outcome = Self.read()
            DispatchQueue.main.async {
                self.isBusy = false
                switch outcome {
                case .success(let reading):
                    self.planName = reading.plan
                    self.included = reading.included
                    self.other = reading.other
                    self.updated = Date()
                    self.problem = nil
                case .failure(let failure):
                    self.problem = failure.message
                }
            }
        }
    }

    /// For the footer: the included pool in the first row, the rest in the
    /// second.
    var readout: UsageReadout {
        UsageReadout(session: included,
                     week: other,
                     account: planName.map { "Cursor \($0)" } ?? "Cursor",
                     problem: problem,
                     isBusy: isBusy,
                     updated: updated)
    }

    // MARK: - Reading

    private struct Reading {
        let plan: String?
        let included: UsageWindow?
        let other: UsageWindow?
    }

    private struct Failure: Error {
        let message: String
    }

    private static func read() -> Result<Reading, Failure> {
        guard let token = CursorAgent.readToken() else {
            return .failure(Failure(message: "Cursor is not signed in on this Mac. Sign in to the Cursor editor, then try again."))
        }
        let plan: [String: Any]
        let usage: [String: Any]
        switch (post("GetPlanInfo", token: token), post("GetCurrentPeriodUsage", token: token)) {
        case (.success(let p), .success(let u)):
            plan = p
            usage = u
        case (.failure(let failure), _), (_, .failure(let failure)):
            return .failure(failure)
        }

        let info = plan["planInfo"] as? [String: Any]
        let pools = usage["planUsage"] as? [String: Any]
        let resets = number(info?["includedUsageResetsAt"]) ?? number(usage["billingCycleEnd"])
        let resetsAt = resets.map { Date(timeIntervalSince1970: $0 / 1000) }
        let included = percent(pools?["autoPercentUsed"]) ?? percent(pools?["totalPercentUsed"])
        return .success(Reading(
            plan: (info?["planName"] as? String)?.nonEmpty,
            included: included.map { UsageWindow(percent: $0, resets: "", resetsAt: resetsAt) },
            other: UsageWindow(percent: percent(pools?["apiPercentUsed"]) ?? 0,
                               resets: "outside the pool",
                               resetsAt: nil)
        ))
    }

    /// One call to Cursor's dashboard service, waited for: this already runs
    /// on a background queue, and the two calls are cheap.
    private static func post(_ method: String, token: String) -> Result<[String: Any], Failure> {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        var result: Result<[String: Any], Failure> = .failure(Failure(message: "Cursor did not answer."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                result = .failure(Failure(message: "Could not reach Cursor: \(error.localizedDescription)"))
            } else if status == 401 || status == 403 {
                result = .failure(Failure(message: "Cursor's sign-in has run out. Open the Cursor editor to renew it."))
            } else if !(200..<300).contains(status) {
                result = .failure(Failure(message: "Cursor answered \(status) to \(method)."))
            } else if let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = .success(object)
            } else {
                result = .failure(Failure(message: "Cursor's answer to \(method) could not be read."))
            }
        }.resume()
        done.wait()
        return result
    }

    /// 0–100, whole: a pool overdrawn by a little is full, not 103%.
    private static func percent(_ value: Any?) -> Int? {
        number(value).map { min(100, max(0, Int($0.rounded()))) }
    }

    /// Cursor sends its numbers as numbers, and its timestamps as strings.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}
