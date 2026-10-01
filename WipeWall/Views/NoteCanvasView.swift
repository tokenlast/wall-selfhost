import SwiftUI

enum CanvasFont: String, CaseIterable, Identifiable {
    case helvetica = "Helvetica"
    case helveticaNeue = "Helvetica Neue"
    case times = "Times New Roman"
    case plex = "Courier"

    var id: String { rawValue }
}

struct NoteCanvasView: View {
    @AppStorage("wall.note") private var note = "Wi‑Fi\nnetwork name\npassword"
    @AppStorage("wall.note.font") private var fontName = CanvasFont.helvetica.rawValue
    @AppStorage("wall.note.size") private var fontSize = 28.0
    @State private var editing = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if editing {
                TextEditor(text: $note)
                    .font(.custom(fontName, size: fontSize))
                    .foregroundColor(.black)
                    .focused($editorFocused)
                    .padding(-5)
                    .background(Color.white)
                    .onAppear {
                        DispatchQueue.main.async {
                            editorFocused = true
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 14) {
                            Menu(fontName) {
                                ForEach(CanvasFont.allCases) { font in
                                    Button(font.rawValue) { fontName = font.rawValue }
                                }
                            }
                            Button("A−") { fontSize = max(16, fontSize - 2) }
                            Button("A+") { fontSize = min(64, fontSize + 2) }
                            InstantActionButton(action: finishEditing) { Text("done") }
                        }
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.black)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .background(Color.white.opacity(0.94))
                    }
            } else {
                ZStack(alignment: .topLeading) {
                    Button {
                        editing = true
                    } label: {
                        Text(note.isEmpty ? " " : note)
                            .font(.custom(fontName, size: fontSize))
                            .foregroundColor(.black)
                            .lineSpacing(fontSize * 0.12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Wall note")
                    .accessibilityHint("Double-tap to edit")

                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Menu(fontName) {
                    ForEach(CanvasFont.allCases) { font in
                        Button(font.rawValue) { fontName = font.rawValue }
                    }
                }
                Spacer()
                Button("A−") { fontSize = max(16, fontSize - 2) }
                Text("\(Int(fontSize))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("A+") { fontSize = min(64, fontSize + 2) }
                InstantActionButton(action: finishEditing) { Text("Done") }
            }
        }
    }

    private func finishEditing() {
        editorFocused = false
        editing = false
    }
}
