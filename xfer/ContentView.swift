import SwiftUI
import Foundation

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let creationDate: Date?
    var existsInDestination: Bool = false
    var isSelected: Bool = false
}

class FileScannerViewModel: ObservableObject {
    @Published var isCopying: Bool = false
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

    @Published var scanProgress: Double = 0
    @Published var scannedFiles: Int = 0
    @Published var totalFiles: Int = 0
    @Published var lastProgressUpdate: Date = .distantPast

    @Published var copyProgress: Double = 0
    @Published var copiedFilesCount: Int = 0
    @Published var totalFilesToCopy: Int = 0

    private var scanTask: Task<Void, Never>?
    private let progressUpdateInterval: TimeInterval = 0.15
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
    
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        DispatchQueue.main.async {
            self.isScanning = false
            self.scanProgress = 0
        }
    }
    func scanFiles(origin: URL, destination: URL) {
        cancelScan()
        isScanning = true
        scanProgress = 0
        scannedFiles = 0
        totalFiles = 0
        originFiles = []
        originURL = origin
        destinationURL = destination

        scanTask = Task.detached { [weak self] in
            guard let self else { return }
            // Build destination filename set lazily
            var destinationNames = Set<String>()
            if let destEnum = FileManager.default.enumerator(at: destination,
                                                              includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles],
                                                              errorHandler: nil) {
                while let url = destEnum.nextObject() as? URL {
                    if Task.isCancelled { return }
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                    destinationNames.insert(url.lastPathComponent)
                }
            }

            var pendingItems: [FileItem] = []
            var localTotal = 0

            if let originEnum = FileManager.default.enumerator(at: origin,
                   includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                   options: [.skipsHiddenFiles],
                   errorHandler: nil) {
                // First pass: (optional) count total files while creating FileItem list incrementally
                while let url = originEnum.nextObject() as? URL {
                    if Task.isCancelled { return }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                    if values?.isDirectory == true { continue }
                    localTotal += 1
                    let exists = destinationNames.contains(url.lastPathComponent)
                    let item = FileItem(url: url, creationDate: values?.creationDate, existsInDestination: exists)
                    pendingItems.append(item)

                    // Progress + throttled UI updates
                    let now = Date()
                    if now.timeIntervalSince(self.lastProgressUpdate) > self.progressUpdateInterval {
                        let currentTotal = localTotal
                        let currentItems = pendingItems
                        await MainActor.run {
                            self.totalFiles = currentTotal
                            self.scannedFiles = currentItems.count
                            self.scanProgress = Double(self.scannedFiles) / Double(max(self.totalFiles, 1))
                            self.originFiles = currentItems
                            self.lastProgressUpdate = now
                        }
                    }
                }
            }
            let currentTotal = localTotal
            let currentItems = pendingItems
            if Task.isCancelled { return }
            await MainActor.run {
                self.totalFiles = currentTotal
                self.scannedFiles = currentItems.count
                self.scanProgress = 1.0
                self.originFiles = currentItems
                self.isScanning = false
            }
        }
    }
    func copySelectedFiles(to destination: URL) {
        let filesToCopy = self.originFiles.filter { $0.isSelected && !$0.existsInDestination }
        guard !filesToCopy.isEmpty else { return }

        isCopying = true
        copiedFilesCount = 0
        totalFilesToCopy = filesToCopy.count
        copyProgress = 0
        
        Task {
            let dateFormatter: DateFormatter = {
                let df = DateFormatter()
                df.dateFormat = "MM-dd-yyyy"
                return df
            }()
            
            // Perform file operations on a background thread
            await Task.detached(priority: .userInitiated) {
                for file in filesToCopy {
                    var destFolder = destination
                    
                    if self.importIntoDatedSubfolders, let creationDate = file.creationDate {
                        let folderName = dateFormatter.string(from: creationDate)
                        destFolder = destFolder.appendingPathComponent(folderName)
                        
                        try? FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true, attributes: nil)
                    }
                    
                    let destURL = destFolder.appendingPathComponent(file.url.lastPathComponent)
                    
                    do {
                        try FileManager.default.copyItem(at: file.url, to: destURL)
                        // Update progress on the main thread
                        await MainActor.run {
                            self.copiedFilesCount += 1
                            self.copyProgress = Double(self.copiedFilesCount) / Double(self.totalFilesToCopy)
                        }
                    } catch {
                        print("Failed to copy \(file.url): \(error)")
                    }
                }
            }.value

            // After copying, switch back to the main thread to update state and start the new scan
            await MainActor.run {
                self.isCopying = false
                if let origin = self.originURL, let destination = self.destinationURL {
                    self.scanFiles(origin: origin, destination: destination)
                }
            }
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
        NavigationSplitView {
            VStack(spacing: 20) {
                Divider()
                VStack {
                    Button("Select Origin") {
                        selectFolder(allowCreate: false) { url in
                            viewModel.originURL = url
                            if let destination = viewModel.destinationURL {
                                viewModel.scanFiles(origin: url, destination: destination)
                            }
                        }
                    }
                    if let origin = viewModel.originURL {
                        Text("Origin: \(origin.path)")
                    }
                }
                Divider()
                VStack {
                    Button("Select Destination") {
                        selectFolder(allowCreate: true) { url in
                            viewModel.destinationURL = url
                            if let origin = viewModel.originURL {
                                viewModel.scanFiles(origin: origin, destination: url)
                            }
                        }
                    }
                    if let destination = viewModel.destinationURL {
                        Text("Destination: \(destination.path)")
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Import into dated subfolders", isOn: $viewModel.importIntoDatedSubfolders)
                    Toggle("Show only untransferred", isOn: $viewModel.showOnlyUntransferred)
                }
                if let origin = viewModel.originURL, let destination = viewModel.destinationURL {
                    Button("Scan") {
                        viewModel.scanFiles(origin: origin, destination: destination)
                    }
                }
                if viewModel.isScanning {
                    Divider()
                    VStack {
                        ProgressView(value: viewModel.scanProgress) {
                            Text("Scanning…")
                        } currentValueLabel: {
                            Text("\(viewModel.scannedFiles) of \(viewModel.totalFiles) files")
                        }
                        .progressViewStyle(.linear)
                        
                        Button("Cancel") {
                            viewModel.cancelScan()
                        }
                    }
                    .padding()
                }
                if viewModel.isCopying {
                    Divider()
                    VStack {
                        ProgressView(value: viewModel.copyProgress) {
                            Text("Copying files...")
                        } currentValueLabel: {
                            Text("\(viewModel.copiedFilesCount) of \(viewModel.totalFilesToCopy) files")
                        }
                        .progressViewStyle(.linear)
                    }.padding()
                }
                Spacer()
            }.navigationSplitViewColumnWidth(400)
        } detail: {
            VStack {
                List {
                    ForEach(viewModel.filteredFiles) { file in
                        HStack {
                            if file.existsInDestination {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { file.isSelected },
                                    set: { newValue in
                                        if let index = viewModel.originFiles.firstIndex(where: { $0.id == file.id }) {
                                            viewModel.originFiles[index].isSelected = newValue
                                        }
                                    })
                                ).labelsHidden()
                            }
                            Text(file.url.lastPathComponent)
                            Spacer()
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
                .padding()
                .searchable(text: $viewModel.searchText)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Toggle("Sort by Type", isOn: $viewModel.sortByFileType).toggleStyle(.checkbox)
                            Button(viewModel.sortAscending ? "Sort A-Z" : "Sort Z-A") {
                                viewModel.sortAscending.toggle()
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                        }
                    }
                }   
            }
        }
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
