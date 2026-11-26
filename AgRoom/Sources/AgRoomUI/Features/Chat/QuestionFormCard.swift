import SwiftUI
import AgRoomCore

// MARK: - Question Form Card

/// 结构化提问卡片：调度 Agent 经 ask_user 挂起时弹出，
/// 按字段类型渲染 GUI 控件（按钮/单选组/下拉/复选/文本/多行/日期），作答后恢复引擎。
/// 视觉语言与确认卡对齐（蓝色 = 需要输入，橙色 = 需要放行，绿色 = 建议沉淀）
struct QuestionFormCard: View {
    let form: QuestionForm
    let onAnswer: (QuestionFormAnswer) -> Void
    let onCancel: () -> Void
    var maxBodyHeight: CGFloat = 320
    @State private var bodyHeight: CGFloat = 1

    /// 文本类作答（text/longText：字符串；date/dateTime：ISO8601）
    @State private var textAnswers: [String: String] = [:]
    /// 选择类作答（single/multi 共用集合；单选集合至多一个）
    @State private var choiceAnswers: [String: Set<String>] = [:]
    /// 日期控件原值（提交时转 ISO8601 字符串）
    @State private var dateAnswers: [String: Date] = [:]

    private var isValid: Bool {
        form.fields.allSatisfy { field in
            let answered = value(for: field) != nil
            if field.required { return answered }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(form.prompt)
                        .readingBodyFont()
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(form.fields) { field in fieldView(field) }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .frame(height: min(bodyHeight, max(80, maxBodyHeight)))

            HStack {
                Button(L.string("chat.ask.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L.string("chat.ask.submit")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .font(MeetTypography.control)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .onAppear(perform: applyDefaults)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(
                form.title.isEmpty ? L.string("chat.ask.title") : form.title,
                systemImage: "questionmark.bubble"
            )
            .font(MeetTypography.control)
            .fixedSize(horizontal: false, vertical: true)
            .fontWeight(.semibold)
            .foregroundColor(.blue)

            Spacer()
        }
    }

    // MARK: - Field Views

    @ViewBuilder
    private func fieldView(_ field: QuestionField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(field)

            switch field.type {
            case .singleChoice:
                singleChoiceView(field)
            case .multiChoice:
                multiChoiceView(field)
            case .text:
                TextField(
                    field.placeholder ?? L.string("chat.ask.placeholder"),
                    text: bindingForText(field)
                )
                .textFieldStyle(.roundedBorder)
            case .longText:
                TextEditor(text: bindingForText(field))
                    .readingBodyFont()
                    .frame(minHeight: 64, maxHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if textAnswers[field.id]?.isEmpty != false, let hint = field.placeholder {
                            Text(hint)
                                .readingBodyFont()
                                .foregroundColor(Color.secondary.opacity(0.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
            case .date, .dateTime:
                DatePicker(
                    L.string("chat.ask.select_date"),
                    selection: bindingForDate(field),
                    displayedComponents: field.type == .dateTime ? [.date, .hourAndMinute] : [.date]
                )
                .datePickerStyle(.field)
                .labelsHidden()
            }
        }
    }

    private func fieldLabel(_ field: QuestionField) -> some View {
        HStack(spacing: 4) {
            Text(field.label)
                .font(MeetTypography.control)
                .fixedSize(horizontal: false, vertical: true)
                .fontWeight(.medium)
            if field.required {
                Text(L.string("chat.ask.required"))
                    .font(MeetTypography.secondary.weight(.semibold))
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(4)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private func singleChoiceView(_ field: QuestionField) -> some View {
        if field.options.contains(where: { $0.count > 24 }) || form.resolvedStyle(for: field) == .radio {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(field.options, id: \.self) { choiceButton(field, option: $0, expanded: true) }
            }
        } else {
            switch form.resolvedStyle(for: field) {
            case .buttons:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(field.options, id: \.self) { choiceButton(field, option: $0, expanded: false).fixedSize() }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(field.options, id: \.self) { choiceButton(field, option: $0, expanded: true) }
                    }
                }
            case .radio:
                Picker(field.label, selection: Binding(
                    get: { choiceAnswers[field.id]?.first ?? "" },
                    set: { newValue in
                        choiceAnswers[field.id] = newValue.isEmpty ? [] : [newValue]
                    }
                )) {
                    Text(L.string("chat.ask.unselected")).tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            case .dropdown:
                Picker(field.label, selection: Binding(
                    get: { choiceAnswers[field.id]?.first ?? "" },
                    set: { newValue in
                        choiceAnswers[field.id] = newValue.isEmpty ? [] : [newValue]
                    }
                )) {
                    Text(L.string("chat.ask.unselected")).tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func choiceButton(_ field: QuestionField, option: String, expanded: Bool) -> some View {
        Button { choiceAnswers[field.id] = [option] } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected(field, option) ? "largecircle.fill.circle" : "circle")
                Text(option).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .readingBodyFont()
            .frame(maxWidth: expanded ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected(field, option) ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected(field, option) ? Color.blue : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected(field, option) ? .isSelected : [])
    }

    private func multiChoiceView(_ field: QuestionField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(field.options, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { choiceAnswers[field.id]?.contains(option) ?? false },
                    set: { isOn in
                        var current = choiceAnswers[field.id] ?? []
                        if isOn {
                            current.insert(option)
                        } else {
                            current.remove(option)
                        }
                        choiceAnswers[field.id] = current
                    }
                )) {
                    Text(option)
                        .readingBodyFont()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
            if let min = field.minSelect, min > 1 {
                Text(L.format("chat.ask.min_select", min))
                    .font(MeetTypography.secondary)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Answer Assembly

    private func isSelected(_ field: QuestionField, _ option: String) -> Bool {
        choiceAnswers[field.id]?.contains(option) ?? false
    }

    /// 字段是否已作答（required 校验依据）
    private func value(for field: QuestionField) -> QuestionFormAnswer.Value? {
        switch field.type {
        case .text, .longText:
            let text = (textAnswers[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .text(text)
        case .singleChoice:
            guard let choice = choiceAnswers[field.id]?.first else { return nil }
            return .choices([choice])
        case .multiChoice:
            let choices = choiceAnswers[field.id] ?? []
            if let min = field.minSelect, min > 0, choices.count < min { return nil }
            if let max = field.maxSelect, choices.count > max { return nil }
            return choices.isEmpty ? nil : .choices(choices.sorted { optionIndex(field, $0) < optionIndex(field, $1) })
        case .date, .dateTime:
            if let date = dateAnswers[field.id] {
                return .date(Self.isoString(from: date, includeTime: field.type == .dateTime))
            }
            return nil
        }
    }

    private func optionIndex(_ field: QuestionField, _ option: String) -> Int {
        field.options.firstIndex(of: option) ?? 0
    }

    private func bindingForText(_ field: QuestionField) -> Binding<String> {
        Binding(
            get: { textAnswers[field.id] ?? "" },
            set: { textAnswers[field.id] = $0 }
        )
    }

    private func bindingForDate(_ field: QuestionField) -> Binding<Date> {
        Binding(
            get: { dateAnswers[field.id] ?? Date() },
            set: { dateAnswers[field.id] = $0 }
        )
    }

    /// 表单默认值落到作答状态（onAppear 一次性）
    private func applyDefaults() {
        for field in form.fields {
            switch field.type {
            case .singleChoice:
                if let def = field.defaultValue, field.options.contains(def) {
                    choiceAnswers[field.id] = [def]
                }
            case .multiChoice:
                let defaults = field.defaultValues?.filter { field.options.contains($0) } ?? []
                if let def = field.defaultValue, field.options.contains(def), !defaults.contains(def) {
                    choiceAnswers[field.id] = [def]
                } else if !defaults.isEmpty {
                    choiceAnswers[field.id] = Set(defaults)
                }
            case .text, .longText:
                if let def = field.defaultValue { textAnswers[field.id] = def }
            case .date, .dateTime:
                if let def = field.defaultValue, let date = Self.date(fromISO: def) {
                    dateAnswers[field.id] = date
                }
            }
        }
    }

    private func submit() {
        var values: [String: QuestionFormAnswer.Value] = [:]
        for field in form.fields {
            if let value = value(for: field) {
                values[field.id] = value
            }
        }
        onAnswer(QuestionFormAnswer(values: values))
    }

    static func isoString(from date: Date, includeTime: Bool) -> String {
        if includeTime {
            return Self.isoDateTime.string(from: date)
        }
        return Self.isoDate.string(from: date)
    }

    static func date(fromISO string: String) -> Date? {
        Self.isoDateTime.date(from: string) ?? Self.isoDate.date(from: string)
    }

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    private static let isoDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
