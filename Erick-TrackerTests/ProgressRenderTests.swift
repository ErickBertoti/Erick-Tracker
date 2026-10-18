import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Erick_Tracker

@MainActor @Suite("Renderização de Progresso", .serialized)
struct ProgressRenderTests {
    @Test("Progresso vazio, preenchido e formulários", arguments:[false,true])
    func progress(dark:Bool) async throws {
        let container = try PersistenceController.makeContainer(inMemory:true)
        let store = WorkoutStore(context:container.mainContext)
        let path = FileManager.default.temporaryDirectory.appending(path:"erick-phase3-render",directoryHint:.isDirectory)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
        try await render(ProgressRootView(store:store).modelContainer(container),name:"vazio",width:1024,height:700,dark:dark,path:path)
        UITestBootstrap.addProgressFixtures(store:store)
        let nav = WorkspaceState(); nav.navigate(to:.progress)
        try await render(ContentView(store:store,navigation:nav).modelContainer(container),name:"progresso",width:1280,height:800,dark:dark,path:path)
        let records = try store.context.fetch(FetchDescriptor<BodyRecord>())
        let points = records.compactMap { r -> WeightPoint? in
            guard let v = r.values.first(where: { $0.kind == .weight }), let value = ProgressRules.decimal(v.value) else { return nil }
            return .init(id:r.id,date:r.measuredAt,value:value)
        }
        try await render(WeightTrendChart(points:points,start:Date.now.addingTimeInterval(-14*86400),end:.now,timezoneID:"America/Sao_Paulo",edit:{_ in}).padding().modelContainer(container),name:"peso",width:1000,height:420,dark:dark,path:path)
        let sleeps = try store.context.fetch(FetchDescriptor<SleepRecord>()).map {
            SleepPoint(id:$0.id,wakeDate:$0.wakeDate,start:$0.startedAt,end:$0.endedAt,startTimezoneID:$0.startTimezoneID,endTimezoneID:$0.endTimezoneID,awakenings:$0.awakenings)
        }
        try await render(VStack {
            SleepDurationChart(points:sleeps,allPoints:sleeps,edit:{_ in})
            SleepScheduleChart(points:sleeps)
        }.padding().modelContainer(container),name:"sono",width:1024,height:800,dark:dark,path:path)
        for route in [ProgressEntryRoute.body(.composition,nil),.sleep(nil),.profile] {
            try await render(ProgressEntrySheet(route:route,store:store).modelContainer(container),name:route.id,width:620,height:680,dark:dark,path:path)
        }
        let measurementRoute = ProgressEntryRoute.body(.measurements,nil)
        var measurementDraft = BodyEntryDraft()
        measurementDraft.values = [.init(kind:.waist,value:"90"),.init(kind:.arm,value:"")]
        #expect(ProgressDraftStore(store:store).save(measurementDraft,key:measurementRoute.id))
        try await render(ProgressEntrySheet(route:measurementRoute,store:store).modelContainer(container),
            name:"medidas-dois-campos",width:560,height:580,dark:dark,path:path)
    }
    private func render<V:View>(_ content:V,name:String,width:Int,height:Int,dark:Bool,path:URL) async throws {
        let host = NSHostingController(rootView:content.environment(\.locale,ProgressRules.locale).preferredColorScheme(dark ? .dark : .light)
            .tint(.teal).frame(width:CGFloat(width),height:CGFloat(height)).background(Color(nsColor:.windowBackgroundColor)))
        let window = NSWindow(contentViewController:host); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua); window.setContentSize(NSSize(width:width,height:height))
        defer { window.contentViewController = nil; window.close() }
        for _ in 0..<3 { try await Task.sleep(for:.milliseconds(80)); host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded() }
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in:host.view.bounds))
        host.view.cacheDisplay(in:host.view.bounds,to:bitmap)
        let data = try #require(bitmap.representation(using:.png,properties:[:]))
        #expect(data.count > 1000)
        let filename = "\(name)-\(dark ? "escuro" : "claro").png"
        try data.write(to:path.appending(path:filename)); Attachment.record(data,named:filename)
    }
}
