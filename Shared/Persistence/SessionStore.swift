import Foundation
import Observation
import SwiftData

@MainActor @Observable final class SessionStore {
    let store: WorkoutStore
    var context: ModelContext { store.context }
    init(store: WorkoutStore) { self.store = store }
    static var deviceID: String {
        if let value = UserDefaults.standard.string(forKey: "trackerDeviceID") { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: "trackerDeviceID"); return value
    }
    var activeSession: WorkoutSession? {
        (try? context.fetch(FetchDescriptor<WorkoutSession>()))?.first { $0.isActive && $0.deviceID == Self.deviceID }
    }
    @discardableResult func start(_ workout: WorkoutTemplate) -> WorkoutSession? {
        if let activeSession { return activeSession }
        guard !workout.items.isEmpty else { store.operationError = "Adicione exercícios ao modelo no Mac antes de iniciar."; return nil }
        do {
            let prescription = try SnapshotCodec.encode(Snapshots.workout(workout))
            let session = WorkoutSession(name: workout.name, prescription: prescription,
                                         sourceTemplateID: workout.id, deviceID: Self.deviceID)
            context.insert(session)
            for item in workout.orderedItems {
                let e = ExerciseLog(name: item.exercise?.name ?? "Exercício", position: item.position,
                    exerciseID: item.exercise?.id, sourceItemID: item.id,
                    prescribedName: item.exercise?.name ?? "Exercício", muscle: item.exercise?.primaryMuscle ?? "")
                context.insert(e); e.session = session; e.notes = item.notes
                for planned in item.orderedSets {
                    let set = SetLog(position: planned.position, kind: planned.kind, restSeconds: planned.effectiveRestSeconds)
                    context.insert(set); set.exercise = e; set.sourceSetID = planned.id
                    set.prescribedReps = planned.reps.isEmpty ? item.repRange : planned.reps
                    set.prescribedLoad = planned.load
                    set.prescribedIntensity = planned.intensity.isEmpty ? item.intensityTarget : planned.intensity
                    set.intensityScaleRaw = item.intensityScale.rawValue
                    let segment = SetLogSegment(); context.insert(segment); segment.set = set
                }
            }
            session.currentExerciseID = session.orderedExercises.first?.id
            store.save(); return session
        } catch { store.operationError = error.localizedDescription; return nil }
    }
    func touch(_ session: WorkoutSession) { session.updatedAt = .now; store.save() }
    func update(_ session: WorkoutSession, _ change: () -> Void) { change(); touch(session) }
    func update(_ set: SetLog, _ change: () -> Void) {
        guard let session = set.exercise?.session else { return }; change(); touch(session)
    }
    @discardableResult func update(_ segment: SetLogSegment, reps: String, load: String) -> Bool {
        let r = WorkoutRules.trimmed(reps), l = WorkoutRules.trimmed(load)
        guard r.isEmpty || (Int(r).map { $0 >= 0 && $0 <= 100_000 } ?? false) else {
            store.operationError = "Informe repetições inteiras, sem valor negativo."; return false
        }
        guard l.isEmpty || Self.decimalLoad(l) != nil else {
            store.operationError = "Informe a carga em kg, com até três casas decimais."; return false
        }
        segment.reps = r.isEmpty ? nil : Int(r); segment.loadKg = l.isEmpty ? nil : Self.decimalLoad(l)
        if let session = segment.set?.exercise?.session { touch(session) }; return true
    }
    static func decimalLoad(_ value: String) -> String? {
        let canonical = value.replacingOccurrences(of: ",", with: ".")
        guard canonical.range(of: "^[0-9]+(?:\\.[0-9]{1,3})?$", options: .regularExpression) != nil,
              let number = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")),
              number >= 0, number <= 1_000_000 else { return nil }
        return NSDecimalNumber(decimal: number).stringValue
    }
    @discardableResult func mark(_ set: SetLog, as status: LoggedSetStatus) -> Bool {
        if status == .completed && !set.segments.contains(where: { ($0.reps ?? 0) > 0 }) {
            store.operationError = "Preencha as repetições realizadas em pelo menos uma etapa."; return false
        }
        guard let s = set.exercise?.session else { return false }
        set.status = status; set.completedAt = status == .completed ? .now : nil
        s.currentExerciseID = set.exercise?.id
        if status == .completed && s.status == .inProgress && set.restSeconds > 0 {
            s.restStartedAt = .now; s.restEndsAt = Date.now.addingTimeInterval(Double(set.restSeconds))
        }
        touch(s); return true
    }
    func setRest(_ session: WorkoutSession, seconds: Int) {
        if session.status == .paused {
            session.pausedRestSeconds = seconds > 0 ? Double(seconds) : nil
            session.restStartedAt = nil; session.restEndsAt = nil; touch(session); return
        }
        session.restStartedAt = seconds > 0 ? .now : nil
        session.restEndsAt = seconds > 0 ? Date.now.addingTimeInterval(Double(seconds)) : nil
        session.pausedRestSeconds = nil; touch(session)
    }
    func pause(_ s: WorkoutSession) {
        guard s.status == .inProgress else { return }
        s.pausedAt = .now; s.status = .paused
        s.pausedRestSeconds = s.restEndsAt.map { max(0, $0.timeIntervalSinceNow) }
        s.restEndsAt = nil; s.restStartedAt = nil; touch(s)
    }
    func resume(_ s: WorkoutSession) {
        guard s.status == .paused, activeSession?.id == s.id else { return }
        if let at = s.pausedAt { s.pausedSeconds += max(0, Date.now.timeIntervalSince(at)) }
        s.pausedAt = nil; s.status = .inProgress
        if let remaining = s.pausedRestSeconds, remaining > 0 {
            s.restStartedAt = .now; s.restEndsAt = Date.now.addingTimeInterval(remaining)
        }
        s.pausedRestSeconds = nil; touch(s)
    }
    func finish(_ s: WorkoutSession, cancelled: Bool = false) {
        if let at = s.pausedAt { s.pausedSeconds += max(0, Date.now.timeIntervalSince(at)) }
        s.pausedAt = nil; s.endedAt = .now; s.status = cancelled ? .cancelled : .completed
        s.restStartedAt = nil; s.restEndsAt = nil; s.pausedRestSeconds = nil
        if !cancelled { for e in s.exercises { for set in e.sets where set.status == .pending { set.status = .skipped } } }
        touch(s)
    }
    func addExercise(_ exercise: Exercise, to s: WorkoutSession) {
        let e = ExerciseLog(name: exercise.name, position: s.exercises.count, exerciseID: exercise.id, muscle: exercise.primaryMuscle)
        context.insert(e); e.session = s; addSet(to: e)
    }
    func replace(_ log: ExerciseLog, with exercise: Exercise) {
        log.exerciseID = exercise.id; log.name = exercise.name; log.muscle = exercise.primaryMuscle
        if let session = log.session { touch(session) }
    }
    func remove(_ e: ExerciseLog) {
        guard let s = e.session else { return }; s.exercises.removeAll { $0.id == e.id }; context.delete(e)
        for (index, row) in s.orderedExercises.enumerated() { row.position = index }
        if s.currentExerciseID == e.id { s.currentExerciseID = s.orderedExercises.first?.id }; touch(s)
    }
    func move(_ e: ExerciseLog, by delta: Int) {
        guard let s = e.session else { return }; var rows = s.orderedExercises
        guard let from = rows.firstIndex(where: { $0.id == e.id }), rows.indices.contains(from + delta) else { return }
        rows.swapAt(from, from + delta); for (index, row) in rows.enumerated() { row.position = index }; touch(s)
    }
    func addSet(to e: ExerciseLog) {
        let x = SetLog(position: e.sets.count, restSeconds: e.orderedSets.last?.restSeconds ?? 120)
        context.insert(x); x.exercise = e
        let segment = SetLogSegment(); context.insert(segment); segment.set = x
        if let s = e.session { touch(s) }
    }
    func remove(_ set: SetLog) {
        guard let e = set.exercise, let s = e.session else { return }
        e.sets.removeAll { $0.id == set.id }; context.delete(set)
        for (index, row) in e.orderedSets.enumerated() { row.position = index }; touch(s)
    }
    func addSegment(to set: SetLog) {
        let p = SetLogSegment(position: set.segments.count); context.insert(p); p.set = set
        if let s = set.exercise?.session { touch(s) }
    }
    func remove(_ segment: SetLogSegment) {
        guard let set = segment.set, set.segments.count > 1 else { return }
        set.segments.removeAll { $0.id == segment.id }; context.delete(segment)
        for (index, p) in set.orderedSegments.enumerated() { p.position = index }
        if let s = set.exercise?.session { touch(s) }
    }
}
