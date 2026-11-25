import SwiftUI
import PandaPlayCore

/// The screen the user sees. Two modes: idle with a start button, and live with the decoded
/// surface plus a diagnostics drawer.
struct ContentView: View {
    @StateObject private var session = AppSession()
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.status {
        case .idle:
            idleView
        case .listening:
            waitingView
        case .streaming:
            liveView
        case let .failed(reason):
            failureView(reason)
        }
    }

    private var idleView: some View {
        VStack(spacing: 24) {
            Text("PandaPlay+")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            Text("车机投屏接收端")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            Button("开始监听") { session.start() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .tint(.white)
            Text("等待车机连接")
                .foregroundStyle(.white)
            Text("请在车机上搜索 PandaPlay+")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
            laneList
        }
        .padding()
    }

    private var liveView: some View {
        ZStack(alignment: .topTrailing) {
            DisplayRepresentable(attach: { view in session.attach(display: view) })
                .ignoresSafeArea()
            VStack(alignment: .trailing, spacing: 10) {
                diagnosticBadge
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .tint(.white)
            }
            .padding(.top, 56)
            .padding(.trailing, 18)
        }
        .sheet(isPresented: $showDiagnostics) {
            diagnosticsSheet
        }
    }

    private func failureView(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
            Button("重试") {
                session.stop()
                session.start()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var diagnosticBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(session.framesDecoded) 帧")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Text("\(Int(session.surfaceSize.width))×\(Int(session.surfaceSize.height))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var laneList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.lanes) { lane in
                HStack(spacing: 10) {
                    Circle()
                        .fill(lane.open ? Color.green : Color.white.opacity(0.25))
                        .frame(width: 7, height: 7)
                    Text("\(lane.kind) :\(lane.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Text("\(lane.frames)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private var diagnosticsSheet: some View {
        NavigationStack {
            List {
                Section("会话") {
                    ForEach(session.snapshot, id: \.0) { key, value in
                        HStack {
                            Text(key)
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Text(value)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("事件") {
                    ForEach(Array(session.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showDiagnostics = false }
                }
            }
        }
    }
}

/// Hosts the `AVSampleBufferDisplayLayer` view inside SwiftUI.
private struct DisplayRepresentable: UIViewRepresentable {
    let attach: (DisplayView) -> Void

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        attach(view)
        return view
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        attach(uiView)
    }
}
