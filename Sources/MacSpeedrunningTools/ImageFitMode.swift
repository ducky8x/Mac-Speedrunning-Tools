enum ImageFitMode: String, CaseIterable, Identifiable {
    case keepAspectRatio
    case keepAspectRatioAndFillScreen
    case fitEntireImage

    var id: Self { self }

    var title: String {
        switch self {
        case .keepAspectRatio:
            return "Keep Aspect Ratio"
        case .keepAspectRatioAndFillScreen:
            return "Keep Aspect Ratio and Fill Screen"
        case .fitEntireImage:
            return "Fit Entire Image (Stretches Image)"
        }
    }
}
