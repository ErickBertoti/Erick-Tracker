import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Erick_Tracker

@Suite("Renderização isolada do planejador", .serialized)
@MainActor
struct LayoutRenderTests {
    @Test("Telas vazias e preenchidas nos dois tamanhos e aparências",
          arguments: [1024, 1280], [false, true])
    func layouts(width: Int, dark: Bool) async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = WorkoutStore(context: container.mainContext)
        let height = width == 1024 ? 700 : 800
        let suffix = "\(width)x\(height)-\(dark ? "escuro" : "claro")"
        try await render(ContentView(store: store).modelContainer(container),
                   named: "inicio-vazio-\(suffix)", width: width, height: height, dark: dark)

        let program = try #require(store.createProgram(name: "Hipertrofia ABC"))
        let exercise = try #require(store.createExercise(name: "Supino reto articulado",
            primaryMuscle: "Peito", secondaryMuscles: "Tríceps, deltoide anterior",
            equipment: "Máquina articulada", movementPattern: "Empurrar horizontal"))
        let workout = try #require(store.createWorkout(name: "Peito · Tríceps · Ombro", program: program))
        let item = store.addExercise(exercise, to: workout, defaults: TrainingDefaults())
        for _ in 1..<SetKind.allCases.count { store.addSet(to: item) }
        for (set, kind) in zip(item.orderedSets, SetKind.allCases) {
            store.updateSet(set) {
                set.kind = kind; set.reps = kind == .dropSet ? "12 + 10" : "6–8"
                set.load = kind == .dropSet ? "15 → 10" : "90"
                set.notes = kind == .warmup ? "Mobilidade de ombro antes" : ""
            }
        }
        store.updateItem(item) { item.notes = "Banco na posição 4. Pausa de 1 s no peito." }
        let navigation = WorkspaceState()
        navigation.open(workout); navigation.selectedItemID = item.id
        try await render(ContentView(store: store, navigation: navigation).modelContainer(container),
                   named: "editor-\(suffix)", width: width, height: height, dark: dark)

        let library = WorkspaceState()
        library.navigate(to: .exercises); library.selectedExerciseID = exercise.id
        try await render(ContentView(store: store, navigation: library).modelContainer(container),
                   named: "biblioteca-\(suffix)", width: width, height: height, dark: dark)
    }

    /// Renders private test content. Vibrancy/toolbars need a separate live-window review.
    private func render<V: View>(_ content: V, named name: String, width: Int, height: Int, dark: Bool) async throws {
        let controller = NSHostingController(rootView: content
            .environment(\.locale, WorkoutRules.locale)
            .preferredColorScheme(dark ? .dark : .light)
            .tint(Color(red: 44 / 255, green: 122 / 255, blue: 120 / 255))
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color(nsColor: .windowBackgroundColor)))
        // An unshown, private window gives native controls a complete appearance/layout environment.
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: width, height: height))
        defer { window.contentViewController = nil; window.close() }
        let view = controller.view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(60))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        #expect(view.bounds.width == CGFloat(width))
        #expect(view.bounds.height == CGFloat(height))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        Attachment.record(data, named: name + ".png")
    }
}
