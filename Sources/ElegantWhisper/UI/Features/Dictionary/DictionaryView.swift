import SwiftUI

/// Same structure as Settings: a grouped Form on the page color, search in the toolbar as on
/// History. The old layout mixed a GroupBox, a bare text field, and a List, each with its own
/// background.
struct DictionaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dictionary = model.dictionary

        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Term", text: $dictionary.term, prompt: Text("Correct spelling or phrase"))
                        .labelsHidden()
                        .onSubmit { model.addDictionaryTerm() }
                    Picker("Language", selection: $dictionary.language) {
                        ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                            Text(language.menuTitle).tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add") { model.addDictionaryTerm() }
                        .buttonStyle(.borderedProminent)
                        .disabled(dictionary.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Add a Term")
            } footer: {
                Text("Names and technical words you use often. They guide recognition, fix near-miss spellings, and keep your casing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !dictionary.candidates.isEmpty {
                Section("Suggestions · \(dictionary.candidates.count)") {
                    ForEach(dictionary.candidates.prefix(50)) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Add “\(candidate.replacement)”").fontWeight(.semibold)
                                Text("You changed “\(candidate.original)” \(candidate.occurrenceCount) times · \(candidate.language.menuTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Dismiss") { model.dismissCandidate(candidate) }
                                .buttonStyle(.borderless)
                            Button("Add") { model.acceptCandidate(candidate) }
                        }
                    }
                }
            }

            Section("Your Terms · \(dictionary.filteredEntries.count)") {
                if dictionary.filteredEntries.isEmpty {
                    Text(dictionary.search.isEmpty ? "No terms yet." : "No terms match “\(dictionary.search)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dictionary.filteredEntries.prefix(200)) { entry in
                        LabeledContent {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deleteDictionaryTerm(id: entry.id)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete “\(entry.term)”")
                        } label: {
                            Text(entry.term)
                            Text(entry.language.menuTitle)
                        }
                    }
                }
            }

            let seedTerms = dictionary.filteredSeedTerms
            if !seedTerms.isEmpty {
                Section {
                    // One flowing row instead of a row per built-in word.
                    Text(seedTerms.joined(separator: "  ·  "))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Included by the \(dictionary.activeStyleName) Style")
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $dictionary.search, placement: .toolbar, prompt: "Search terms")
        .navigationTitle("Dictionary")
        .onAppear { dictionary.reload() }
    }
}
