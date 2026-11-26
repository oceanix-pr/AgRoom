import Foundation

/// Bundled task examples use the same package store and sandboxed runner as user skills.
public enum SkillTaskTemplate: String, CaseIterable, Sendable, Identifiable {
    case csvQuality = "csv-quality"
    case actionChecklist = "action-checklist"
    public var id: String { rawValue }
    public var titleKey: String { "scenario.skill.\(rawValue).title" }
    public var summaryKey: String { "scenario.skill.\(rawValue).summary" }
    public var criteriaKey: String { "scenario.skill.\(rawValue).criteria" }
    public var sampleFile: String { self == .csvQuality ? "sample.csv" : "sample.json" }
    public var sampleInput: String {
        switch self {
        case .csvQuality: "name,owner,status\nLaunch,Lin,open\nReport,,open\nLaunch,Lin,open\n"
        case .actionChecklist: #"{"actions":[{"task":"Confirm launch date","owner":"Lin","due":"2026-11-06"},{"task":"Send report","owner":"","due":""}]}"#
        }
    }
    public var expectedOutput: String {
        switch self {
        case .csvQuality: #"{"columns":["name","owner","status"],"row_count":3,"duplicate_rows":1,"missing_by_column":{"name":0,"owner":1,"status":0},"malformed_rows":[]}"#
        case .actionChecklist: #"{"action_count":2,"ready_count":1,"issues":[{"row":2,"field":"owner","reason":"missing"},{"row":2,"field":"due","reason":"missing"}]}"#
        }
    }
    public var instructions: String {
        """
        Use this skill to \(self == .csvQuality ? "inspect a CSV table for missing values, duplicate rows and malformed records" : "check a structured meeting action list for missing owners, deadlines and invalid dates").
        1. Review references/\(sampleFile) and references/expected.json for the input format and sample acceptance result.
        2. Run scripts/main.py with no arguments for the bundled sample. It compares its computed report against expected.json and fails on a mismatch.
        3. For real work, obtain the user's input file through the current conversation's normal file access. Pass --input followed by that file path. Never fabricate a missing owner, deadline, row or status. Do not claim the sample check validates the user's data.
        4. Read the actual scratch/report.json receipt and explain its findings. Missing fields are issues, not inferred facts. The report's row numbers start at 1 after the CSV header or in the actions array.
        All files and script execution remain subject to the host's current space, directory and approval policies. This package requests no new authority, network, dependencies or external changes.
        """
    }
    public func install(in store: SkillStore, alias: String, description: String) throws -> String {
        let skill = Skill(name: "task-" + rawValue, alias: alias, description: description, content: instructions,
            allowedTools: "skill_run_script,skill_file,files_read", outputs: ["scratch/report.json"],
            outputRequiredFields: self == .csvQuality ? ["columns", "row_count", "duplicate_rows", "missing_by_column", "malformed_rows"] : ["action_count", "ready_count", "issues"])
        return try store.installPackage(skill, scripts: [("scripts/main.py", script)],
            references: [("references/" + sampleFile, sampleInput), ("references/expected.json", expectedOutput)], overwrite: false)
    }
    public func matchesSampleOutput(_ output: String) -> Bool {
        guard let line = output.components(separatedBy: .newlines).first,
              let actual = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary,
              let expected = try? JSONSerialization.jsonObject(with: Data(expectedOutput.utf8)) as? NSDictionary else { return false }
        return actual == expected
    }
    public var script: String {
        let algorithm: String
        switch self {
        case .csvQuality:
            algorithm = #"""
            import csv
            import io

            def analyze(text):
                rows = list(csv.reader(io.StringIO(text)))
                if not rows or not rows[0] or len(rows) > 10001:
                    raise ValueError('Expected a header and at most 10000 data rows')
                columns = rows[0]
                if len(columns) > 256 or any(not name.strip() for name in columns) or len(set(columns)) != len(columns):
                    raise ValueError('Use at most 256 unique nonempty column names')
                missing = dict.fromkeys(columns, 0)
                malformed, seen, duplicates = [], set(), 0
                for index, row in enumerate(rows[1:], 1):
                    if len(row) != len(columns):
                        malformed.append(index)
                        continue
                    key = tuple(row)
                    duplicates += key in seen
                    seen.add(key)
                    for name, value in zip(columns, row):
                        missing[name] += not value.strip()
                return {'columns': columns, 'row_count': len(rows)-1, 'duplicate_rows': duplicates,
                        'missing_by_column': missing, 'malformed_rows': malformed}
            """#
        case .actionChecklist:
            algorithm = #"""
            from datetime import date

            def analyze(text):
                obj = json.loads(text)
                actions = obj.get('actions') if isinstance(obj, dict) else None
                if not isinstance(actions, list) or len(actions) > 10000:
                    raise ValueError('Expected an actions array with at most 10000 entries')
                issues, ready = [], 0
                for index, action in enumerate(actions, 1):
                    before = len(issues)
                    if not isinstance(action, dict):
                        issues.append({'row': index, 'field': 'action', 'reason': 'invalid_object'})
                        continue
                    for field in ('task', 'owner', 'due'):
                        value = action.get(field)
                        if not isinstance(value, str) or not value.strip():
                            issues.append({'row': index, 'field': field, 'reason': 'missing'})
                        elif field == 'due':
                            try:
                                if len(value) != 10:
                                    raise ValueError('Use YYYY-MM-DD')
                                date.fromisoformat(value)
                            except ValueError:
                                issues.append({'row': index, 'field': field, 'reason': 'invalid_date'})
                    ready += before == len(issues)
                return {'action_count': len(actions), 'ready_count': ready, 'issues': issues}
            """#
        }
        return "import argparse\nimport json\nfrom pathlib import Path\n\n" + algorithm + "\n\n" + #"""
        parser = argparse.ArgumentParser()
        parser.add_argument('--input', help='Approved input file; omit to verify the bundled example')
        args = parser.parse_args()
        root = Path(__file__).resolve().parent.parent
        source = Path(args.input) if args.input else root / 'references' / '\#(sampleFile)'
        if source.stat().st_size > 2000000:
            raise ValueError('Input exceeds 2 MB')
        report = analyze(source.read_text(encoding='utf-8-sig'))
        if not args.input:
            expected = json.loads((root / 'references' / 'expected.json').read_text(encoding='utf-8'))
            if report != expected:
                raise RuntimeError('Bundled example did not match its acceptance result')
        target = root / 'scratch' / 'report.json'
        target.parent.mkdir(exist_ok=True)
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report, ensure_ascii=False))
        """#
    }
}
