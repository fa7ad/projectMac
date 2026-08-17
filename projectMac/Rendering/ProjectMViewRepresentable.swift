import SwiftUI

struct ProjectMViewRepresentable: NSViewRepresentable {
    let coordinator: AppCoordinator

    func makeNSView(context: Context) -> ProjectMGLView {
        let view = ProjectMGLView(frame: .zero,
                                  pixelFormat: ProjectMGLView.makePixelFormat())!
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ nsView: ProjectMGLView, context: Context) {}
}
