//
//  LinkClick.swift
//  MarkDevKit
//
//  Pure classification of an editor link click — what to do, not how.
//

import Foundation

/// What ``MarkdownTextView.clicked(onLink:at:)`` should do with a URL.
public enum LinkClick: Equatable, Sendable {
    /// A `[[wikilink]]` carried on the `markdev-wiki` scheme.
    case wiki(String)
    /// A footnote reference on the `markdev-footnote` scheme.
    case footnote(String)
    /// In-document jump — `#heading` only, never a path.
    case heading(String)
    /// Scheme-less relative path, or `file:` that the workspace must resolve.
    case document(String)
    /// `http` / `https` / `mailto` / `tel`, or any other residual scheme.
    case external
}

extension LinkClick {
    /// Classifies `url` without side effects — tests exercise this directly.
    public static func classify(_ url: URL) -> LinkClick {
        if url.scheme == MarkdownStyler.wikiLinkScheme {
            let target = (url.host(percentEncoded: false) ?? url.absoluteString)
                .replacingOccurrences(of: "\(MarkdownStyler.wikiLinkScheme)://", with: "")
            return .wiki(target.removingPercentEncoding ?? target)
        }

        if url.scheme == MarkdownStyler.footnoteScheme {
            let target = (url.host(percentEncoded: false) ?? url.absoluteString)
                .replacingOccurrences(of: "\(MarkdownStyler.footnoteScheme)://", with: "")
            return .footnote(target.removingPercentEncoding ?? target)
        }

        if isHeadingOnly(url) {
            let anchor = headingAnchor(from: url)
            return .heading(anchor)
        }

        let absolute = url.absoluteString
        // Protocol-relative URLs are not vault paths.
        if absolute.hasPrefix("//") {
            return .external
        }

        let scheme = url.scheme?.lowercased()
        if scheme == nil || scheme == "file" {
            return .document(documentDestination(from: url))
        }

        switch scheme {
        case "http", "https", "mailto", "tel":
            return .external
        default:
            // Residual junk schemes (`foo:bar`) still go to AppKit; only
            // scheme-less paths were the -50 failure this exists to stop.
            return .external
        }
    }

    /// `#Parsing`, or a URL whose path is empty and whose fragment is set.
    private static func isHeadingOnly(_ url: URL) -> Bool {
        let absolute = url.absoluteString
        if absolute.hasPrefix("#") { return true }
        if url.scheme != nil { return false }
        // Protocol-relative `//host/...` is not a heading and not a document.
        if absolute.hasPrefix("//") { return false }
        let path = url.path
        let fragment = url.fragment
        return path.isEmpty && fragment != nil && !(fragment?.isEmpty ?? true)
    }

    private static func headingAnchor(from url: URL) -> String {
        if let fragment = url.fragment, !fragment.isEmpty {
            return fragment.removingPercentEncoding ?? fragment
        }
        let trimmed = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return trimmed.removingPercentEncoding ?? trimmed
    }

    /// Percent-decoded destination, including a trailing `#anchor` when present.
    private static func documentDestination(from url: URL) -> String {
        if url.scheme?.lowercased() == "file" {
            var path = url.path
            if let fragment = url.fragment, !fragment.isEmpty {
                path += "#\(fragment)"
            }
            return path.removingPercentEncoding ?? path
        }

        // Scheme-less: the styler percent-encoded the raw dest (so `#` became
        // `%23`). Decode once, then the follow path can split the anchor.
        let raw = url.absoluteString
        if raw.hasPrefix("//") {
            // Classifier already sends protocol-relative elsewhere when it has
            // a scheme; a bare `//` string still lands here as scheme-less.
            return raw
        }
        return raw.removingPercentEncoding ?? raw
    }
}

/// How a resolved local path should be opened from a document link.
public enum DocumentLinkOpenKind: Equatable, Sendable {
    case markdownNote
    case directory
    case otherFile
    case missing

    /// Pure: filesystem shape plus whether the URL is Markdown.
    public static func classify(
        isDirectory: Bool,
        isRegularFile: Bool,
        isMarkdown: Bool
    ) -> DocumentLinkOpenKind {
        if isDirectory { return .directory }
        if isRegularFile {
            return isMarkdown ? .markdownNote : .otherFile
        }
        return .missing
    }
}
