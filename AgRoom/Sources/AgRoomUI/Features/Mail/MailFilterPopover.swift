import SwiftUI
import AgRoomCore

/// 筛选即时生效。显式排列字段，避免原生 Form 的标签列和剩余高度挤压浮层。
struct MailFilterPopover: View {
    let availableScopes: [MailSearchScope]
    @Binding var scope: MailSearchScope
    @Binding var includeBody: Bool
    @Binding var unreadOnly: Bool
    @Binding var starredOnly: Bool
    @Binding var attachmentsOnly: Bool
    @Binding var sender: String
    @Binding var recipient: String
    @Binding var attachmentName: String
    @Binding var minimumKB: Int
    @Binding var maximumKB: Int
    @Binding var afterEnabled: Bool
    @Binding var beforeEnabled: Bool
    @Binding var afterDate: Date
    @Binding var beforeDate: Date
    let activeCount: Int
    let onReset: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("mail.filter.title")).font(MeetTypography.sectionTitle)
                Spacer()
                Text(L.string("mail.filter.live")).font(MeetTypography.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            ScrollView {
                fields.padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button(L.string("mail.filter.reset"), action: onReset)
                    .disabled(activeCount == 0)
                Spacer()
                Button(L.string("common.done"), action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .font(MeetTypography.secondary)
        .controlSize(.small)
        .textFieldStyle(.roundedBorder)
        .frame(width: 380)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(L.string("mail.search.range")).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Picker(L.string("mail.search.range"), selection: $scope) {
                        ForEach(availableScopes, id: \.self) { scope in
                            Text(L.string("mail.search.range." + scope.rawValue)).tag(scope)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Toggle(L.string("mail.search.includeBody"), isOn: $includeBody)
                Text(L.string("mail.filter.localHint"))
                    .font(MeetTypography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            statusFilters
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                field("mail.filter.sender", text: $sender)
                field("mail.search.recipient", text: $recipient)
                field("mail.search.attachmentName", text: $attachmentName)
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("mail.filter.size", hint: "mail.filter.sizeHint")
                HStack(spacing: 12) {
                    sizeField("mail.filter.minimum", value: $minimumKB)
                    sizeField("mail.filter.maximum", value: $maximumKB)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionHeading("mail.filter.dates", hint: "mail.filter.dateHint")
                dateRow("mail.filter.startDate", enabled: $afterEnabled, date: $afterDate)
                dateRow("mail.filter.endDate", enabled: $beforeEnabled, date: $beforeDate)
            }
        }
    }

    private var statusFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Toggle(L.string("mail.filter.unread"), isOn: $unreadOnly)
                Toggle(L.string("mail.filter.starred"), isOn: $starredOnly)
                Toggle(L.string("mail.filter.attachments"), isOn: $attachmentsOnly)
            }.fixedSize()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Toggle(L.string("mail.filter.unread"), isOn: $unreadOnly)
                    Toggle(L.string("mail.filter.starred"), isOn: $starredOnly)
                }
                Toggle(L.string("mail.filter.attachments"), isOn: $attachmentsOnly)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func field(_ key: String, text: Binding<String>) -> some View {
        GridRow {
            Text(L.string(key)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField("", text: text).labelsHidden()
                .accessibilityLabel(L.string(key))
        }
    }

    private func sectionHeading(_ title: String, hint: String) -> some View {
        HStack {
            Text(L.string(title)).fontWeight(.medium)
            Spacer()
            Text(L.string(hint)).font(MeetTypography.caption).foregroundStyle(.secondary)
        }
    }

    private func sizeField(_ key: String, value: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(L.string(key)).foregroundStyle(.secondary)
            TextField(L.string(key), value: value, format: .number)
                .labelsHidden().monospacedDigit()
                .accessibilityLabel(L.string(key == "mail.filter.minimum" ? "mail.search.minimumKB" : "mail.search.maximumKB"))
        }
        .frame(maxWidth: .infinity)
    }

    private func dateRow(_ key: String, enabled: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack {
            Toggle(L.string(key), isOn: enabled).toggleStyle(.checkbox)
            Spacer(minLength: 8)
            DatePicker(L.string(key), selection: date, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).disabled(!enabled.wrappedValue)
                .accessibilityLabel(L.string(key))
        }
    }
}
