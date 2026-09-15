import Foundation

struct LocalRuntimeReading: Equatable {
    struct Model: Identifiable, Equatable {
        /// What the runtime's byte count measures.
        enum MemoryKind: Equatable {
            /// Ollama reports what a model occupies, split into GPU and CPU.
            case allocation
            /// LM Studio reports only the weights' size on disk. Said so,
            /// rather than dressed up as memory in use.
            case modelSize
        }

        let name: String
        let memoryBytes: Int64?
        let contextLength: Int?
        let quantizationLevel: String?
        let gpuMemoryBytes: Int64?
        let expiresAt: Date?
        let memoryKind: MemoryKind
        /// The model an instance was loaded from, when the runtime names
        /// instances separately. Consulted only for the brand mark: an LM
        /// Studio instance can be given any identifier at load time.
        let modelKey: String?

        init(name: String, memoryBytes: Int64?, contextLength: Int?, quantizationLevel: String?,
             gpuMemoryBytes: Int64? = nil, expiresAt: Date? = nil,
             memoryKind: MemoryKind = .allocation, modelKey: String? = nil) {
            self.name = name
            self.memoryBytes = memoryBytes
            self.contextLength = contextLength
            self.quantizationLevel = quantizationLevel
            self.gpuMemoryBytes = gpuMemoryBytes
            self.expiresAt = expiresAt
            self.memoryKind = memoryKind
            self.modelKey = modelKey
        }

        var displayedMemoryBytes: Int64? {
            if let gpuMemoryBytes, gpuMemoryBytes > 0 { return gpuMemoryBytes }
            return memoryBytes
        }

        var memoryLabel: String { memoryLabel(locale: L10n.locale) }

        func memoryLabel(locale: Locale = L10n.locale) -> String {
            // VRAM and RAM are initialisms every language this app ships keeps
            // as they are, so they are not catalog keys — translating them
            // would invent a word nobody uses.
            if memoryKind == .modelSize { return L10n.t("Model size", locale: locale) }
            guard let gpuMemoryBytes else { return L10n.t("Memory", locale: locale) }
            return gpuMemoryBytes > 0 ? "VRAM" : "RAM"
        }

        func unloadText(now: Date, locale: Locale = L10n.locale) -> String {
            guard let expiresAt else { return L10n.t("Unavailable", locale: locale) }
            guard expiresAt > now else { return L10n.t("Pending", locale: locale) }
            // Went through the system locale before, so a Mongolian card said
            // "in 4 min" in English next to Mongolian labels.
            return NumberCopy.relative(expiresAt, to: now, locale: locale)
        }

        var id: String { name }
        var brand: LocalModelBrand? {
            LocalModelBrand.detect(modelName: name)
                ?? modelKey.flatMap { LocalModelBrand.detect(modelName: $0) }
        }

        var memoryText: String { memoryText(locale: L10n.locale) }

        /// The hand-rolled table of powers of 1024 this replaced always wrote
        /// an English "GB" and an English decimal point. The system already
        /// knows both for every language the app ships.
        func memoryText(locale: Locale = L10n.locale) -> String {
            guard let memoryBytes = displayedMemoryBytes else { return UsageFormat.noReading }
            return NumberCopy.bytes(memoryBytes, locale: locale)
        }

        var contextText: String { contextText(locale: L10n.locale) }

        func contextText(locale: Locale = L10n.locale) -> String {
            guard let contextLength else { return L10n.t("Unavailable", locale: locale) }
            return L10n.t("\(NumberCopy.grouped(contextLength, locale: locale)) tokens", locale: locale)
        }

        var quantizationText: String { quantizationText(locale: L10n.locale) }

        /// A quantization level is the runtime's own label — "Q8_K_XL",
        /// "8bit" — and is left exactly as the runtime wrote it.
        func quantizationText(locale: Locale = L10n.locale) -> String {
            quantizationLevel ?? L10n.t("Unavailable", locale: locale)
        }

        var detail: String { detail(locale: L10n.locale) }

        func detail(locale: Locale = L10n.locale) -> String {
            let size = displayedMemoryBytes == nil
                ? L10n.t("unavailable", locale: locale)
                : memoryText(locale: locale)
            return L10n.t(
                "\(memoryLabel(locale: locale)) \(size) · Context limit \(contextText(locale: locale)) · Quantization \(quantizationText(locale: locale))",
                locale: locale)
        }
    }

    let models: [Model]
    /// Whether the runtime measures its own responses — LM Studio logs every
    /// request it serves — so speed is shown without any relay being switched on.
    let measuresSpeed: Bool

    init(models: [Model], measuresSpeed: Bool = false) {
        self.models = models
        self.measuresSpeed = measuresSpeed
    }

    var summary: String { summary(locale: L10n.locale) }

    /// One model or many. Two keys rather than one with a plural rule, so a
    /// language whose plural does not split at one — Russian splits at two and
    /// at five — can say so in the catalog.
    func summary(locale: Locale = L10n.locale) -> String {
        guard !models.isEmpty else {
            return L10n.t("Server reachable · No models loaded", locale: locale)
        }
        return models.count == 1
            ? L10n.t("\(NumberCopy.integer(models.count, locale: locale)) model loaded", locale: locale)
            : L10n.t("\(NumberCopy.integer(models.count, locale: locale)) models loaded", locale: locale)
    }
}
