import AppKit

@MainActor
enum MainWindowUI {
    static let sidebarWidth: CGFloat = 214
    static let labelWidth: CGFloat = 150

    static func page(title: String, subtitle: String, views: [NSView]) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 0

        let subtitleLabel = body(subtitle)
        subtitleLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, subtitleLabel] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in [titleLabel, subtitleLabel] + views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    static func scrollView(for stack: NSStackView) -> NSScrollView {
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return scroll
    }

    static func card(_ views: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = NSColor.controlBackgroundColor
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.45)
        box.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            // Cards are full-width page sections. Let forms and text editors use the available
            // width so the UI does not collapse into narrow controls with empty space on the right.
            let width = view.widthAnchor.constraint(equalTo: stack.widthAnchor)
            width.priority = .defaultHigh
            width.isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14)
        ])
        return box
    }

    static func metricCard(_ title: String, value: String, detail: String) -> NSView {
        let titleLabel = body(title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.maximumNumberOfLines = 1

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1

        let detailLabel = body(detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        return card([titleLabel, valueLabel, detailLabel])
    }

    static func horizontalRow(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    static func form(_ rows: [(String, NSView)]) -> NSView {
        let stack = NSStackView(views: rows.map { formRow($0.0, control: $0.1) })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    static func formRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    static func sectionHeader(_ title: String, _ detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor

        let detailPill = pill(detail)
        let row = NSStackView(views: [titleLabel, detailPill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    static func pill(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.fillColor = NSColor.separatorColor.withAlphaComponent(0.20)
        box.borderColor = .clear
        box.cornerRadius = 7
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3)
        ])
        return box
    }

    static func button(_ title: String, target: AnyObject, action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = primary ? .large : .regular
        return button
    }

    static func buttonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    static func body(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    static func empty(_ text: String) -> NSTextField {
        let label = body(text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        return label
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
