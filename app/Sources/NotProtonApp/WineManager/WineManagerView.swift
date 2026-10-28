// NotProtonGPTK: Heroic style list of Wine versions to download and use from Steam

import SwiftUI

struct WineManagerView: View {

    @Environment(WineManagerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            header(search: $model.search)
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(model.source.blurb, systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    if model.source == .notproton { gptkOverlayCard }
                    table
                }
                .padding(20)
            }
        }
        .navigationTitle(wm("Wine Manager"))
        .safeAreaInset(edge: .bottom) { messages }
        .task { await model.appear() }
    }

    private func header(search: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(wm("Wine Manager")).font(.largeTitle.bold())
            Spacer()
            TextField(wm("Search versions…"), text: search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(wm("Refresh"))
            .disabled(model.loading.contains(model.source))
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(WineSource.offered) { source in
                Button {
                    Task { await model.select(source) }
                } label: {
                    Text(source.title)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(model.source == source ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(model.source == source ? Color.primary : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // GPTK 4 is behind an Apple developer login, so it is patched in from the user's DMG.
    private var gptkOverlayCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(wm("Game Porting Toolkit 4 (beta)")).font(.headline)
                Text(wm("Apple only publishes GPTK 4 behind a free Apple ID sign-in, so it cannot be downloaded for you. Download the DMG from Apple and NotProton patches its D3DMetal into \(model.latestBase?.display ?? "the latest NotProton Wine"). DirectX 11 and 12 games need this; plain NotProton Wine draws through OpenGL."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let dmg = model.foundDMG {
                    Label(wm("Found \(dmg.lastPathComponent)"), systemImage: "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(.green)
                }
                if let job = model.job, job.id == WineManagerModel.gptkOverlayJob {
                    progress(job)
                } else {
                    HStack {
                        Button(wm("Get from Apple…")) { model.openAppleDownloads() }
                        if let dmg = model.foundDMG {
                            Button(wm("Patch in \(dmg.deletingPathExtension().lastPathComponent)")) { model.importGPTK(dmg: dmg) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(wm("Choose DMG…")) { model.chooseDMG() }
                    }
                    .disabled(model.job != nil || model.latestBase == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack {
                Text(wm("WINE VERSION")).frame(maxWidth: .infinity, alignment: .leading)
                Text(wm("RELEASE DATE")).frame(width: 130, alignment: .leading)
                Text(wm("SIZE")).frame(width: 100, alignment: .leading)
                Text(wm("ACTION")).frame(width: 150, alignment: .trailing)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            Divider()

            ForEach(model.unlistedInstalled) { manifest in
                row(name: manifest.display, link: nil, date: manifest.installedAt,
                    size: nil, manifest: manifest, release: nil)
                Divider()
            }
            ForEach(model.olderInstalled) { manifest in
                row(name: manifest.display + (manifest.source.runsSteamGames ? "" : wm(" (Wine 7/8, Steam games crash)")),
                    link: nil, date: manifest.installedAt, size: nil, manifest: manifest, release: nil)
                Divider()
            }

            if model.loading.contains(model.source) && model.visibleReleases.isEmpty {
                ProgressView().padding(30)
            } else if model.visibleReleases.isEmpty {
                Text(wm("No versions")).foregroundStyle(.secondary).padding(30)
            }
            ForEach(model.visibleReleases) { release in
                row(name: release.name + (release.prerelease ? " (beta)" : ""), link: release.page,
                    date: release.published, size: release.size, manifest: model.manifest(for: release),
                    release: release)
                Divider()
            }
        }
    }

    private func row(
        name: String, link: URL?, date: Date, size: Int64?, manifest: ManagedRunnerManifest?, release: WineRelease?
    ) -> some View {
        let id = manifest?.id ?? release?.runnerID ?? name
        return HStack {
            Group {
                if let link, manifest != nil {
                    Link(name, destination: link).underline()
                } else {
                    Text(name)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                .monospacedDigit().frame(width: 130, alignment: .leading)
            Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                .frame(width: 100, alignment: .leading)
            HStack(spacing: 14) {
                if let job = model.job, job.id == id {
                    progress(job)
                } else if let manifest {
                    Button { model.reveal(manifest.id) } label: { Image(systemName: "folder.fill") }
                        .help(wm("Show in Finder"))
                    Button { model.remove(manifest.id) } label: { Image(systemName: "trash.fill") }
                        .help(wm("Remove"))
                        .disabled(model.job != nil)
                } else if let release {
                    Button { model.install(release) } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.title2)
                    }
                    .help(wm("Download and set up"))
                    .disabled(model.job != nil)
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func progress(_ job: WineManagerModel.Job) -> some View {
        HStack(spacing: 8) {
            if let fraction = job.fraction {
                ProgressView(value: fraction).frame(width: 70)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(job.label).font(.caption).lineLimit(1).truncationMode(.middle)
            Button { model.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help(wm("Cancel"))
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let text = model.failure ?? model.outcome {
            HStack(alignment: .top) {
                Image(systemName: model.failure != nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.failure != nil ? .red : .green)
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button(wm("Dismiss")) { model.dismissMessages() }
            }
            .padding(12)
            .background(.bar)
        }
    }
}
