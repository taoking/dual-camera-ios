import AVKit
import SwiftUI

/// 预览关闭时显式停止并释放 AVPlayerItem，避免临时视频仍被文件句柄占用。
struct ManagedVideoPlayer: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
    }
}
