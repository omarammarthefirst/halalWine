import Foundation

/// Turns an inspection report into an ordered list of launch configurations.
public struct LaunchPlanner: Sendable {
    public var rules: RuleSet

    public init(rules: RuleSet) {
        self.rules = rules
    }

    public func plan(for report: GameReport,
                     available: Set<GraphicsBackend>,
                     history: LaunchHistory = LaunchHistory()) -> LaunchPlan {
        let rule = rules.rule(for: report)
        let steps = rule?.steps ?? [RuleSet.Step(id: "fallback-wined3d", backend: .wined3d)]
        var ordered = steps.map {
            LaunchConfig(stepID: $0.id, backend: $0.backend, arguments: $0.arguments ?? [], environment: $0.environment ?? [:])
        }

        // What worked last time goes first; what failed goes last.
        if let working = history.working {
            ordered.removeAll { $0.key == working.key }
            ordered.insert(working, at: 0)
        }
        let failed = Set(history.failedKeys)
        let fresh = ordered.filter { !failed.contains($0.key) }
        let stale = ordered.filter { failed.contains($0.key) }
        ordered = fresh + stale

        var seen = Set<String>()
        ordered = ordered.filter { seen.insert($0.key).inserted }

        return LaunchPlan(
            ruleID: rule?.id ?? "fallback",
            configs: ordered.filter { available.contains($0.backend) },
            unavailable: ordered.filter { !available.contains($0.backend) },
            windowedArguments: rule?.windowedArguments ?? []
        )
    }
}
