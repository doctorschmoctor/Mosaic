import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import MosaicCore
#endif

// MARK: - Reactions

/// The reactions on a message, as small badges at the bubble's top corner: one per kind, with a
/// count when more than one person chose it, blue when one of them is you. Clicking shows who
/// reacted. Nothing here is sent anywhere: these are reactions Messages recorded.
struct ReactionBadges: View {
    let reactions: [ReactionSummary]
    let names: (ReactionActor) -> String
    @Environment(\.zoomScale) private var zoom
    @State private var showsPeople = false

    var body: some View {
        HStack(spacing: -4 * zoom) {
            ForEach(reactions.prefix(3)) { reaction in badge(reaction) }
            if reactions.count > 3 {
                Text("+\(reactions.count - 3)").font(.system(size: 9 * zoom, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 6 * zoom)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showsPeople = true }
        .popover(isPresented: $showsPeople, arrowEdge: .top) { people.padding(12) }
        .hoverCursor(.pointingHand)
        .help(Self.description(of: reactions, names: names))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.description(of: reactions, names: names))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showsPeople = true }
    }

    private func badge(_ reaction: ReactionSummary) -> some View {
        let mine = reaction.includesMe
        return HStack(spacing: 2 * zoom) {
            Self.glyph(for: reaction.kind, size: 10 * zoom)
            if reaction.count > 1 { Text("\(reaction.count)").font(.system(size: 9 * zoom, weight: .semibold)) }
        }
        .foregroundStyle(mine ? Color.white : Color.secondary)
        .padding(.horizontal, 6 * zoom)
        .frame(minWidth: 22 * zoom, minHeight: 20 * zoom)
        .background(mine ? Palette.bubbleBlue : Palette.incoming, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.surface, lineWidth: 1.5 * zoom))
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(reactions) { reaction in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Self.glyph(for: reaction.kind, size: 12).frame(width: 18)
                    Text(reaction.actors.map(names).joined(separator: ", ")).font(.callout)
                }
            }
        }
        .frame(minWidth: 160, alignment: .leading)
    }

    /// The symbol for a reaction kind, as Messages draws its Tapbacks.
    @ViewBuilder static func glyph(for kind: ReactionEvent.Kind, size: CGFloat) -> some View {
        switch kind {
        case .love: Image(systemName: "heart.fill").font(.system(size: size, weight: .semibold))
        case .like: Image(systemName: "hand.thumbsup.fill").font(.system(size: size, weight: .semibold))
        case .dislike: Image(systemName: "hand.thumbsdown.fill").font(.system(size: size, weight: .semibold))
        case .laugh: Text("HA").font(.system(size: size * 0.8, weight: .heavy, design: .rounded))
        case .emphasize: Image(systemName: "exclamationmark.2").font(.system(size: size, weight: .bold))
        case .question: Image(systemName: "questionmark").font(.system(size: size, weight: .bold))
        case .emoji(let value): Text(value.isEmpty ? "•" : value).font(.system(size: size))
        case .other: Image(systemName: "face.smiling").font(.system(size: size, weight: .semibold))
        }
    }
    static func verb(for kind: ReactionEvent.Kind) -> String {
        switch kind {
        case .love: return "Loved"
        case .like: return "Liked"
        case .dislike: return "Disliked"
        case .laugh: return "Laughed at"
        case .emphasize: return "Emphasized"
        case .question: return "Questioned"
        case .emoji(let value): return "Reacted \(value)"
        case .other: return "Reacted (a kind Mosaic can't show)"
        }
    }
    /// "Loved by Alex and you; Laughed at by Sam."
    static func description(of reactions: [ReactionSummary], names: (ReactionActor) -> String) -> String {
        reactions.map { reaction in
            let people = reaction.actors.map(names)
            let list = people.count > 1 ? people.dropLast().joined(separator: ", ") + " and " + people.last! : people.first ?? ""
            return "\(verb(for: reaction.kind)) by \(list)"
        }.joined(separator: "; ")
    }
}

// MARK: - Replies

/// What a reply's original is, as far as Mosaic can tell.
enum ReplyContext: Equatable {
    /// In the loaded page; the excerpt jumps to it.
    case loaded(Message)
    /// Above the loaded page; the excerpt shows it in full on click.
    case earlier(Message)
    /// Not in this conversation's database (deleted, or not synced to this Mac).
    case missing
}

/// The line above a reply naming what it answers. Clicking goes to the original, or shows it when
/// it is above the loaded history.
struct ReplyExcerpt: View {
    let context: ReplyContext
    let senderName: (Message) -> String
    let onShowOriginal: (Message) -> Void
    @Environment(\.zoomScale) private var zoom
    @State private var showsOriginal = false

    var body: some View {
        HStack(spacing: 4 * zoom) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 8 * zoom))
            Text(label).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 10 * zoom))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8 * zoom).padding(.vertical, 4 * zoom)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: activate)
        .hoverCursor(.pointingHand, enabled: context != .missing)
        .popover(isPresented: $showsOriginal, arrowEdge: .top) { original.padding(12).frame(maxWidth: 320) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reply to " + label)
        .accessibilityAddTraits(context == .missing ? [] : .isButton)
    }

    private var label: String {
        switch context {
        case .loaded(let message), .earlier(let message):
            return "\(senderName(message)): \(QuotedReply.excerpt(of: message))"
        case .missing:
            return "Original message unavailable"
        }
    }
    private func activate() {
        switch context {
        case .loaded(let message): onShowOriginal(message)
        case .earlier: showsOriginal = true
        case .missing: break
        }
    }
    @ViewBuilder private var original: some View {
        if case .earlier(let message) = context {
            VStack(alignment: .leading, spacing: 6) {
                Text(senderName(message)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.isUnsent ? "This message was unsent." : message.text.isEmpty ? QuotedReply.excerpt(of: message) : message.text)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(MessageText.day(message.date) + ", " + MessageText.time(message.date)).font(.caption2).foregroundStyle(.tertiary)
                Text("Earlier than the loaded history").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The line under a composer that is quoting a message, with the quote as it will be sent.
struct ReplyBar: View {
    let target: ReplyTarget
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Quoting \(target.senderName ?? "message")").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(target.excerpt).font(.system(size: 11)).lineLimit(1).foregroundStyle(.primary)
            }
            Spacer(minLength: 4)
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel("Cancel the quote")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help("Messages can't start a reply thread from another app, so the quote is sent as ordinary text above your message: “" + QuotedReply.compose(quoting: target.excerpt, from: target.senderName, reply: "…") + "”. Esc cancels.")
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Thread lines

/// A centered line in the thread that is not a bubble: someone unsent a message, or something
/// happened to the conversation itself.
struct ThreadNote: View {
    let text: String
    @Environment(\.zoomScale) private var zoom
    var body: some View {
        Text(text).font(.system(size: 10 * zoom)).italic().foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity).padding(.vertical, 2 * zoom)
    }
}

/// Where the unread messages begin, while the reader is scrolled up above them.
struct UnreadDivider: View {
    @Environment(\.zoomScale) private var zoom
    var body: some View {
        HStack(spacing: 8 * zoom) {
            Rectangle().fill(Palette.accent.opacity(0.5)).frame(height: 1)
            Text("New Messages").font(.system(size: 9 * zoom, weight: .semibold)).foregroundStyle(Palette.accent)
            Rectangle().fill(Palette.accent.opacity(0.5)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("New messages below")
    }
}
