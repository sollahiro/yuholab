import SwiftUI

/// 大画面の同業比較（準備中。次のコミットで実装）。
struct RegularCompareView: View {
    @Bindable var model: LargeScreenModel

    var body: some View {
        Text("比較")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.shell.ignoresSafeArea())
    }
}
