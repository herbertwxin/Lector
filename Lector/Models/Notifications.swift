import Foundation

// MARK: - Notifications

extension Notification.Name {
    static let lectorPrint               = Notification.Name("lectorPrint")
    static let lectorAddHighlight        = Notification.Name("lectorAddHighlight")
    static let lectorSearchNext          = Notification.Name("lectorSearchNext")
    static let lectorSearchPrev          = Notification.Name("lectorSearchPrev")
    static let lectorWebSearch           = Notification.Name("lectorWebSearch")
    static let lectorAnnotationsChanged  = Notification.Name("lectorAnnotationsChanged")
    static let lectorCopySelection       = Notification.Name("lectorCopySelection")
    static let lectorRotate              = Notification.Name("lectorRotate")
    static let lectorFocusPDF            = Notification.Name("lectorFocusPDF")
    static let lectorOpenNewWindow       = Notification.Name("lectorOpenNewWindow")
    /// Scroll the PDF view by a pixel delta. UserInfo: ["delta": CGFloat, "smooth": Bool]
    static let lectorScrollBy            = Notification.Name("lectorScrollBy")
}
