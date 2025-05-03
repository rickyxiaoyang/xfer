import SwiftUI
import Foundation

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    var existsInDestination: Bool = false
    var isSelected: Bool = false
}

class FileScannerViewModel: ObservableObject {
    @Published var isScanning: Bool = false
    @Published var originFiles: [FileItem] = []
    @Published var destinationURL: URL? {
        didSet {
            if let url = destinationURL {
                saveBookmark(for: url, key: "LastDestinationBookmark")
            }
        }
    }
    @Published var originURL: URL? {
        didSet {
            if let url = originURL {
                saveBookmark(for: url, key: "LastOriginBookmark")
            }
        }
    }
    @Published var importIntoDatedSubfolders: Bool = false
    @Published var searchText: String = ""
    @Published var showOnlyUntransferred: Bool = false
    @Published var sortAscending: Bool = true
    @Published var sortByFileType: Bool = false

    init() {
        if let origin = resolveBookmark(for: "LastOriginBookmark"), let destination = resolveBookmark(for: "LastDestinationBookmark") {
            self.originURL = origin
            self.destinationURL = destination
            scanFiles(origin: origin, destination: destination)
        }
    }

    var filteredFiles: [FileItem] {
        let filtered = originFiles.filter { file in
            (!showOnlyUntransferred || !file.existsInDestination) &&
            (searchText.isEmpty || file.url.lastPathComponent.localizedCaseInsensitiveContains(searchText))
        }

        return filtered.sorted {
            if sortByFileType {
                let ext1 = $0.url.pathExtension.lowercased()
                let ext2 = $1.url.pathExtension.lowercased()
                return sortAscending ? ext1 < ext2 : ext1 > ext2
            } else {
                return sortAscending ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.url.lastPathComponent > $1.url.lastPathComponent
            }
        }
    }

    func scanFiles(origin: URL, destination: URL) {
        isScanning = true
        self.originURL = origin
        self.destinationURL = destination

        DispatchQueue.global(qos: .userInitiated).async {
            let originFileURLs = FileManager.default.enumerator(at: origin, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            let destinationFileURLs = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []

            let destinationFileSet = Set(destinationFileURLs.map { $0.lastPathComponent })

            let filteredOriginURLs = originFileURLs.filter { !$0.hasDirectoryPath }
            var tempOriginFiles: [FileItem] = []
            for fileURL in filteredOriginURLs {
                let fileName = fileURL.lastPathComponent
                let exists = destinationFileSet.contains(fileName)
                let fileItem = FileItem(url: fileURL, existsInDestination: exists)
                tempOriginFiles.append(fileItem)
            }

            DispatchQueue.main.async {
                self.originFiles = tempOriginFiles
                self.isScanning = false
            }
        }
    }

    func copySelectedFiles(to destination: URL) {
        for file in originFiles where file.isSelected && !file.existsInDestination {
            var destURL = destination

            if importIntoDatedSubfolders {
                if let creationDate = try? FileManager.default.attributesOfItem(atPath: file.url.path)[.creationDate] as? Date {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM-dd-yyyy"
                    let folderName = formatter.string(from: creationDate)
                    destURL = destURL.appendingPathComponent(folderName)

                    try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true, attributes: nil)
                }
            }

            destURL = destURL.appendingPathComponent(file.url.lastPathComponent)

            do {
                try FileManager.default.copyItem(at: file.url, to: destURL)
            } catch {
                print("Failed to copy \(file.url): \(error)")
            }
        }

        if let origin = originFiles.first?.url.deletingLastPathComponent(), let destination = destinationURL {
            scanFiles(origin: origin, destination: destination)
        }
    }

    func selectAllUntransferred() {
        for index in originFiles.indices {
            if !originFiles[index].existsInDestination {
                originFiles[index].isSelected = true
            }
        }
    }

    private func saveBookmark(for url: URL, key: String) {
        if let bookmarkData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmarkData, forKey: key)
        }
    }

    private func resolveBookmark(for key: String) -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if !url.startAccessingSecurityScopedResource() {
                print("Failed to start accessing security scoped resource for \(key)")
            }
            return url
        } catch {
            print("Failed to resolve bookmark for \(key): \(error)")
            return nil
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = FileScannerViewModel()

    var body: some View {
        ZStack {
        VStack {
            HStack {
                Button("Select Origin") {
                    selectFolder(allowCreate: false) { url in
                        viewModel.originURL = url
                        if let destination = viewModel.destinationURL {
                            viewModel.scanFiles(origin: url, destination: destination)
                        }
                    }
                }
                Button("Select Destination") {
                    selectFolder(allowCreate: true) { url in
                        viewModel.destinationURL = url
                        if let origin = viewModel.originURL {
                            viewModel.scanFiles(origin: origin, destination: url)
                        }
                    }
                }
                if let origin = viewModel.originURL, let destination = viewModel.destinationURL {
                    Button("Scan") {
                        viewModel.scanFiles(origin: origin, destination: destination)
                    }
                }

            }

            if let origin = viewModel.originURL {
                Text("Origin: \(origin.path)").font(.caption)
            }
            if let destination = viewModel.destinationURL {
                Text("Destination: \(destination.path)").font(.caption)
            }

            Toggle("Import into dated subfolders", isOn: $viewModel.importIntoDatedSubfolders)
                .padding(.top)
            Toggle("Show only untransferred", isOn: $viewModel.showOnlyUntransferred)
            HStack {
                TextField("Search files...", text: $viewModel.searchText)
                Toggle("Sort by Type", isOn: $viewModel.sortByFileType).toggleStyle(.checkbox)
                Button(viewModel.sortAscending ? "Sort A-Z" : "Sort Z-A") {
                    viewModel.sortAscending.toggle()
                }
            }

            List {
                ForEach(viewModel.filteredFiles) { file in
                    HStack {
                        Image(systemName: "checkmark")
                            .foregroundColor(.green)
                            .opacity(file.existsInDestination ? 1 : 0)
                        Text(file.url.lastPathComponent)
                        Spacer()
                        if !file.existsInDestination {
                            Toggle("", isOn: Binding(
                                get: { file.isSelected },
                                set: { newValue in
                                    if let index = viewModel.originFiles.firstIndex(where: { $0.id == file.id }) {
                                        viewModel.originFiles[index].isSelected = newValue
                                    }
                                })
                            ).labelsHidden()
                        }
                    }
                }
            }
            .frame(minHeight: 400)

            HStack {
                Button("Select All Untransferred") {
                    viewModel.selectAllUntransferred()
                }
                Button("Copy Selected Files") {
                    if let destination = viewModel.destinationURL {
                        viewModel.copySelectedFiles(to: destination)
                    }
                }
            }
        }
        .padding()
        .frame(width: 700, height: 600)
        }
        .overlay(
            Group {
                if viewModel.isScanning {
                    ProgressView("Scanning files...")
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding()
                        .cornerRadius(10)
                        .shadow(radius: 10)
                }
            }
        )
    }

    func selectFolder(allowCreate: Bool, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = allowCreate
        if panel.runModal() == .OK {
            if let url = panel.url {
                completion(url)
            }
        }
    }
}

#Preview {
    ContentView()
}
