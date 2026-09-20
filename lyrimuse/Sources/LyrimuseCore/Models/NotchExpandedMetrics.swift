import CoreGraphics

public enum NotchExpandedMetrics {

    public static let controlsBlock: CGFloat = 35

    public static let lyricPreviewBlock: CGFloat = 17

    public static let scrubberBlock: CGFloat = 24

    public static func height(
        hasLyricPreview: Bool, hasScrubber: Bool, hasControls: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        var h: CGFloat = hasControls ? controlsBlock : 0
        if hasLyricPreview { h += lyricPreviewBlock }
        if hasScrubber { h += scrubberBlock }
        if trackInfoHeight > 0 { h += trackInfoHeight + trackInfoTopSpacing + trackInfoSpacing }
        return h
    }

    public static let trackInfoSpacing: CGFloat = 4

    public static let trackInfoTopSpacing: CGFloat = 12

    public static let trackInfoArtworkSide: CGFloat = 32

    public static let trackInfoTitleLineHeight: CGFloat = 14
    public static let trackInfoArtistLineHeight: CGFloat = 12
    public static let trackInfoAlbumLineHeight: CGFloat = 11

    public static let trackInfoLineSpacing: CGFloat = 1

    public static let trackInfoActionsHeight: CGFloat = 22

    public static func trackInfoHeight(showsArtwork: Bool, showsTitle: Bool, showsArtist: Bool, showsAlbum: Bool,
                                       showsActions: Bool = false) -> CGFloat {
        var textHeight: CGFloat = 0
        var lineCount = 0
        if showsTitle { textHeight += trackInfoTitleLineHeight; lineCount += 1 }
        if showsArtist { textHeight += trackInfoArtistLineHeight; lineCount += 1 }
        if showsAlbum { textHeight += trackInfoAlbumLineHeight; lineCount += 1 }
        if lineCount > 1 { textHeight += CGFloat(lineCount - 1) * trackInfoLineSpacing }
        let artworkHeight: CGFloat = showsArtwork ? trackInfoArtworkSide : 0
        let actionsHeight: CGFloat = showsActions ? trackInfoActionsHeight : 0
        return max(artworkHeight, textHeight, actionsHeight)
    }

    public static let idlePanelBottomSpacing: CGFloat = 10

    public static var idlePanelHeight: CGFloat {
        trackInfoHeight(showsArtwork: false, showsTitle: true, showsArtist: true, showsAlbum: false, showsActions: true)
            + trackInfoTopSpacing + idlePanelBottomSpacing
    }

    public static func maxHeight(
        hasLyricPreviewPossible: Bool = true, hasControlsPossible: Bool = true, trackInfoHeight: CGFloat = 0
    ) -> CGFloat {
        height(hasLyricPreview: hasLyricPreviewPossible, hasScrubber: true,
               hasControls: hasControlsPossible, trackInfoHeight: trackInfoHeight)
    }
}
