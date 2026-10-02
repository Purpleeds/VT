import Foundation
import SwiftUI

/// Every exercise in the lesson plan, searchable and playable on its own,
/// with filters by skill (SPEC section 8).
struct ExerciseLibraryView: View {
    var initialFilter: ExerciseLibraryFilter = .all
    @State private var filter: ExerciseLibraryFilter = .all
    @State private var query = ""
    @State private var didApplyInitialFilter = false

    var body: some View {
        Group {
            if let catalog = LessonLibrary.catalog {
                content(catalog)
            } else {
                ContentUnavailableView(
                    "Exercises unavailable",
                    systemImage: "books.vertical",
                    description: Text(LessonLibrary.loadError ?? "The exercise list couldn’t be loaded.")
                )
            }
        }
        .navigationTitle("Exercise Library")
        .searchable(text: $query, prompt: "Search exercises")
        .onAppear {
            guard !didApplyInitialFilter else { return }
            didApplyInitialFilter = true
            filter = initialFilter
        }
    }

    private func content(_ catalog: LessonCatalog) -> some View {
        let results = ExerciseLibrary.filter(catalog.allExercises, by: filter, query: query)
        let sections = ExerciseLibrary.sections(results)
        return List {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(ExerciseLibraryFilter.allCases) { option in
                            FilterChip(title: option.title, systemImage: option.systemImage, isSelected: filter == option) {
                                filter = option
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            } footer: {
                Text(footerText(count: results.count))
            }

            if sections.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "No exercises here",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try another filter.")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.exercises) { exercise in
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise)
                        } label: {
                            LibraryExerciseLabel(exercise: exercise)
                        }
                    }
                } header: {
                    Label(section.skill.title, systemImage: section.skill.systemImage)
                }
            }
        }
    }

    private func footerText(count: Int) -> String {
        let noun = count == 1 ? "exercise" : "exercises"
        return filter == .quiet
            ? "\(count) quiet \(noun), good for when others are nearby."
            : "\(count) \(noun). Tap one to see how to do it and practice it on its own."
    }
}

/// An exercise's title, length and whether it's scored or quiet.
private struct LibraryExerciseLabel: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exercise.title)
                .font(.body.weight(.medium))
            Text(exercise.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Label(SessionFormat.duration(Double(exercise.durationSeconds)), systemImage: "timer")
                if exercise.kind.isMeasured {
                    Label("Scored", systemImage: "chart.bar")
                }
                if exercise.isQuiet {
                    Label("Quiet", systemImage: "speaker.slash")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
