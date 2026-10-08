// Harness render lokal untuk video; memakai komponen aplikasi dan data sintetis.
import SwiftUI
import UIKit
import MapKit

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Rendering demo assets").task { await DemoCapture.run() }
        }
    }
}
@MainActor enum DemoCapture {
    static func makeAnalysis() -> TripAnalysis {
        var rows = ["elapsed_s,rpm,speed_kmh,battery_v,coolant_c,intake_c,throttle_deg,fiError,dtc,fiWarningLamp,odometer_km,gps_lat,gps_lon,gps_speed_kmh,gps_accuracy_m"]
        var distance = 4200.0
        for i in 0...180 {
            let t = Double(i)
            let phase = t.truncatingRemainder(dividingBy: 60)
            let speed: Double
            let throttle: Double
            if phase < 8 { speed = 0; throttle = 0 }
            else if phase < 26 { speed = (phase - 8) * 2.7; throttle = 18 + 6 * sin(phase / 4) }
            else if phase < 43 { speed = 48 + 3 * sin(phase / 3); throttle = 9 + 2 * sin(phase) }
            else { speed = max(0, 48 - (phase - 43) * 3); throttle = 0 }
            let rpm = speed < 1 ? 1550 : (throttle < 1 ? 2100 + speed * 48 : 2200 + min(speed, 25) * 112 + max(0, speed - 25) * 16 + 100 * sin(t))
            let coolant = 69 + 17 * (1 - exp(-t / 42)) + 1.6 * sin(t / 21)
            let battery = 13.8 + 0.28 * sin(t / 8) - (speed < 1 ? 0.4 : 0)
            distance += speed / 3600
            // Rute ilustrasi di area publik Monas; bukan lokasi atau rekaman pengguna.
            let angle = (distance - 4200) * 1000 / 240
            let lat = -6.1754 + 0.00216 * cos(angle)
            let lon = 106.8272 + 0.00217 * sin(angle)
            rows.append(String(format: "%.0f,%.0f,%.1f,%.2f,%.1f,31,%.1f,0,0,0,%.3f,%.7f,%.7f,%.1f,3",t,rpm,speed,battery,coolant,throttle,distance,lat,lon,speed))
        }
        return TripAnalysis.parse(rows.joined(separator: "\n"))!
    }
    static func export<V: View>(_ view: V, name: String, width: CGFloat = 380) async throws {
        let content = view.padding(18).frame(width:width).fixedSize(horizontal:false,vertical:true)
            .background(Color(red:0.055,green:0.075,blue:0.11))
            .environment(\.colorScheme,.dark)
            .environment(\.locale,Locale(identifier:"id_ID"))
            .environment(\.dynamicTypeSize,.large)
        let host = UIHostingController(rootView:content)
        host.safeAreaRegions = []
        let size = host.sizeThatFits(in:CGSize(width:width,height:3000))
        guard let scene=UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let window=UIWindow(windowScene:scene)
        window.frame=CGRect(origin:.zero,size:size)
        window.rootViewController=host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.frame=CGRect(origin:.zero,size:size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(80))
        let format=UIGraphicsImageRendererFormat();format.scale=3
        let image=UIGraphicsImageRenderer(size:size,format:format).image { _ in
            host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
        }
        window.isHidden=true
        guard let data=image.pngData() else { return }
        let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("video-demo",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try data.write(to:dir.appendingPathComponent(name+".png"))
    }
    static func run() async {
        let a = makeAnalysis()
        let p = TripPlayback(analysis: a)
        p.seek(to: 85)
        do {
            if ProcessInfo.processInfo.arguments.contains("--maps-only") {
                try await exportMaps(analysis:a,playback:p)
                return
            }
            try await export(VStack(alignment: .leading, spacing: 16) {
                Label("Kondisi motor", systemImage: "gauge.with.dots.needle.50percent").font(.title3.bold())
                TripStatsGrid(analysis: a, group: .vehicle)
                TripTimelineCharts(analysis: a, playback: p, group: .vehicle)
            }, name: "motor-kondisi")
            try await export(VStack(alignment: .leading, spacing: 16) {
                Label("Analisis berkendara", systemImage: "chart.xyaxis.line").font(.title3.bold())
                TripTimelineCharts(analysis: a, playback: p)
            }, name: "motor-grafik")
            try await export(VStack(alignment: .leading, spacing: 16) {
                TripCVTChart(analysis: a, playback: p)
            },name: "motor-cvt")
            try await export(VStack(alignment: .leading, spacing: 16) {
                TripModeBreakdown(analysis: a)
                TripHistogramCard(analysis: a)
            },name: "motor-mode")
            try await export(VStack(alignment: .leading, spacing: 16) {
                Label("Status diagnostik", systemImage: "wrench.and.screwdriver").font(.title3.bold())
                TripDiagnosticStatus(analysis: a)
            },name: "motor-diagnostik")
            // Kursor dan pembacaan berubah dari sumber data dan kode replay yang sama.
            for index in 0..<45 {
                p.seek(to: Double(67 + index))
                try await export(VStack(alignment: .leading,spacing: 14) {
                    TripLineChart(title:"Kecepatan",series:[TripLineSeries(id:"ECU",points:a.speedSeries,color:TripPalette.ecu)],playback:p,fromZero:true) { sample in
                        sample?.speed.map { String(format:"%.0f km/h",$0) } ?? "—"
                    }
                    TripLineChart(title:"RPM",series:[TripLineSeries(id:"RPM",points:a.rpmSeries,color:TripPalette.rpm)],playback:p,fromZero:true,area:true) { sample in
                        sample?.rpm.map { String(format:"%.0f rpm",$0) } ?? "—"
                    }
                    TripPlaybackBar(playback: p,accent: Color(red: 0.2,green: 0.56,blue: 0.95))
                },name: String(format: "motor-replay-%02d",index),width:420)
                await Task.yield()
            }
            let dir=FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("video-demo")
            try "complete".write(to:dir.appendingPathComponent("DONE"),atomically:true,encoding:.utf8)
        } catch { print("DEMO RENDER ERROR: \(error)") }
    }

    // Pertahankan satu view peta agar tile dan kamera tidak dimuat ulang per frame.
    static func exportMaps(analysis:TripAnalysis,playback:TripPlayback) async throws {
        let content = VStack(spacing:14) {
            TripMapCard(analysis:analysis,playback:playback,accent:.blue)
            TripPlaybackBar(playback:playback,accent:Color(red:0.2,green:0.56,blue:0.95))
        }.padding(18).frame(width:420).fixedSize(horizontal:false,vertical:true)
            .background(Color(red:0.055,green:0.075,blue:0.11))
            .environment(\.colorScheme,.dark).environment(\.locale,Locale(identifier:"id_ID"))
            .environment(\.dynamicTypeSize,.large)
        let host=UIHostingController(rootView:content)
        host.safeAreaRegions=[]
        let size=host.sizeThatFits(in:CGSize(width:420,height:1600))
        guard let scene=UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let window=UIWindow(windowScene:scene)
        window.frame=CGRect(origin:.zero,size:size)
        window.rootViewController=host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.frame=CGRect(origin:.zero,size:size)
        host.view.layoutIfNeeded()
        playback.rate=8
        try await Task.sleep(for:.seconds(12))
        let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("video-demo",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        for index in 0..<45 {
            playback.seek(to:Double(67+index))
            try await Task.sleep(for:.milliseconds(150))
            host.view.layoutIfNeeded()
            let format=UIGraphicsImageRendererFormat();format.scale=3
            let image=UIGraphicsImageRenderer(size:size,format:format).image { _ in
                host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)
            }
            try image.pngData()?.write(to:dir.appendingPathComponent(String(format:"motor-map-%02d.png",index)))
        }
        window.isHidden=true
        try "complete".write(to:dir.appendingPathComponent("MAPS-DONE"),atomically:true,encoding:.utf8)
    }
}
