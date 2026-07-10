import SwiftUI

struct DictionaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var dictionary = model.dictionary

        VStack(spacing: 0) {
            GroupBox("Add Term") {
                HStack {
                    TextField("Correct spelling or phrase", text: $dictionary.term)
                        .onSubmit { model.addDictionaryTerm() }
                    Picker("Language", selection: $dictionary.language) {
                        ForEach(RecognitionLanguage.allCases, id: \.self) { language in
                            Text(language.menuTitle).tag(language)
                        }
                    }
                    .labelsHidden()
                    Button("Add Term") { model.addDictionaryTerm() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding([.horizontal, .top])

            TextField("Search dictionary", text: $dictionary.search)
                .textFieldStyle(.roundedBorder)
                .padding()

            List {
                Section("Suggestions · \(dictionary.candidates.count) pending") {
                    if dictionary.candidates.isEmpty {
                        Text("No learning suggestions yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(dictionary.candidates.prefix(50)) { candidate in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Add “\(candidate.replacement)”").fontWeight(.semibold)
                                    Text("Edited from “\(candidate.original)” · \(candidate.language.menuTitle) · \(candidate.bundleIdentifier ?? "all apps") · \(candidate.occurrenceCount)x")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Accept") { model.acceptCandidate(candidate) }
                                Button("Dismiss") { model.dismissCandidate(candidate) }
                            }
                        }
                    }
                }

                Section("Style pack terms · \(dictionary.activeStyleName)") {
                    if dictionary.filteredSeedTerms.isEmpty {
                        Text("No style pack terms match this search.").foregroundStyle(.secondary)
                    } else {
                        ForEach(dictionary.filteredSeedTerms.prefix(100), id: \.self) { term in
                            LabeledContent(term, value: "Included by the active style pack")
                        }
                    }
                }

                Section("Your terms · \(dictionary.filteredEntries.count) saved") {
                    if dictionary.filteredEntries.isEmpty {
                        Text("No personal dictionary terms yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(dictionary.filteredEntries.prefix(100)) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.term).fontWeight(.semibold)
                                    Text(entry.language.menuTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Delete", role: .destructive) { model.deleteDictionaryTerm(id: entry.id) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Dictionary")
        .onAppear { dictionary.reload() }
    }
}
