enum RouterDriverAvailability: Equatable {
    case missing
    case installedOnDisk
    case loaded

    init(installedOnDisk: Bool, loadedByCoreAudio: Bool = false) {
        if loadedByCoreAudio {
            self = .loaded
        } else if installedOnDisk {
            self = .installedOnDisk
        } else {
            self = .missing
        }
    }

    var isInstalled: Bool {
        self != .missing
    }

    var isLoaded: Bool {
        self == .loaded
    }
}
