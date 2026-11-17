import SwiftUI

/// How much of the toolbar fits. Groups collapse one at a time as the window narrows.
enum ToolbarLevel: CaseIterable, Comparable {
    case minimal    // Tools and actions are both menus.
    case condensed  // Undo, shadow and the actions share one menu.
    case compact    // Crop's Reset and Apply become icons.
    case full

    /// The narrowest toolbar width this level is guaranteed to fit in.
    var minimumWidth: CGFloat {
        switch self {
        case .minimal: 300
        case .condensed: 584
        case .compact: 762
        case .full: 816
        }
    }

    static func fitting(width: CGFloat) -> ToolbarLevel {
        allCases.last { width >= $0.minimumWidth } ?? .minimal
    }
}

struct EditorToolbar: View {
    let model: EditorModel
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onDone: () -> Void

    @State private var level = ToolbarLevel.full

    var body: some View {
        EditorToolbarContent(model: model, level: level, onCopy: onCopy, onDelete: onDelete, onPin: onPin, onDone: onDone)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                level = ToolbarLevel.fitting(width: width)
            }
            .animation(.smooth(duration: 0.3), value: level)
    }
}

struct EditorToolbarContent: View {
    @Bindable var model: EditorModel
    let level: ToolbarLevel
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onDone: () -> Void

    @Namespace private var selection
    @Namespace private var glass
    @State private var showsStylePopover = false

    var body: some View {
        HStack(spacing: 10) {
                if level == .minimal { toolsMenu } else { tools }

                if model.tool == .crop {
                    cropControls
                } else if model.usesStyle {
                    styleButton
                }

                // Undo, redo and the shadow come out with the rest of the tools.
                if level >= .compact {
                    if model.showsAllTools { history }
                    actions
                } else {
                    moreMenu
                }
                doneButton
        }
        .fixedSize()
        .background { shortcuts }
        .animation(.smooth(duration: 0.25), value: model.tool)
        .animation(.smooth(duration: 0.3), value: model.showsAllTools)
    }

    /// Always present, so the keys keep working while their buttons are collapsed into a menu.
    private var shortcuts: some View {
        ZStack {
            Button("Undo", action: model.undo)
                .keyboardShortcut("z")
                .disabled(!model.canUndo || model.isEditingText)
            Button("Redo", action: model.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo || model.isEditingText)
            // Disabled while typing, so ⌘C reaches the text field instead.
            Button("Copy", action: onCopy)
                .keyboardShortcut("c")
                .disabled(model.isEditingText)
            Button("Done", action: onDone)
                .keyboardShortcut(.return, modifiers: .command)
            Button("Save", action: onDone)
                .keyboardShortcut("s")
            Button("Pin", action: onPin)
                .keyboardShortcut("p")
            if model.tool == .crop {
                Button("Apply", action: model.applyCrop)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Tools

    /// The everyday tools always show. The rest slide out of the same strip, so nothing jumps around.
    private var tools: some View {
        HStack(spacing: 2) {
            // The extras line up after the everyday tools, so those never move when the strip grows.
            ForEach(EditorTool.allCases.filter(\.isEveryday)
                    + (model.showsAllTools ? EditorTool.allCases.filter { !$0.isEveryday } : [])) { tool in
                Button {
                    model.choose(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                        .background {
                            if model.tool == tool {
                                Circle()
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "tool", in: selection)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                .accessibilityLabel(tool.title)
            }

            Divider().frame(height: 18).padding(.horizontal, 3)

            Button {
                model.setShowsAllTools(!model.showsAllTools)
            } label: {
                Image(systemName: model.showsAllTools ? "chevron.backward" : "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(model.showsAllTools ? "Fewer Tools" : "More Tools: steps, highlight, blur, undo and shadow")
            .accessibilityLabel(model.showsAllTools ? "Fewer Tools" : "More Tools")
        }
        .padding(4)
        .desktopGlass()
    }

    private var toolsMenu: some View {
        Menu {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    model.choose(tool)
                } label: {
                    if model.tool == tool {
                        Label(tool.title, systemImage: "checkmark")
                    } else {
                        Text(tool.title)
                    }
                }
            }
        } label: {
            menuLabel(Image(systemName: model.tool.symbol))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .desktopGlass()
        .help("Tool: \(model.tool.title)")
        .accessibilityLabel("Tool")
        .accessibilityValue(model.tool.title)
    }

    // MARK: Style

    private var styleButton: some View {
        Button {
            showsStylePopover.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: model.color.nsColor))
                .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5) }
                .frame(width: 20, height: 20)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .desktopGlass()
        .help("Color and Size")
        .accessibilityLabel("Color and Size")
        .popover(isPresented: $showsStylePopover, arrowEdge: .top) {
            HStack(spacing: 6) {
                swatches
                Divider().frame(height: 18).padding(.horizontal, 2)
                sizes
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var swatches: some View {
        ForEach(AnnotationColor.allCases) { color in
            Button {
                model.color = color
            } label: {
                Circle()
                    .fill(Color(nsColor: color.nsColor))
                    .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5) }
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .overlay {
                        if model.color == color {
                            Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(color.rawValue.capitalized)
        }
    }

    private var sizes: some View {
        ForEach(StrokeSize.allCases) { size in
            Button {
                model.setSize(size)
            } label: {
                Circle()
                    .fill(model.size == size ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: size.points + 3, height: size.points + 3)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Size \(size.points)")
        }
    }

    // MARK: Crop

    @ViewBuilder
    private var cropControls: some View {
        if level == .full {
            HStack(spacing: 0) {
                Button("Reset") { model.resetCrop() }
                    .disabled(model.draftCrop == nil)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                Divider().frame(height: 18)
                Button("Apply") { model.applyCrop() }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
            .desktopGlass()
        } else {
            HStack(spacing: 2) {
                iconButton("arrow.counterclockwise", "Reset Crop") { model.resetCrop() }
                    .disabled(model.draftCrop == nil)
                iconButton("checkmark", "Apply Crop") { model.applyCrop() }
            }
            .padding(4)
            .desktopGlass()
        }
    }

    // MARK: History and actions

    private var history: some View {
        HStack(spacing: 2) {
            iconButton("arrow.uturn.backward", "Undo", action: model.undo)
                .disabled(!model.canUndo || model.isEditingText)
            iconButton("arrow.uturn.forward", "Redo", action: model.redo)
                .disabled(!model.canRedo || model.isEditingText)
            Button(action: model.toggleShadow) {
                shadowGlyph
                    .frame(width: 32, height: 32)
                    .foregroundStyle(model.showsShadow ? Color.white : Color.primary)
                    .background {
                        if model.showsShadow {
                            Circle().fill(Color.accentColor)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.showsShadow ? "Remove Shadow (S)" : "Add Shadow (S)")
            .accessibilityLabel("Shadow")
            .accessibilityValue(model.showsShadow ? "On" : "Off")

        }
        .padding(4)
        .desktopGlass()
    }

    private var actions: some View {
        HStack(spacing: 2) {
            iconButton("pin", "Pin to Screen (⌘P)", action: onPin)
            iconButton("doc.on.doc", "Copy (⌘C)", action: onCopy)
            iconButton("trash", "Delete Screenshot", action: onDelete)
        }
        .padding(4)
        .desktopGlass()
    }

    private var moreMenu: some View {
        Menu {
            Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                .disabled(!model.canUndo || model.isEditingText)
            Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                .disabled(!model.canRedo || model.isEditingText)
            Divider()
            Button(model.showsShadow ? "Remove Shadow" : "Add Shadow", action: model.toggleShadow)
            Button("Pin to Screen", systemImage: "pin", action: onPin)
            Button("Copy", systemImage: "doc.on.doc", action: onCopy)
            Divider()
            Button("Delete Screenshot", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            menuLabel(Image(systemName: "ellipsis"))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .desktopGlass()
        .help("More")
        .accessibilityLabel("More")
    }

    private func menuLabel(_ image: Image) -> some View {
        image
            .frame(width: 40, height: 40)
            .contentShape(Circle())
    }

    /// SF Symbols' "shadow" is a text-formatting glyph, so draw a card casting a shadow instead.
    private var shadowGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .opacity(0.4)
                .frame(width: 13, height: 11)
                .offset(x: 2, y: 3)
            RoundedRectangle(cornerRadius: 3)
                .frame(width: 13, height: 11)
                .offset(x: -1, y: -1)
        }
    }

    private var doneButton: some View {
        Button("Done", action: onDone)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Liquid Glass that samples the desktop behind the window. SwiftUI's glass only refracts the window's
/// own content, and the editor window is see-through, so that glass would come out flat.
private struct DesktopGlass: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

extension View {
    /// A capsule, or a circle for a square view, of glass behind the content.
    func desktopGlass() -> some View {
        background {
            GeometryReader { geometry in
                DesktopGlass(cornerRadius: min(geometry.size.width, geometry.size.height) / 2)
            }
        }
    }
}
