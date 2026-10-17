import SwiftData
import SwiftUI

struct SessionHistoryView: View {
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]
    var edit: ((WorkoutSession) -> Void)?
    @State private var selection: UUID?
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sessions) { s in
                    NavigationLink(value: s.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name).font(.headline)
                            Text(s.startedAt, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                            Text("\(s.completedSetCount) séries realizadas · \(sessionStatus(s.status))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(s.id).accessibilityIdentifier("history-session-\(s.id.uuidString)")
                }
            }
            .overlay { if sessions.isEmpty { ContentUnavailableView("Nenhuma sessão", systemImage: "clock.arrow.circlepath", description: Text("Os treinos registrados no iPhone aparecem aqui.")) } }
            .navigationTitle("Histórico")
        } detail: {
            if let selected = sessions.first(where: { $0.id == selection }) {
                ScrollView { SessionSummaryView(session: selected).padding() }
                    .navigationTitle(selected.name)
                    .toolbar {
                        if let edit { Button(selected.isActive ? "Retomar" : "Corrigir registro") { edit(selected) } }
                    }
            } else { ContentUnavailableView("Selecione uma sessão", systemImage: "figure.strengthtraining.traditional") }
        }
    }
}

struct SessionSummaryView: View {
    let session: WorkoutSession
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.startedAt, format: .dateTime.day().month().year().hour().minute()).font(.headline)
                Text("\(sessionStatus(session.status)) · \(WorkoutRules.restText(Int(session.elapsed()))) · \(session.completedSetCount) séries realizadas")
                    .foregroundStyle(.secondary)
                if !session.notes.isEmpty { Text(session.notes) }
            }
            ForEach(session.orderedExercises) { e in
                VStack(alignment: .leading, spacing: 10) {
                    Text(e.name).font(.headline)
                    if !e.prescribedName.isEmpty && e.name != e.prescribedName {
                        Text("Planejado: \(e.prescribedName)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !e.notes.isEmpty { Text(e.notes).font(.callout) }
                    ForEach(e.orderedSets) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                SetGlyph(kind: s.kind)
                                Text("\(e.number(for: s).map(String.init) ?? "—") · \(s.kind.label)").font(.subheadline.bold())
                                Spacer()
                                Text(s.status == .completed ? "Realizada" : s.status == .skipped ? "Ignorada" : "Pendente")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Planejado: \(s.prescribedReps.isEmpty ? "—" : s.prescribedReps) reps · \(s.prescribedLoad.isEmpty ? "—" : s.prescribedLoad) kg")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(s.orderedSegments) { p in
                                Text("\(p.reps.map(String.init) ?? "—") reps × \(p.loadKg.map { $0.replacingOccurrences(of: ".", with: ",") } ?? "—") kg")
                                    .monospacedDigit()
                            }
                            if !s.intensity.isEmpty { Text("\(s.intensityScaleRaw.uppercased()) \(s.intensity)").font(.caption) }
                            if !s.notes.isEmpty { Text(s.notes).font(.caption) }
                        }.padding(.vertical, 5)
                    }
                }
                Divider()
            }
            if let original = try? SnapshotCodec.decode(WorkoutSnapshot.self, from: session.prescription) {
                DisclosureGroup("Prescrição original completa") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(original.items, id: \.id) { item in
                            Text(item.exerciseName).font(.subheadline.bold())
                            ForEach(item.sets, id: \.id) { set in
                                Text("\(set.kind.label) · \(set.reps.isEmpty ? "—" : set.reps) reps · \(set.load.isEmpty ? "—" : set.load) kg")
                                    .font(.caption)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.frame(maxWidth: 800, alignment: .leading)
    }
}

func sessionStatus(_ status: SessionStatus) -> String {
    switch status { case .inProgress: "Em andamento"; case .paused: "Em pausa"; case .completed: "Concluído"; case .cancelled: "Cancelado" }
}
