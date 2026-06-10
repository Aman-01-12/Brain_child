//
//  InterTileBadge.swift
//  inter
//
//  Reusable, design-token-driven badge for a video tile: a rounded translucent chip
//  containing a single SF Symbol. Replaces the ad-hoc per-badge emoji `NSTextField`s
//  used previously (spec §6.3 / DESIGN-SPEC §7.5). ObjC instantiates this via the
//  generated `inter-Swift.h`.
//

import AppKit

@objc public final class InterTileBadge: NSView {

    private let imageView = NSImageView()

    @objc public init(symbolName: String, tint: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: InterDesignTokens.badgeSize,
                                 height: InterDesignTokens.badgeSize))
        wantsLayer = true
        layer?.backgroundColor = InterDesignTokens.badgeBackground.cgColor
        layer?.cornerRadius = InterDesignTokens.badgeCornerRadius
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = tint
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSymbolName(symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Update the displayed SF Symbol. Safe to call repeatedly.
    @objc public func setSymbolName(_ symbolName: String) {
        let config = NSImage.SymbolConfiguration(
            pointSize: InterDesignTokens.badgeSymbolPointSize, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// The symbol image currently shown (nil if the symbol failed to resolve). Test hook.
    @objc public var currentImage: NSImage? { imageView.image }
}
