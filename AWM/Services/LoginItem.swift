import ServiceManagement

@MainActor
struct LoginItem {
    let status: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () throws -> Void

    static var system: Self {
        let service = SMAppService.mainApp
        return Self(status: { service.status }, register: service.register, unregister: service.unregister)
    }

    var isRequested: Bool {
        let current = status()
        return current == .enabled || current == .requiresApproval
    }

    func apply(_ enabled: Bool) throws {
        guard enabled != isRequested else { return }
        if enabled { try register() }
        else { try unregister() }
    }
}
