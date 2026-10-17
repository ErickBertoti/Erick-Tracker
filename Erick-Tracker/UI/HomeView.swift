import SwiftUI

struct HomeView: View {
    let workouts: [WorkoutTemplate]
    let exerciseCount: Int
    let programCount: Int
    let newWorkout: () -> Void
    let newExercise: () -> Void
    let newProgram: () -> Void
    let openWorkout: (WorkoutTemplate) -> Void

    private var recent: [WorkoutTemplate] {
        Array(workouts.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(6))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Seu próximo treino começa aqui.").font(.system(size: 22, weight: .semibold))
                    Text("Organize seus exercícios, monte seus modelos e ajuste cada série.")
                        .foregroundStyle(.secondary)
                }.padding(.top, 4)

                HStack(spacing: 16) {
                    summary("Modelos ativos", value: workouts.filter { !$0.isArchived }.count, symbol: "list.bullet.rectangle")
                    summary("Exercícios", value: exerciseCount, symbol: "figure.strengthtraining.traditional")
                    summary("Programas", value: programCount, symbol: "folder")
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "Ações rápidas")
                    GroupBox {
                        VStack(spacing: 0) {
                            quickAction("Novo exercício", detail: "Cadastre os movimentos da sua biblioteca", symbol: "figure.strengthtraining.traditional", action: newExercise)
                            Divider().padding(.leading, 40)
                            quickAction("Novo treino", detail: "Escolha exercícios e configure suas séries", symbol: "plus.square", action: newWorkout)
                            Divider().padding(.leading, 40)
                            quickAction("Novo programa", detail: "Agrupe os modelos da sua rotina", symbol: "folder.badge.plus", action: newProgram)
                        }
                    }
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "Editados recentemente")
                        GroupBox {
                            VStack(spacing: 0) {
                                ForEach(recent) { workout in
                                    if workout.id != recent.first?.id { Divider() }
                                    Button { openWorkout(workout) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "list.bullet.rectangle").foregroundStyle(.tint)
                                                .font(.title3).frame(width: 28)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(workout.name).fontWeight(.medium).foregroundStyle(.primary)
                                                Text("\(workout.program?.name ?? "Modelos avulsos") · \(WorkoutRules.count(workout.items.count, singular: "exercício", plural: "exercícios")) · \(WorkoutRules.count(workout.totalSetCount, singular: "série", plural: "séries"))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(workout.updatedAt, format: .dateTime.day().month(.abbreviated))
                                                .font(.caption).foregroundStyle(.secondary)
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }.padding(10).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    Label("Comece cadastrando um exercício ou criando seu primeiro treino.", systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
    private func summary(_ title: String, value: Int, symbol: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: symbol).foregroundStyle(.tint)
                }
                Text(value, format: .number).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func quickAction(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus").foregroundStyle(.secondary)
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
