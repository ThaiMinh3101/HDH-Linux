import SwiftUI

/// Sheet hiển thị tiến trình import ZIP.
struct ImportProgressView: View {

    @Binding var importState: ImportState
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {

            // MARK: Icon
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 72, height: 72)

                if importState.isImporting {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse)
                } else if importState.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.green)
                }
            }

            // MARK: Title + subtitle
            VStack(spacing: 6) {
                if importState.isImporting {
                    Text("Đang import…")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(importState.currentFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let error = importState.error {
                    Text("Import có vấn đề")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Import thành công!")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }

            // MARK: Progress bar (chỉ khi đang import)
            if importState.isImporting {
                VStack(spacing: 8) {
                    ProgressView(value: importState.progress)
                        .tint(.accentColor)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)

                    Text("\(Int(importState.progress * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Action button (chỉ khi xong)
            if !importState.isImporting {
                Button(action: onDismiss) {
                    Text(importState.error != nil ? "Đóng" : "OK")
                        .font(.body.weight(.semibold))
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(importState.error != nil ? .orange : .accentColor)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 32)
    }
}
